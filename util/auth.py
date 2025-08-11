import argparse, asyncio, datetime, os, steam, steam.gateway, struct, sys, textwrap, typing

# Helpers
def write(str, symb):
    if not args.silent:
        print(f"[{symb}] {str}")
def dbg(str):
    if args.verbose:
        write(str, '+')
def log(str): write(str, '-')
def warn(str): write(str, '!')
def date(d): return d.strftime('%Y-%m-%d %H:%M:%S')
def time(t): return date(datetime.datetime.fromtimestamp(t))
async def end(reason = None) -> typing.NoReturn:
    if reason: warn(reason)
    await client.disconnect()
    raise SystemExit(1 if reason else 0)

# Argument parsing
parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=textwrap.dedent("""
        - Simple Steam App Authenticator -
    Generates and activates a session authentication ticket for the given app via Steam's API,
    this cancels any outstanding tickets for the same user/app pair, and expires in ~5 minutes.
    The credentials must be provided either in the args or via SSAA_USERNAME and SSAA_PASSWORD
    environment variables. An ownership ticket can be supplied in ASCII, otherwise a new
    one will be generated too, but they typically have a lifetime of weeks so its recommended
    to cache them and pass them whenever possible. Requires Python 3.11+. See below for more info.
    """),
    epilog=textwrap.dedent("""
    Session tickets are normally obtained via Steamwork's GetAuthSessionTicket method and need to
    be supplied to servers in order to authenticate and prove ownership of the game. This allows
    the server to start an authenticated session with BeginAuthSession. The ticket is composed of
    3 elements: The Game Connect (GC) token, the Session Header, and the Ownership Ticket.

        - The Game Connect token (24 bytes) is unique per session and should be used immediately,
          once validated it expires in about 5 mins. Steam issues 10 GC tokens on login so they
          can be consumed as needed, as well as additional tokens when we join a game.

        - The Session Header (28 bytes) contains session information that is not validated, such
          as the current connection's duration or the external IP.

        - The Ownership Ticket constitutes the rest of the payload, being at least 46 bytes, plus
          128 bytes for the signature. It expires in 21 days and thus, while not necessary, it
          should be preserved and reused. This can be done by stripping the first 56 bytes of the
          full ticket (GC token + session header + ownership ticket size). The signature is based
          on RSA-SHA1 and can be verified with Steam's public System key:

              MIGdMA0GCSqGSIb3DQEBAQUAA4GLADCBhwKBgQDf7BrWLBBmLBc1OhSwfFkRf53T
              2Ct64+AVzRkeRuh7h3SiGEYxqQMUeYKO6UWiSRKpI2hzic9pobFhRr3Bvr/WARvY
              gdTckPv+T1JzZsuVcNfFjrocejN1oWI0Rrtgt4Bo+hOneoo3S57G9F1fOpn5nsQ6
              6WOiu4gZKODnFMBCiQIBEQ==
    """)
)
parser.add_argument('app',              type=int,            help='Steam app ID (e.g. 440 for TF2)')
parser.add_argument('-c', '--connect',  action='store_true', help='Stay connected after exporting tickets (will require an Interrupt to close)')
parser.add_argument('-d', '--dry',      action='store_true', help='Performs a dry run (logs in a verifies supplied ticket)')
parser.add_argument('-f', '--file',     type=str,            help='Export tickets to this file instead of STDOUT')
parser.add_argument('-p', '--password', type=str,            help='Steam password used for login (also SSAA_PASSWORD env var)')
parser.add_argument('-u', '--username', type=str,            help='Steam username used for login (also SSAA_USERNAME env var)')
parser.add_argument('-s', '--silent',   action='store_true', help='Supresses all STDOUT and STDERR output except for the ticket itself')
parser.add_argument('-t', '--ticket',   type=str,            help='App ownership ticket to attempt to reuse (also SSAA_TICKET)')
parser.add_argument('-v', '--verbose',  action='store_true', help='Print additional technical information to the terminal')
args = parser.parse_args()

