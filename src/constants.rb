# This file contains most of the variables that configure the behaviour of many
# features and aspects of the bot.
#
# When first setting up the bot it may be necessary, or at least recommended,
# to configure a few of these (e.g., BOTMASTER_ID, SERVER_ID, CHANNEL_HIGHSCORES,
# DATABASE...). Several others are useful to change during development as well
# (TEST, BENCHMARK, DO_NOTHING, DO_EVERYTHING...).

# <---------------------------------------------------------------------------->
# <------                    DEVELOPMENT VARIABLES                       ------>
# <---------------------------------------------------------------------------->

# General
TEST           = true  # Switch to the local test bot
BENCHMARK      = false # Benchmark and log functions (for optimization)
DO_NOTHING     = false # Don't execute any threads (see below for ind flags)
DO_EVERYTHING  = false # Execute all threads
RESPOND        = true  # Respond to pings / DMs (for testing)
DEBUG          = false # Breakpoint right after loading the bot

# Test specific features
TEST_REPORT    = false # Produces the report immediately once
TEST_LOTD      = false # Posts lotd immediately once
TEST_CTP_LOTD  = false # Posts CTP lotd immediately once
BENCH_IMAGES   = false # Benchmark image manipulation steps

# Internal
WAIT            = 1       # Seconds between iterations of infinite loops
DATABASE        = 'outte' # Database environment

# Memory
MEMORY_LIMIT    = 0.25    # Available memory (ratio) before restarting
MEMORY_USAGE    = 0.5     # Memory usage by outte (ratio) before restarting
MEMORY_CRITICAL = 0.05    # Critical memory available ratio
MEMORY_DELAY    = 5       # Seconds between memory checks during monitoring


# <---------------------------------------------------------------------------->
# <------                      NETWORK VARIABLES                         ------>
# <---------------------------------------------------------------------------->

OFFLINE_MODE   = false   # Disables most intensive online functionalities
OFFLINE_STRICT = false   # Disables all online functionalities of outte
RETRIES        = 50      # Redownload attempts for boards / demos
ATTEMPT_LIMIT  = 5       # Redownload attempts in general (bigger files)
INVALID_RESP   = '-1337' # N++'s server response when Steam ID is inactive

FAST_MANUAL = true # Only use active Steam IDs for manual queries, for speed
FAST_PERIOD = 7    # Days old until a Steam ID is marked as inactive

UPDATE_SCORES_ON_LOTD = true # Update scores right before lotd (may delay post)

# <---------------------------------------------------------------------------->
# <------                      DISCORD VARIABLES                         ------>
# <---------------------------------------------------------------------------->

# IDs
BOTMASTER_ID           = 204332624288677890  # User ID of the bot manager (Eddy)
SERVER_ID              = 197765375503368192  # Discord server/guild ID (N++ Server)
CHANNEL_HIGHSCORES     = 210778111594332181  # #highscores
CHANNEL_USERLEVELS     = 221721273405800458  # #userlevels
CHANNEL_NV2            = 197774025844457472  # #nv2
CHANNEL_CONTENT        = 197793786389200896  # #content-creation
CHANNEL_SECRETS        = 217283494664077312  # #secrets
CHANNEL_CTP_HIGHSCORES = 1137794057205198848 # #ctp-highscores
CHANNEL_CTP_SECRETS    = 1137794113475969034 # #ctp-secrets

# Limits
DISCORD_CHAR_LIMIT     = 2000                # Message character limit
DISCORD_FILE_LIMIT     = 25 * 1000 ** 2      # Attachment size limit
DELETE_TIMELIMIT       = 5 * 60              # Seconds to delete an outte post
CONFIRM_TIMELIMIT      = 30                  # Seconds to confirm a dialog

# Non-standard character widths in the monospaced font (for padding adjustments)
WIDTH_EMOJI = 2
WIDTH_KANJI = 1.67

# Despite the bot being public, so that the botmaster does not need to be a mod
# of the server, we only allow select servers. Otherwise randos could add outte.
SERVER_WHITELIST = [
  SERVER_ID,          # N++
  535635802386857995  # Test server
]

# Others
BOT_STATUS   = 'online'             # Discord status for the bot
BOT_ACTIVITY = "inne's evil cousin" # Discord activity for the bot
EMOJIS_TO_DELETE = [                # Emojis to delete msgs via reactions
  '❌', '✖️', '🇽', '⛔', '🚫'
]
EMOJIS_FOR_PLAY = [
  'Ninja', 'ninjajump', 'ninjavictory', 'nAight'
]

