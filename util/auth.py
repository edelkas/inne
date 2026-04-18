import argparse, asyncio, base64, datetime, enum, json, os, steam, steam.gateway, struct, sys, textwrap, traceback, typing

# Helpers
def write(str, symb):
    if not args.silent:
        print(f"[{symb}] {str}")
def dbg(str):
    if args.verbose:
        write(str, '+')
def log(str): write(str, '-')
def warn(str): write(str, '!')
def date(d): return d.isoformat() if d else 'Unknown'
def time(t): return date(datetime.datetime.fromtimestamp(t))
def serial(bytes: bytes) -> str: return bytes.hex().upper()

# Exiting the program
class ExitCode(enum.Enum):
    OK                       = 0
    NO_CREDENTIALS           = 1
    NO_OWNERSHIP_TICKET      = 2
    NO_AUTHENTICATION_TICKET = 3

async def end(code: ExitCode = ExitCode.OK) -> typing.NoReturn:
    match code:
        case ExitCode.OK:
            log("Exited normally")
        case ExitCode.NO_CREDENTIALS:
            warn("No valid login credentials found, supply them via refresh token or username and password.")
        case ExitCode.NO_OWNERSHIP_TICKET:
            warn("Invalid ownership ticket supplied / fetched")
        case ExitCode.NO_AUTHENTICATION_TICKET:
            warn("Failed to generate valid authentication ticket")
    if code != ExitCode.NO_CREDENTIALS:
        await client.disconnect()
    raise SystemExit(code.value)

def save(data: str):
    if args.file:
        with open(args.file, 'w') as f:
            f.write(data + '\n')
    else:
        print(data)

# Argument parsing
parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=textwrap.dedent("""
        - Simple Steam App Authenticator -
    Generates and activates a session authentication ticket for the given app via Steam's API,
    this cancels any outstanding tickets for the same user/app pair, and expires in ~5 minutes.
    Login can be performed via refresh token or username + password, both of which can be supplied
    as arguments or as environment variables. An ASCII ownership ticket can be supplied, otherwise
    a new one will be generated, but they typically have a lifetime of 21 days so its recommended
    to cache them and pass them whenever possible. Requires Python 3.11+. See below for more info.
    Usage hint: Boolean flags are lower-case, flags that require a value are upper-case.
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

    For automated logins it's advised to use a refresh token. This will be fetched when you log
    in with username and password in verbose mode, and allows to re-login without providing them
    again. It's a Base64-encoded signed JWT (JSON Web Token) that expires in ~200 days and
    specifies your Steam ID and IP, among other fields.
    """)
)
parser.add_argument('app',              type=int,            help='Steam app ID (e.g. 440 for TF2)')
parser.add_argument('-B', '--branch',   type=str,            help='Branch name, for fetching build or manifest info')
parser.add_argument('-c', '--connect',  action='store_true', help='Stay connected after exporting tickets (will require an Interrupt to close)')
parser.add_argument('-D', '--depot',    type=int,            help='Depot ID, for fetching build or manifest info')
parser.add_argument('-d', '--dry',      action='store_true', help='Performs a dry run (logs in a verifies supplied ticket)')
parser.add_argument('-F', '--file',     type=str,            help='Export tickets to this file instead of STDOUT')
parser.add_argument('-i', '--info',     action='store_true', help='Only fetch game info, implies -d')
parser.add_argument('-M', '--manifest', type=int,            help='Manifest ID to fetch details from')
parser.add_argument('-O', '--ticket',   type=str,            help='App ownership ticket to attempt to reuse (also SSAA_TICKET)')
parser.add_argument('-P', '--password', type=str,            help='Steam password used for login (also SSAA_PASSWORD env var)')
parser.add_argument('-U', '--username', type=str,            help='Steam username used for login (also SSAA_USERNAME env var)')
parser.add_argument('-s', '--silent',   action='store_true', help='Supresses all STDOUT and STDERR output except for the ticket itself')
parser.add_argument('-T', '--token',    type=str,            help='Refresh token JWT used for login (also SSAA_TOKEN env var)')
parser.add_argument('-v', '--verbose',  action='store_true', help='Print additional technical information to the terminal')
args = parser.parse_args()

# It's very hard to properly catch exceptions inside async contexts and we need the
# terminal to be clean to export the ticket, so we optionally suppress STDERR to
# prevent exceptions raised when disconnecting from cluttering the terminal.
if args.silent:
    sys.stderr.flush()
    devnull = open(os.devnull, 'w')
    os.dup2(devnull.fileno(), sys.stderr.fileno())