# It's very hard to properly catch exceptions inside async contexts and we need the
# terminal to be clean to export the ticket, so we optionally suppress STDERR to
# prevent exceptions raised when disconnecting from cluttering the terminal.
if args.silent:
    sys.stderr.flush()
    devnull = open(os.devnull, 'w')
    os.dup2(devnull.fileno(), sys.stderr.fileno())

USERNAME = args.username or os.environ.get('SSAA_USERNAME')
PASSWORD = args.password or os.environ.get('SSAA_PASSWORD')
TICKET   = args.ticket   or os.environ.get('SSAA_TICKET')
if not USERNAME:
    warn('Steam username must be provided by either the --username option or the SSAA_USERNAME environment variable')
if not PASSWORD:
    warn('Steam username must be provided by either the --password option or the SSAA_PASSWORD environment variable')
if not USERNAME or not PASSWORD:
    raise SystemExit(1)

class Bot(steam.Client):
    """Handle communications via Steamworks API using Gobot1234/steam.py"""

    # < ------------ EVENT HANDLERS ------------>

    async def on_connect(self) -> None:
        log(f"Connected to Steam")

    async def on_ready(self) -> None:
        log(f"Logged in as {self.user.name} ({self.user.id64})")
        self.log_tokens()

        # Reuse ownership ticket or fetch a new one
        app = self.get_app(args.app)
        await self.change_presence(app=app)
        ticket = await self.get_ownership_ticket(app)
        if not ticket:
            await end("Invalid ownership ticket supplied / fetched")
        if args.dry:
            await end()

        # Build and activate ticket
        ticket = self.get_authentication_ticket(ticket)
        if not ticket:
            await end("Failed to generate valid authentication ticket")
        log("Activating ticket...")
        await ticket.activate()

        # Export ticket
        ascii = bytes(ticket)[4:].hex().upper()
        if args.file:
            with open(args.file, 'a') as f:
                f.write(ascii + '\n')
        else:
            print(ascii)

        if not args.connect:
            await end()

    async def on_disconnect(self) -> None:
        log(f"Disconnected from Steam")

    async def on_user_update(self, before: steam.User, after: steam.User, /) -> None:
        dbg(f"User {after.name} ({after.state.name}) updated: Playing {after.app}")

    async def on_error(self, event, error, *arg, **kwarg) -> None:
        warn(f"Received Steam error: {event} ({error})")

    # < ------------ TICKET MANIPULATION ------------>

    def tokens(self) -> list[bytes]:
        return self._state._game_connect_bytes

    def verify_ticket(self, ticket: steam.OwnershipTicket | steam.AuthenticationTicket) -> bool:
        ttype = type(ticket).__name__
        issues = 0
        if not ticket.signature or not ticket.is_signature_valid():
            warn(f"{ttype} is not properly signed by Steam")
            issues += 1
        if ticket.is_expired():
            warn(f"{ttype} is expired ({date(ticket.expires)})")
            issues += 1
        if ticket.app.id != args.app:
            warn(f"{ttype} belongs to a different app ({ticket.app.id} vs {args.app})")
            issues += 1
        if ticket.user.id64 != self.user.id64:
            warn(f"{ttype} belongs to a different user ({ticket.user.id64} vs {self.user.id64})")
            issues += 1
        if issues == 0:
            log(f"{ttype} is correct (app {ticket.app.id}, steam id {ticket.user.id64}, expires {date(ticket.expires)})")
        return issues == 0

    async def get_ownership_ticket(self, app: steam.PartialApp) -> steam.OwnershipTicket | None:
        # First try to use supplied ticket
        if TICKET:
            log("Attempting to use provided ownership ticket:")
            ticket = bytes.fromhex(TICKET)
            dbg(ticket.hex().upper())
            ticket = steam.OwnershipTicket(self._state, steam.utils.StructIO(ticket))
            if self.verify_ticket(ticket):
                self.log_ownership_ticket(ticket)
                return ticket

        # Otherwise, fetch a new ticket
        if args.dry:
            return
        log("Requesting new ownership ticket...")
        ticket = await self._state.fetch_app_ownership_ticket(app.id)
        dbg(ticket.hex().upper())
        ticket = steam.OwnershipTicket(self._state, steam.utils.StructIO(ticket))
        if self.verify_ticket(ticket):
            self.log_ownership_ticket(ticket)
            return ticket
        return None

    def get_authentication_ticket(self, own: steam.OwnershipTicket) -> steam.AuthenticationTicket | None:
        try:
            token = self.tokens().pop(0)
        except IndexError:
            return None
        log(f"Building authentication ticket with token {struct.unpack('<Q', token[:8])[0]:x}")
        gc_token = struct.pack('<L', len(token)) + token
        session_header = struct.pack('<7L', 24, 1, 2, int(own.external_ip), 0, 0, 1)
        own_ticket = struct.pack('<L', len(bytes(own))) + bytes(own)
        ticket = steam.utils.StructIO(gc_token + session_header + own_ticket)
        ticket.seek(4) # Poor design but the library assumes this
        ticket = steam.AuthenticationTicket(self._state, ticket)
        return ticket if self.verify_ticket(ticket) else None

    # < ------------ LOGGING ------------>

    def log_tokens(self) -> None:
        tokens = self.tokens().copy()
        log(f"GC tokens found: {len(tokens)}")
        if not args.verbose or len(tokens) == 0:
            return
        dbg("    %40s    %16s %17s %19s" % ('Raw bytes', 'Token', 'Steam ID', 'Date'))
        for token in tokens:
            gc, steam_id, gen_time = struct.unpack('<2QL', token)
            dbg(f"    {token.hex().upper()} -> {gc:016x} {steam_id} {time(gen_time)}")

    def log_ownership_ticket(self, ticket: steam.OwnershipTicket) -> None:
        line = "+" + "-" * 76 + "+"
        dbg(line)
        dbg("|Metadata|%6s|%7s|%5s|%6s|%19s|%19s|" % ('Length', 'Version', 'Flags', 'Signed', 'Created', 'Expires'))
        dbg("|        |%6d|%7d|%5d|%6s|%19s|%19s|" % (len(bytes(ticket)), ticket.version, ticket.flags, 'Yes' if ticket.signature else 'No', date(ticket.created_at), date(ticket.expires)))
        dbg(line)
        dbg("|Profile |%17s|%6s|%15s|%15s|%5s|%4s|" % ('Steam ID', 'App ID', 'External IP', 'Internal IP', 'Lics.', 'DLCs'))
        dbg("|        |%17d|%6d|%15s|%15s|%5d|%4d|" % (ticket.user.id64, ticket.app.id, ticket.external_ip, ticket.internal_ip, len(ticket.licenses), len(ticket.dlc)))
        if len(ticket.licenses) > 0:
            dbg(line)
            dbg("|Licenses|%-67s|" % (', '.join(str(lic.id) for lic in ticket.licenses),))
        if len(ticket.dlc) > 0:
            dbg(line)
            dbg("|DLCs    |%-67s|" % (', '.join(str(dlc.id) for dlc in ticket.dlc),))
        dbg("+" + "-" * 76 + "+")

    # < ------------ OTHER ------------>

    async def disconnect(self) -> None:
        """Disconnect bot. The reason we don't use self.close() directly is because
        that deactivates the auth tickets."""
        log("Disconnecting...")
        if self.is_closed(): return
        self._closed = True
        await self.change_presence(apps=[]) # Disconnect from games
        await self._state.handle_close()    # Close TCP websocket

client = Bot()
try:
    client.run(USERNAME, PASSWORD)
except* steam.gateway.ConnectionClosed:
    pass
finally:
    asyncio.run(client.http.close()) # Close HTTP session
    log("Closed")