# <---------------------------------------------------------------------------->
# <------                      LOGGING VARIABLES                         ------>
# <---------------------------------------------------------------------------->

# General
LOG_TO_CONSOLE  = true  # Log stuff to the terminal
LOG_TO_FILE     = true  # Export logs to a file
LOG_TO_DISCORD  = true  # Log select stuff to the botmaster's Discord DMs
LOG_SQL         = false # Log _all_ SQL queries
LOG_SQL_TO_FILE = false # Log SQL queries to the logfile
LOG_REPORT      = true  # Export new weekly scores to a file
LOG_FILE_MAX    = 10 * 1024 ** 2 # Max log file size (10 MB)
LOG_SHELL       = false # Redirect STDOUT/STDERR to outte when we call the shell

# Log format (can be set on the fly as well)
LOG_FANCY      = true    # Use rich terminal logs (bold, colors...)
LOG_LEVEL      = :debug  # Default terminal logging level (see Log class)
LOG_LEVEL_FILE = :quiet  # Default file logging level (see Log class)
LOG_APPS       = false   # Append source app to log msgs
LOG_PAD        = 120     # Pad each log line to this many chars
LOG_BACKTRACES = true    # Log exception backtraces

# Log specific things
LOG_DOWNLOAD_ERRORS = false # Too spammy if no Steam IDs are active

# <---------------------------------------------------------------------------->
# <------                        PATH VARIABLES                          ------>
# <---------------------------------------------------------------------------->

DIR_DB            = './db'
DIR_MIGRATION     = "#{DIR_DB}/migrate"
CONFIG            = "#{DIR_DB}/config.yml"
DIR_MAPPACKS      = "#{DIR_DB}/mappacks"
PATH_MAPPACK_INFO = "#{DIR_MAPPACKS}/digest"

DIR_IMAGES    = './images'
PATH_AVATARS  = "#{DIR_IMAGES}/avatars"
PATH_PALETTES = "#{DIR_IMAGES}/palette.png"
PATH_OBJECTS  = "#{DIR_IMAGES}/object_layers"
PATH_TILES    = "#{DIR_IMAGES}/tile_layers"
PATH_BORDER   = "#{DIR_IMAGES}/b.png"

DIR_LOGS        = './logs'
PATH_LOG_FILE   = "#{DIR_LOGS}/log_outte"
PATH_LOG_SQL    = "#{DIR_LOGS}/log_outte_sql"
PATH_LOG_OLD    = "#{DIR_LOGS}/log_outte_old"
PATH_LOG_REPORT = "#{DIR_LOGS}/log_report"

DIR_SCREENSHOTS = "./screenshots"

DIR_SOURCE      = './src'

DIR_TEST        = './test'

DIR_UTILS       = './util'
PATH_NTRACE     = "#{DIR_UTILS}/ntrace.py"
PATH_SHA1       = "#{DIR_UTILS}/sha1"

DIR_FONTS       = "#{DIR_UTILS}/fonts"

FILENAME_MAPPACK_AUTHORS = 'AUTHORS'

# <---------------------------------------------------------------------------->
# <------               SCREENSHOT AND ANIMATION VARIABLES               ------>
# <---------------------------------------------------------------------------->

# The scale of the screenshots is measured in pixels per quarter tile. At normal
# 1080p resolution, the scale is 11 (44 pixels per tile).
SCREENSHOT_SCALE_LEVEL   = 11
SCREENSHOT_SCALE_EPISODE = 3
SCREENSHOT_SCALE_STORY   = 2

# Animation playback speed
ANIMATION_STEP_NORMAL  = 1   # How many frames to trace per GIF frame
ANIMATION_STEP_FAST    = 3
ANIMATION_STEP_VFAST   = 6
ANIMATION_DELAY_NORMAL = 2   # Time between GIF frames (min. 2)
ANIMATION_DELAY_SLOW   = 3
ANIMATION_DELAY_VSLOW  = 5

# Other animation parameters
ANIMATION_SCALE         = 4   # Scale of GIF
ANIMATION_RADIUS        = 6   # Radius of ninja balls in pixels
ANIMATION_EXHIBIT       = 100 # Showcase final frame for 1 second before looping
ANIMATION_EXHIBIT_INTER = 100 # Exhibit between levels (for multi-level animations)