USERNAME: str | None = args.username or os.environ.get('SSAA_USERNAME')
PASSWORD: str | None = args.password or os.environ.get('SSAA_PASSWORD')
TOKEN:    str | None = args.token    or os.environ.get('SSAA_TOKEN')
TICKET:   str | None = args.ticket   or os.environ.get('SSAA_TICKET')

def verify_token(token: str) -> bool:
    """Decode a token and perform some sanity checks"""
    dbg("Refresh token supplied:")
    dbg(token)
    header, payload = [json.loads(base64.urlsafe_b64decode(bytes(block + '==', 'utf-8'))) for block in token.split('.')[:2]]
    dbg(f"Header: {header}")
    dbg(f"Payload: {payload}")
    lower = datetime.datetime.fromtimestamp(payload['nbf'])
    upper = datetime.datetime.fromtimestamp(payload['exp'])
    now   = datetime.datetime.now()
    if not (lower <= now <= upper):
        warn(f"Refresh token is only valid between {date(lower)} and {date(upper)}")
        return False
    # No need to check Steam ID since we aren't logged in yet
    dbg(f"Refresh token issued {date(datetime.datetime.fromtimestamp(payload['iat']))} valid for {payload['sub']}@{payload['ip_subject']}, expires {date(upper)}")
    return True

if TOKEN and not verify_token(TOKEN):
    warn("Defaulting to username and password")
    TOKEN = None

