import argparse, datetime, os, struct, steam, steam.gateway

# Helpers
def log(str):
    if args.verbose:
        print(str)
async def end(reason = 0):
    await client.disconnect()
    raise SystemExit(reason)
def date(d):
    return d.strftime('%Y-%m-%d %H:%M:%S')
def time(t):
    return date(datetime.datetime.fromtimestamp(t))

# Argument parsing
parser = argparse.ArgumentParser(description=
    """Simple Steam App Authenticator -
    Generates and activates an authentication ticket for the given app via Steam's API.
    The credentials can be provided in the args or via SSAA_USERNAME and SSAA_PASSWORD
    environment variables. An ownership ticket can be provided in ASCII, a new one will
    be generated, but they typically have a lifetime of weeks so its recommended to
    cache them and pass them whenever possible.
    """
)
parser.add_argument('app',              type=int, help='App ID (e.g. 440 for TF2)')
parser.add_argument('-u', '--username', type=str, help='Steam username used for login (cf. SSAA_USERNAME)')
parser.add_argument('-p', '--password', type=str, help='Steam password used for login (cf. SSAA_PASSWORD)')
parser.add_argument('-t', '--ticket',   type=str, help='App ownership ticket to reuse')
parser.add_argument('-v', '--verbose', action='store_true', help='Print additional information to the terminal')
args = parser.parse_args()

USERNAME = args.username or os.environ.get('SSAA_USERNAME')
PASSWORD = args.password or os.environ.get('SSAA_PASSWORD')
if not USERNAME:
    log('Steam username must be provided by either the --username option or the SSAA_USERNAME environment variable')
if not PASSWORD:
    log('Steam username must be provided by either the --password option or the SSAA_PASSWORD environment variable')
if not USERNAME or not PASSWORD:
    end(1)

class Bot(steam.Client):

    async def on_connect(self) -> None:
        log(f"Connected to Steam")

    async def on_ready(self) -> None:
        log(f"Logged in as {self.user.name} ({self.user.id64})")
        self.log_tokens()
        app = self.get_app(args.app)
        ticket = await self.get_ownership_ticket(app)
        ticket = self.get_authentication_ticket(ticket)
        await self.change_presence(app=app)
        log("Activating ticket...")
        await ticket.activate()
        print(bytes(ticket)[4:].hex().upper())
        await end(0)

    async def on_disconnect(self) -> None:
        log(f"Disconnected from Steam")

    async def on_user_update(self, before: steam.User, after: steam.User, /) -> None:
        log(f"User {after.name} ({after.state.name}) updated: Playing {after.app}")

    async def on_error(self, event, error, *arg, **kwarg) -> None:
        if not args.verbose:
            end(f"Steam error: {error}")
        raise

    def tokens(self) -> list[bytes]:
        return self._state._game_connect_bytes

    def verify_ticket(self, ticket: steam.OwnershipTicket | steam.AuthenticationTicket) -> None:
        ttype = type(ticket).__name__
        if not ticket.signature or not ticket.is_signature_valid():
            end(f"{ttype} is not properly signed by Steam")
        if ticket.is_expired():
            end(f"{ttype} is expired ({date(ticket.expires)})")
        if ticket.app.id != args.app:
            end(f"{ttype} belongs to a different app ({ticket.app.id} vs {args.app})")
        if ticket.user.id64 != self.user.id64:
            end(f"{ttype} belongs to a different user ({ticket.user.id64} vs {self.user.id64})")
        log(f"{ttype} is correct (app {ticket.app.id}, steam id {ticket.user.id64}, expires {date(ticket.expires)})")

    async def get_ownership_ticket(self, app: steam.PartialApp) -> steam.OwnershipTicket:
        if args.ticket:
            log("Using provided ownership ticket:")
            ticket = bytes.fromhex(args.ticket)
        else:
            log("Requesting new ownership ticket...")
            ticket = await self._state.fetch_app_ownership_ticket(app.id)
        log(ticket.hex().upper())
        ticket = steam.OwnershipTicket(self._state, steam.utils.StructIO(ticket))
        self.verify_ticket(ticket)
        return ticket
    
    def get_authentication_ticket(self, own: steam.OwnershipTicket) -> steam.AuthenticationTicket:
        log("Building authentication ticket...")
        token = self.tokens().pop(0)
        gc_token = struct.pack('<L', len(token)) + token
        session_header = struct.pack('<7L', 24, 1, 2, int(own.external_ip), 0, 0, 1)
        own_ticket = struct.pack('<L', len(bytes(own))) + bytes(own)
        ticket = steam.utils.StructIO(gc_token + session_header + own_ticket)
        ticket.seek(4) # Poor design but the library assumes this
        ticket = steam.AuthenticationTicket(self._state, ticket)
        self.verify_ticket(ticket)
        return ticket

    def log_tokens(self, all=False) -> None:
        log(f"GC tokens found: {len(self.tokens())}")
        if not all:
            return
        for token in self.tokens():
            gc, steam_id, gen_time = struct.unpack('<2QL', token)
            log("    %-20s -> %-16s %-17s %s" % ('Raw bytes', 'Token', 'Steam ID', 'Date'))
            log(f"    {token.hex().upper()} -> {gc:016x} {steam_id} {time(gen_time)}")

    async def disconnect(self) -> None:
        """Disconnect bot. The reason we don't use self.close() directly is because
        that deactivates the auth tickets."""
        log("Disconnecting...")
        if self.is_closed(): return
        self._closed = True

        try:
            await self.change_presence(apps=[]) # Disconnect from games
            await self._state.handle_close()    # Close TCP websocket
        except steam.gateway.ConnectionClosed:
            pass
        await self.http.close()             # Close HTTP server
        self._ready.clear()                 # Clear asyncio event
        log("Closed")

client = Bot()
client.run(USERNAME, PASSWORD)