# Input display for animations
ANIMATION_DEFAULT_INPUT = false # Whether to draw input displays by default
ANIMATION_WEDGE_WIDTH  = 3      # Semi-width of the wedge
ANIMATION_WEDGE_HEIGHT = 4      # Full height of the wedge
ANIMATION_WEDGE_SEP    = 2      # Separation between wedge and ninja marker
ANIMATION_WEDGE_WEIGHT = 2      # Thickness of the wedge

# Colors
TRANSPARENT_COLOR = 0x00FF00FF

# Fonts
FONT_TIMEBAR = 'retro'

# Other
ANIM_GC      = false # Garbage collect periodically when generating frames
ANIM_GC_STEP = 100   # How many frames to render before running the GC

# <---------------------------------------------------------------------------->
# <------                      FEATURE VARIABLES                         ------>
# <---------------------------------------------------------------------------->

FEATURE_NTRACE  = true # Enable SimVYo's ntrace tool (required Python 3)
FEATURE_ANIMATE = true # Enable animation for traces (requires FFmpeg)

# <---------------------------------------------------------------------------->
# <------                  MONKEY PATCHING VARIABLES                     ------>
# <---------------------------------------------------------------------------->

MONKEY_PATCH               = true # Enable monkey patches globally
MONKEY_PATCH_CORE          = true # Enable Kernel patches (must!)
MONKEY_PATCH_ACTIVE_RECORD = true # Enable ActiveRecord monkey patches (must!)
MONKEY_PATCH_DISCORDRB     = true # Enable Discordrb monkey patches (optional)
MONKEY_PATCH_WEBRICK       = true # Enable WEBrick monkey patches (optional)
MONKEY_PATCH_CHUNKYPNG     = true # Enable ChunkyPNG monkey patches (optional)

# <---------------------------------------------------------------------------->
# <------                       FORMAT VARIABLES                         ------>
# <---------------------------------------------------------------------------->

# Highscoreable ID patterns
LEVEL_PATTERN       = /([SCR][ILU]?-[ABCDEX]-[0-9][0-9]?-[0-9][0-9]?)|([?!]-[ABCDEX]-[0-9][0-9]?)/i
LEVEL_PATTERN_D     = /([SCR][ILU]?)-?([ABCDEX])-?([0-9][0-9]?)-?([0-9][0-9]?)|([?!])-?([ABCDEX])-?([0-9][0-9]?)/i
LEVEL_PATTERN_M     = /([A-Z]{3}-[SCR][ILU]?-[ABCDEX]-[0-9][0-9]?-[0-9][0-9]?)|([A-Z]{3}-[?!]-[ABCDEX]-[0-9][0-9]?)/i
LEVEL_PATTERN_M_D   = /([A-Z]{3})-?([SCR][ILU]?)-?([ABCDEX])-?([0-9][0-9]?)-?([0-9][0-9]?)|([A-Z]{3})-?([?!])-?([ABCDEX])-?([0-9][0-9]?)/i
EPISODE_PATTERN     = /([SCR][ILU]?-[ABCDEX]-[0-9][0-9]?)/i
EPISODE_PATTERN_D   = /([SCR][ILU]?)-?([ABCDEX])-?([0-9][0-9]?)/i
EPISODE_PATTERN_M   = /([A-Z]{3}-[SCR][ILU]?-[ABCDEX]-[0-9][0-9]?)/i
EPISODE_PATTERN_M_D = /([A-Z]{3})-?([SCR][ILU]?)-?([ABCDEX])-?([0-9][0-9]?)/i
STORY_PATTERN       = /([SCR][ILU]?)-?([0-9][0-9]?)/i
STORY_PATTERN_M     = /([A-Z]{3})-?([SCR][ILU]?)-?([0-9][0-9]?)/i

# Organize all possible highscoreable ID patterns into a hash
# (note dashes are irrelevant for stories, as there can be no ambiguity)
ID_PATTERNS = {
  'Level' => {
    vanilla: { dashed: LEVEL_PATTERN,     dashless: LEVEL_PATTERN_D     },
    mappack: { dashed: LEVEL_PATTERN_M,   dashless: LEVEL_PATTERN_M_D   },
  },
  'Episode' => {
    vanilla: { dashed: EPISODE_PATTERN,   dashless: EPISODE_PATTERN_D   },
    mappack: { dashed: EPISODE_PATTERN_M, dashless: EPISODE_PATTERN_M_D },
  },
  'Story' => {
    vanilla: { dashed: STORY_PATTERN,     dashless: STORY_PATTERN       },
    mappack: { dashed: STORY_PATTERN_M,   dashless: STORY_PATTERN_M     },
  }
}