class Bot(steam.Client):
    """Handle communications via Steamworks API using Gobot1234/steam.py"""

    # < ------------ EVENT HANDLERS ------------>

    async def on_connect(self) -> None:
        log(f"Connected to Steam")

    async def on_ready(self) -> None:
        log(f"Logged in as {self.user.name} ({self.user.id64})")
        self.log_tokens()
        if not TOKEN and args.verbose:
            dbg(f"Refresh token: {self.refresh_token}")
        app = self.get_app(args.app)
        await self.change_presence(app=app)

        # Fetch game info
        if args.info:
            save(json.dumps(await self.get_info(app)))
            await end()

        # Fetch manifest details
        if args.branch and args.depot and args.manifest:
            save(json.dumps(await self.get_manifest(app, args.branch, args.depot, args.manifest)))
            await end()

        # Reuse ownership ticket or fetch a new one
        ticket = await self.get_ownership_ticket(app)
        if not ticket:
            await end(ExitCode.NO_OWNERSHIP_TICKET)
        if args.dry:
            await end()

        # Build and activate ticket
        ticket = self.get_authentication_ticket(ticket)
        if not ticket:
            await end(ExitCode.NO_AUTHENTICATION_TICKET)
        log("Activating ticket...")
        await ticket.activate()

        # Export ticket
        save(serial(bytes(ticket)[4:]))

        if not args.connect:
            await end()

    async def on_disconnect(self) -> None:
        log(f"Disconnected from Steam")

    async def on_user_update(self, before: steam.User, after: steam.User, /) -> None:
        dbg(f"User {after.name} ({after.state.name}) updated: Playing {after.app}")

    async def on_error(self, event, error, *arg, **kwarg) -> None:
        warn(f"Received error: {event} ({error})")
        if not args.verbose:
            return
        exc_type, exc_val, exc_tb = sys.exc_info()
        traceback.print_exception(exc_type, exc_val, exc_tb)

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
            dbg(TICKET)
            try:
                ticket = bytes.fromhex(TICKET)
                ticket = steam.OwnershipTicket(self._state, steam.utils.StructIO(ticket))
                if self.verify_ticket(ticket):
                    self.log_ownership_ticket(ticket)
                    return ticket
            except:
                warn("Failed to parse supplied ownership ticket")

        # Otherwise, fetch a new ticket
        if args.dry:
            return
        log("Requesting new ownership ticket...")
        ticket = await self._state.fetch_app_ownership_ticket(app.id)
        dbg(serial(ticket))
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
            dbg(f"    {serial(token)} -> {gc:016x} {steam_id} {time(gen_time)}")

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

    # < ------------ INFO ------------>

    async def get_info(self, app: steam.app.PartialApp) -> dict:
        fetch_count        = False
        fetch_stats        = False
        fetch_info         = True
        fetch_achievements = False
        fetch_dlcs         = False
        fetch_packages     = False
        result = {}

        if fetch_count:
            log("Fetching player count...")
            result["players"] = await app.player_count() # int

        if fetch_stats:
            log("Fetching app stats...")
            stats = await app.stats() # AppStats
            result["stats"] = {
                "version": stats.version,
                "stats":   [
                    {
                        "name": s.name,
                        "display": s.display_name,
                        "default": s.default_value
                    } for s in stats.stats
                ]
            }

        if fetch_info:
            log("Fetching app info and branches...")
            info = await app.info() # AppInfo
            result["info"] = {
                "id":           info.id,
                "changenum":    info.change_number,
                "name":         info.name,
                "sha":          info.sha,
                "url":          info.website_url,
                "developers":   info.developers,
                "date":         date(info.created_at),
                "score":        info.review_score.name,
                "ratio":        info.review_percentage,
                "free":         info.is_free(),
                "platforms":    {"windows": info.is_on_windows(), "linux": info.is_on_linux(), "mac": info.is_on_mac_os()},
                "genres":       [{"id": g.id, "name": g.name} for g in info.genres],
                "categories":   [{"id": c.id, "name": c.name} for c in info.categories],
                "tags":         [{"id": t.id, "name": t.name} for t in info.tags]
            }
            result["branches"] = [
                {
                    "name":        b.name,
                    "build_id":    b.build_id,
                    "date":        date(b.updated_at),
                    "description": b.description,
                    "private":     b.password_required,
                    "password":    b.password,
                    "depots":      [
                        {
                            "id":             d.id,
                            "name":           d.name,
                            "max_size":       d.max_size,
                            "shared_install": d.shared_install,
                            "system_defined": d.system_defined,
                            "manifest":       d.manifest.id,
                            "config":         {k: d.config.getall(k) for k in set(d.config.keys())}

                        } for d in b.depots],
                    "manifests":   [
                        {
                            "id": m.id,
                            "name": m.name,
                            "depot": m.depot.id
                        } for m in b.manifests]
                } for b in info.branches
            ]

        if fetch_achievements:
            log("Fetching app achievements...")
            achs = await app.achievements() # List[AppAchivement]
            result["achievements"] = [
                {
                    "name":        a.name,
                    "display":     a.display_name,
                    "description": a.description,
                    "hidden":      a.hidden,
                    "ratio":       a.global_percent_unlocked
                } for a in achs
            ]

        if fetch_dlcs:
            log("Fetching app DLCs...")
            dlcs = await app.dlc() # List[DLC]
            result["dlcs"] = [
                {
                    "id":        dlc.id,
                    "name":      dlc.name,
                    "date":      date(dlc.created_at),
                    "free":      dlc.is_free,
                    "platforms": {"windows": dlc.is_on_windows(), "linux": dlc.is_on_linux(), "mac": dlc.is_on_mac_os()}

                } for dlc in dlcs
            ]

        if fetch_packages:
            log("Fetching app packages...")
            packages = await app.packages() # List[FetchedAppPackage]
            result["packages"] = [
                {
                    "id": p.id,
                    "name": p.name,
                    "url": p.url

                } for p in packages
            ]

        return result

    # TODO: Retrieve chunks for fine-grained statistics and diffing?
    async def get_manifest(self, app: steam.app.PartialApp, branch: str, depot_id: int, manifest_id: int) -> dict:
        log(f"Fetching manifest {manifest_id} from branch {branch} and depot {depot_id}...")
        manifest = await app.fetch_manifest(id=manifest_id, depot_id=depot_id, branch=branch)
        # Depot file flags bitmap:
        #   u (user config),  v (versioned user config),  e (encrypted),          r (read-only),       h (hidden),
        #   x (executable),   d (directory),              c (custom executable),  s (install script),  l (symbolic link)
        flags = ['u', 'v', 'e', 'r', 'h', 'x', 'd', 'c', 's', 'l']
        result = {
            "id":              manifest.id,
            "app":             manifest.app.id,
            "depot":           manifest.depot_id,
            "name":            manifest.name,
            "count":           len(manifest),
            "size_raw":        manifest.size_original,
            "size_compressed": manifest.size_compressed,
            "compressed":      manifest.compressed,
            "size":            manifest.size_compressed if manifest.compressed else manifest.size_original,
            "server":          manifest.server.url.human_repr(),
            "files":           [
                {
                    "path":        str(f),
                    "size":        f.size,
                    "flags":       [flag for i, flag in enumerate(flags) if int(f.flags.value) & (1 << i)],
                    "sha_name":    serial(f.sha_filename),
                    "sha_content": serial(f.sha_content)
                } for f in manifest.paths
            ]
        }
        return result

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
    if TOKEN:
        log("Logging in with refresh token...")
        client.run(refresh_token=TOKEN)
    elif USERNAME and PASSWORD:
        log("Logging in with username and password...")
        client.run(USERNAME, PASSWORD)
    else:
        warn("No valid login credentials found, supply them via refresh token or username and password.")
        raise SystemExit(ExitCode.NO_CREDENTIALS.value)
except* steam.gateway.ConnectionClosed:
    pass
finally:
    if not client.is_closed():
        asyncio.run(client.http.close()) # Close HTTP session