# Input
NAME_PATTERN = /(for|of) (.*)[\.\?]?/i
MAX_ENTRIES  = 20 # maximum number of entries on methods with user input, to avoid spam

# Output
NUM_ENTRIES     = 20   # number of entries to show on most methods
SCORE_PADDING   =  0   #         fixed    padding, 0 for no fixed padding
DEFAULT_PADDING = 15   # default variable padding, never make 0
MAX_PADDING     = 15   # max     variable padding, 0 for no maximum
MAX_PAD_GEN     = 80   # max padding for general strings (not player names)
TRUNCATE_NAME   = true # truncate name when it exceeds the maximum padding

# Dates
DATE_FORMAT_NPP   = "%Y-%m-%d-%H:%M"       # Date format used by N++
DATE_FORMAT_OUTTE = "%Y/%m/%d %H:%M"       # Date format used by outte
DATE_FORMAT_MYSQL = "%Y-%m-%d %H:%M:%S"    # Date format required by MySQL
DATE_FORMAT_LOG   = "%Y/%m/%d %H:%M:%S.%L" # Date format used for terminal logs

# <---------------------------------------------------------------------------->
# <------                    USERLEVEL VARIABLES                         ------>
# <---------------------------------------------------------------------------->

MIN_U_SCORES = 20    # Minimum number of userlevel highscores to appear in average rankings
MIN_G_SCORES = 500   # Minimum number of userlevel highscores to appear in global average rankings
PAGE_SIZE    = 10    # Number of userlevels to show when browsing
PART_SIZE    = 500   # Number of userlevels per file returned by the server when querying levels
MIN_ID       = 22715 # ID of the very first userlevel, to exclude Metanet levels

# Userlevel query types
QT_SI                                  =  0 # (Metanet only)
QT_S                                   =  1 # (Metanet only)
QT_SL                                  =  2 # (Metanet only)
QT_SS                                  =  3 # (Metanet only)
QT_SU                                  =  4 # (Metanet only)
QT_SS2                                 =  5 # (Metanet only)
QT_DLC                                 =  6 # (Metanet only) (Not used)
QT_BEST                                =  7
QT_FEATURED                            =  8
QT_TOP_WEEKLY                          =  9
QT_NEWEST                              = 10
QT_HARDEST                             = 11
QT_MINE_BY_FAVS                        = 12
QT_MINE_BY_DATE                        = 13
QT_FAVED_BY_DATE                       = 14
QT_FAVED_BY_FAVS                       = 15
QT_POPULAR                             = 16 # (Not used)
QT_PLAYED_RECENTLY                     = 17 # (Not used)
QT_MADE_BY_FRIENDS_BY_DATE             = 18
QT_MADE_BY_FRIENDS_BY_FAVS             = 19
QT_PLAYED_BY_FRIENDS                   = 20 # (Not used)
QT_FAVED_BY_FRIENDS                    = 21
QT_TRACKED_BY_FRIENDS_BY_DATE          = 22
QT_TRACKED_BY_FRIENDS_BY_RANK          = 23
QT_TRACKED_BY_FRIENDS_BY_RANK_SCORED   = 24
QT_TRACKED_BY_FRIENDS_BY_RANK_UNSCORED = 25
QT_TRACKED_BY_DATE                     = 26
QT_TRACKED_BY_RANK                     = 27 # (Not used)
QT_TRACKED_BY_RANK_SCORED              = 28 # (Not used)
QT_TRACKED_BY_RANK_UNSCORED            = 29 # (Not used)
QT_FOLLOWING_BY_DATE                   = 30
QT_FOLLOWING_BY_FAVS                   = 31
QT_SEARCH_BY_AUTHOR_1                  = 32 # (Not used)
QT_SEARCH_BY_AUTHOR_2                  = 33 # (Not used)
QT_SEARCH_BY_AUTHOR_3                  = 34 # (Not used)
QT_SEARCH_BY_AUTHOR_4                  = 35 # (Not used)
QT_SEARCH_BY_TITLE                     = 36

# Mapping for each QT we care about
#     'name'     - Internal name used to identify each tab.
#     'fullname' - Display name of tab
#     'update'   - Determines whether we update our db's tab info.
#     'size'     - Determines how many maps from each tab to update.
USERLEVEL_TABS = {
  QT_NEWEST     => { name: 'all',      fullname: 'All',        size:   -1, update: false }, # keep first
  QT_BEST       => { name: 'best',     fullname: 'Best',       size: 1000, update: true  },
  QT_FEATURED   => { name: 'featured', fullname: 'Featured',   size:   -1, update: true  },
  QT_TOP_WEEKLY => { name: 'top',      fullname: 'Top Weekly', size: 1000, update: true  },
  QT_HARDEST    => { name: 'hardest',  fullname: 'Hardest',    size: 1000, update: true  }
}

USERLEVEL_REPORT_SIZE = 500       # Number of userlevels to include in daily rankings
INVALID_NAMES = [nil, "null", ""] # Names that correspond to invalid players

NPP_CACHE_DURATION   = 5            # N++'s cache duration in seconds for userlevel queries
OUTTE_CACHE_DURATION = 24 * 60 * 60 # Ditto, but the one outte uses in its database
OUTTE_CACHE_LIMIT    = 1024         # Max entries in outte's userlevel cache

# <---------------------------------------------------------------------------->
# <------                        JOKE VARIABLES                          ------>
# <---------------------------------------------------------------------------->

POTATO         = true               # joke they have in the nv2 channel
POTATO_RATE    = 1                  # seconds between potato checks
POTATO_FREQ    = 3 * 60 * 60        # 3 hours between potato delivers
MISHU          = true               # MishNUB joke
MISHU_COOLDOWN = 30 * 60            # MishNUB cooldown
COOL           = true               # Emoji for CKC in leaderboards
FOOD           = [                  # Emojis for the potato joke
  ':potato:',
  ':tomato:',
  ':eggplant:',
  ':peach:',
  ':carrot:',
  ':pineapple:',
  ':cucumber:',
  ':cheese:'
]

# <---------------------------------------------------------------------------->
# <------                        TASK VARIABLES                          ------>
# <---------------------------------------------------------------------------->

# Individual flags for each thread / task
UPDATE_STATUS      = false # Thread to regularly update the bot's status
UPDATE_TWITCH      = false # Thread to regularly look up N related Twitch streams
UPDATE_SCORES      = false # Thread to regularly download Metanet's scores
UPDATE_HISTORY     = false # Thread to regularly update highscoring histories
UPDATE_DEMOS       = false # Thread to regularly download missing Metanet demos
UPDATE_LEVEL       = false # Thread to regularly publish level of the day
UPDATE_EPISODE     = false # Thread to regularly publish episode of the week
UPDATE_STORY       = false # Thread to regularly publish column of the month
UPDATE_CTP_LEVEL   = false # Thread to regularly publish CTP level of the day
UPDATE_CTP_EPISODE = false # Thread to regularly publish CTP episode of the week
UPDATE_CTP_STORY   = false # Thread to regularly publish CTP column of the month
UPDATE_USERLEVELS  = false # Thread to regularly download newest userlevel scores
UPDATE_USER_GLOB   = false # Thread to continuously (but slowly) download all userlevel scores
UPDATE_USER_HIST   = false # Thread to regularly update userlevel highscoring histories
UPDATE_USER_TABS   = false # Thread to regularly update userlevel tabs (best, featured, top, hardest)
REPORT_METANET     = false # Thread to regularly post Metanet's highscoring report
REPORT_USERLEVELS  = false # Thread to regularly post userlevels' highscoring report

# Update frequencies for each task, in seconds
STATUS_UPDATE_FREQUENCY     =             5 * 60
TWITCH_UPDATE_FREQUENCY     =                 60
HIGHSCORE_UPDATE_FREQUENCY  =       24 * 60 * 60
HISTORY_UPDATE_FREQUENCY    =       24 * 60 * 60
DEMO_UPDATE_FREQUENCY       =       24 * 60 * 60
LEVEL_UPDATE_FREQUENCY      =       24 * 60 * 60
EPISODE_UPDATE_FREQUENCY    =   7 * 24 * 60 * 60
STORY_UPDATE_FREQUENCY      =  30 * 24 * 60 * 60 # Not used (published 1st of each month)
CTP_LEVEL_FREQUENCY         =       24 * 60 * 60
CTP_EPISODE_FREQUENCY       =   7 * 24 * 60 * 60
CTP_STORY_FREQUENCY         =  30 * 24 * 60 * 60 # Not used (published 1st of each month)
REPORT_UPDATE_FREQUENCY     =       24 * 60 * 60
REPORT_UPDATE_SIZE          =   7 * 24 * 60 * 60
SUMMARY_UPDATE_SIZE         =   1 * 24 * 60 * 60
USERLEVEL_SCORE_FREQUENCY   =       24 * 60 * 60
USERLEVEL_UPDATE_RATE       =                  5
USERLEVEL_HISTORY_FREQUENCY =       24 * 60 * 60
USERLEVEL_REPORT_FREQUENCY  =       24 * 60 * 60
USERLEVEL_TAB_FREQUENCY     =       24 * 60 * 60
USERLEVEL_DOWNLOAD_CHUNK    =                100

# <---------------------------------------------------------------------------->
# <------                       TWITCH VARIABLES                         ------>
# <---------------------------------------------------------------------------->

TWITCH_ROLE      = "Voyeur"    # Discord role to ping when a new stream happens
TWITCH_COOLDOWN  = 2 * 60 * 60 # Cooldown to ping stream by the same user
TWITCH_BLACKLIST = [           # Should probably use IDs instead of usernames here
  "eblan4ikof"
]

# <---------------------------------------------------------------------------->
# <------                       SOCKET VARIABLES                         ------>
# <---------------------------------------------------------------------------->

# Variables that control the TCP server that outte starts in order to provide
# custom functionality to N++ players:
#
# 1) CUSE - Custom Userlevel Search Engine
#    Generates custom userlevel searches that users with the corresponding tool
#    can inject directly into their N++ game to expand the native searching
#    functionalities by using outte's database of userlevels.
# 2) CLE - Custom Leaderboard Engine
#    Provides 3rd party leaderboards hosted in outte's database, that people
#    with the corresponding tool can connect to, so they can highscore custom
#    mappacks.

SOCKET      = true  # Whether to open sockets or not
SOCKET_PORT = 8126  # Port for CLE's TCP server
SOCKET_LOG  = false # Log request and response details

# CUSE-specific variables
QUERY_LIMIT_SOFT = 25   # Number of queried userlevels per page
QUERY_LIMIT_HARD = 500  # Maximum number of queried userlevels per page

# CLE-specific variables
PWD              = ENV['NPP_HASH']
CLE_FORWARD      = true            # Forward unrelated requests to Metanet
INTEGRITY_CHECKS = false           # Verity replay security hashes
WARN_VERSION     = false           # Warning for score submissions with old map versions
LOCAL_LOGIN      = true            # Try to login user ourselves if Metanet fails
HASH_INPUT_FN    = 'hash_in'       # Filename for SHA1 util to read
HASH_OUTPUT_FN   = 'hash_out'      # Filename for SHA1 util to write

# <---------------------------------------------------------------------------->
# <------                        GAME VARIABLES                          ------>
# <---------------------------------------------------------------------------->

APP_ID              = 230270     # N++'s Steam app ID
BOTMASTER_NPP_ID    = 54303      # Botmaster's N++ player ID
OUTTE_ID            = 361131     # outte's N++ player ID
OUTTE_STEAM_ID      = '76561199562076498'
MIN_REPLAY_ID       = 131072     # Minimum replay ID for the game to perform the HTTP request
MAGIC_EPISODE_VALUE = 0xffc0038e # First 4 bytes of a decompressed episode replay
MAGIC_STORY_VALUE   = 0xff3800ce # First 4 bytes of a decompressed story replay

# Mode stuff
MODE_SOLO = 0
MODE_COOP = 1
MODE_RACE = 2
MODE_HC   = 3
MODES = {
  -1        => "all",
  MODE_SOLO => "solo",
  MODE_COOP => "coop",
  MODE_RACE => "race"
}


# Type stuff
TYPE_LEVEL   = 0
TYPE_EPISODE = 1
TYPE_STORY   = 2

# Properties of the different playing types
#   id         - Internal game index for the type
#   name       - Name of the type AND of the Rails model class
#   slots      - IDs reserved by N++ to this mode in the db
#   min_scores - Max-min amount of scores to be taken into consideration for average rankings
#   qt         - Query type, index used by the game for server communications
#   rt         - Replay type, used for replay headers
#   size       - How many levels this type contains
TYPES = {
  'Level' => {
    id:         TYPE_LEVEL,
    name:       'Level',
    slots:      20000,
    min_scores: 100,
    qt:         0,
    rt:         0,
    size:       1
  },
  'Episode' => {
    id:         TYPE_EPISODE,
    name:       'Episode',
    slots:      4000,
    min_scores: 50,
    qt:         1,
    rt:         1,
    size:       5
  },
  'Story' => {
    id:         TYPE_STORY,
    name:       'Story',
    slots:      800,
    min_scores: 10,
    qt:         4,
    rt:         0,
    size:       25
  }
}

# Tab stuff
TAB_INTRO           = 0
TAB_NPP             = 1
TAB_LEGACY          = 2
TAB_SECRET          = 3
TAB_ULTIMATE        = 4
TAB_SECRET_ULTIMATE = 5
TAB_DLC             = 6

# @par1: ID ranges for levels and episodes
# @par2: Score limits to filter new hacked scores
# @par3: Number of scores required to enter the average rank/point rankings of tab
TABS = {
  "Episode" => {
    :SI => [ (  0.. 24).to_a, 400,  5],
    :S  => [ (120..239).to_a, 950, 25],
    :SL => [ (240..359).to_a, 650, 25],
    :SU => [ (480..599).to_a, 650, 25]
  },
  "Level" => {
    :SI  => [ (  0..  124).to_a,  298, 25],
    :S   => [ ( 600..1199).to_a,  874, 50],
    :SL  => [ (1200..1799).to_a,  400, 50],
    :SS  => [ (1800..1919).to_a, 2462, 25],
    :SU  => [ (2400..2999).to_a,  530, 50],
    :SS2 => [ (3000..3119).to_a,  322, 25]
  },
  "Story" => {
    :SI => [ ( 0..  4).to_a, 1000, 1],
    :S  => [ (24.. 43).to_a, 2000, 5],
    :SL => [ (48.. 67).to_a, 2000, 5],
    :SU => [ (96..115).to_a, 1500, 5]
  }
}

# TODO: Add the stuff in TABS to TABS_NEW, then use TABS_NEW wherever TABS is
# is being used and also in parse_tabs, then delete TABS and rename TABS_NEW to TABS

# All tab information.
TABS_NEW = {
  SI: {
    code:   'SI',
    mode:   MODE_SOLO,
    tab:    TAB_INTRO,
    index:  0,
    name:   'Intro',
    start:  0,
    size:   125,
    files:  { 'SI' => 125 },
    x:      false,
    secret: false
  },
  S: {
    code:   'S',
    mode:   MODE_SOLO,
    tab:    TAB_NPP,
    index:  1,
    name:   'Solo',
    start:  600,
    size:   600,
    files:  { 'S' => 600 },
    x:      true,
    secret: false
  },
  SL: {
    code:   'SL',
    mode:   MODE_SOLO,
    tab:    TAB_LEGACY,
    index:  3,
    name:   'Legacy',
    start:  1200,
    size:   600,
    files:  { 'SL' => 600 },
    x:      true,
    secret: false
  },
  SS: {
    code:   '?',
    mode:   MODE_SOLO,
    tab:    TAB_SECRET,
    index:  4,
    name:   'Secret',
    start:  1800,
    size:   120,
    files:  { 'SS' => 120 },
    x:      true,
    secret: true,
  },
  SU: {
    code:   'SU',
    mode:   MODE_SOLO,
    tab:    TAB_ULTIMATE,
    index:  2,
    name:   'Ultimate',
    start:  2400,
    size:   600,
    files:  { 'S2' => 600 },
    x:      true,
    secret: false
  },
  SS2: {
    code:   '!',
    mode:   MODE_SOLO,
    tab:    TAB_SECRET_ULTIMATE,
    index:  5,
    name:   'Ultimate Secret',
    start:  3000,
    size:   120,
    files:  { 'SS2' => 120 },
    x:      true,
    secret: true
  },
  CI: {
    code:   'CI',
    mode:   MODE_COOP,
    tab:    TAB_INTRO,
    index:  0,
    name:   'Coop Intro',
    start:  4200,
    size:   50,
    files:  { 'CI' => 50 },
    x:      false,
    secret: false
  },
  C: {
    code:   'C',
    mode:   MODE_COOP,
    tab:    TAB_NPP,
    index:  1,
    name:   'Coop',
    start:  4800,
    size:   600,
    files:  { 'C' => 300, 'C2' => 300 },
    x:      true,
    secret: false
  },
  CL: {
    code:   'CL',
    mode:   MODE_COOP,
    tab:    TAB_LEGACY,
    index:  2,
    name:   'Coop Legacy',
    start:  5400,
    size:   330,
    files:  { 'CL' => 120, 'CL2' => 210 },
    x:      true,
    secret: false
  },
  RI: {
    code:   'RI',
    mode:   MODE_RACE,
    tab:    TAB_INTRO,
    index:  0,
    name:   'Race Intro',
    start:  8400,
    size:   25,
    files:  { 'RI' => 25 },
    x:      false,
    secret: false
  },
  R: {
    code:   'R',
    mode:   MODE_RACE,
    tab:    TAB_NPP,
    index:  1,
    name:   'Race',
    start:  9000,
    size:   600,
    files:  { 'R' => 300, 'R2' => 300 },
    x:      true,
    secret: false
  },
  RL: {
    code:   'RL',
    mode:   MODE_RACE,
    tab:    TAB_LEGACY,
    index:  2,
    name:   'Race Legacy',
    start:  9600,
    size:   570,
    files:  { 'RL' => 120, 'RL2' => 450 },
    x:      true,
    secret: false
  }
}

# <---------------------------------------------------------------------------->
# <------                     HIGHSCORING VARIABLES                      ------>
# <---------------------------------------------------------------------------->

DEFAULT_TYPES  = ['Level', 'Episode'] # Default highscoreable types
MAX_TRACES = 4 # Maximum amount of simultaneous replays to trace

MIN_TIES = 3 # Minimum number of ties for 0th to be considered maxable
MAX_SECS = 5 # Difference in seconds to consider two dates equal (for navigation)
MAXMIN_SCORES = 100   # max-min number of highscores to appear in average point rankings

# Different ranking types
# * For parsing, 'top1' (i.e. 0th) will be removed (default)
# * For formatting, 'top1' will be changed to '0th'
RTYPES = [
  'top1',
  'top5',
  'top10',
  'top20',
  'average_rank',
  'score',
  'cool',
  'star',
  'maxed',
  'maxable',
  'G++',
  'G--',
  'tied_top1',
  'singular_top1',
  'plural_top1',
  'average_top1_lead',
  'point',
  'average_point'
]

# TODO: Move Dan and crit to PATCH_IND_DEL, they're not cheaters

# Players blacklisted from the leaderboards (hackers and cheaters)
# Keys are the user IDs, values are their known usernames
BLACKLIST = {
   63944 => ["Kronogenics"],
   72791 => ["Jett Altair"],
   75839 => ["vorcazm", "Treagus"],
   76223 => ["TylerDC"],
  107118 => ["Tabby_Cxt"],
  115572 => ["Mishu"],
  122681 => ["nietske"],
  128613 => ["cock unsucker"],
  135161 => ["Apjue"],
  146275 => ["Puce"],
  173617 => ["You have been banned."],
  201322 => ["dimitry008"],
  202167 => ["crit a cola drinker"],
  221472 => ["VexatiousCheff", "vex"],
  243184 => ["Player"],
  253072 => ["test8378"],
  253161 => ["Chara"],
  276273 => ["DBYT3"],
  291743 => ["Yup_This_Is_My_Name"],
  298531 => ["Boringfish"],
  307030 => ["The_Mega_Force"],
  325245 => ["Staticwork"],
  326339 => ["Psina"],
  336069 => ["Progressively idle"]
}

# Additional blacklisted names whose ID we don't know, since their scores
# were cleaned long ago (we still hold a grudge tho)
BLACKLIST_NAMES = [
  "BlueIsTrue",
  "fiordhraoi",
  "cheeseburgur101",
  "Jey",
  "jungletek",
  "Hedgy",
  "ᕈᘎᑕᒎᗩn ᙡiᗴᒪḰi",
  "Venom",
  "EpicGamer10075",
  "Altii",
  "Floof The Goof",
  "Prismo"
]

# Patched runs from legitimate players because they were done
# with older versions of levels and the scores are now incorrect.
# @params: maximum replay id of incorrect scores, score adjustment required
PATCH_RUNS = {
  :episode => {
    182 => [695142, -42], #  S-C-12
    217 => [1165074, -8], #  S-C-19
    509 => [2010381, -6]  # SU-E-05
  },
  :level => {
     910 => [286360, -42], #  S-C-12-00
    1089 => [225710,  -8], #  S-C-19-04
    2549 => [2000000, -6]  # SU-E-05-04
  },
  :story => {
  },
  :userlevel => {
  }
}

# Delete individual runs
PATCH_IND_DEL = {
  :episode   => [
    5035576, # proxy17585's SI-C-00
    5073211  # HamSandwich's SI-D-00
  ],
  :level     => [
    3572785, # SuperVolcano's S-B-00-01
    3622469  # HamSandwich's S-B-00-02
  ],
  :story     => [],
  :userlevel => [
    2649242  # ekisacik's run in 68214
  ]
}

# Patch individual runs (by changing score)
PATCH_IND_CHG = {
  :episode   => {
    5067031 => -6 # trance's SU-E-05
  },
  :level     => {
    3758900 => -6 # trance's SU-E-05-04
  },
  :story     => {},
  :userlevel => {}
}
