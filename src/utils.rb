# This file compiles a general library of diverse functions that can be useful
# throughout the entire program:
#
#  1) Logging:
#       A custom and configurable logging class, with different levels and modes,
#       that can log timestamped text to the terminal, to a file, and to Discord.
#  2) Exception handling:
#       Defines a custom exception class, OutteError, which is printed to Discord
#       whenever raised. Intended for user errors.
#  3) Networking:
#       Getting arbitrary data from N++'s server using Steam IDs, forwarding
#       requests and acting as a middleman, building multipart POSTs, ...
#  4) System operations:
#       Forking, threading, inkoving the shell, getting memory information for
#       maintenance, etc.
#  5) Benchmarking:
#       Functions to benchmark code, perform memory profiling, etc.
#  6) String manipulation:
#       Converting between formats (ASCII, UTF8, ...), string escaping/unescaping,
#       string sanitization (for filenames, SQL, ...), string truncation/padding,
#       string distance (Damerau-Levenshtein), etc.
#  7) Binary manipulation:
#       Basically packing and unpacking binary data into/from strings.
#  8) Discord related:
#       Finding Discord users, channels, servers, emojis, etc. Pinging users,
#       reacting or unreacting to comments, mentioning channels... Formatting
#       strings (as code blocks, spoilers, ...), etc.
#  9) N++ specific:
#       Stuff like sanitizing parameters for N++ functions, finding maximum values
#       for rankings, calculating episode splits, or computing a highscoreable's
#       name from its ID.
# 10) Graphics:
#       Generating SVG plots from a dataset.
# 11) Bot management:
#       Permission system for commands with custom roles, setting the bot's main
#       channels, leaving blacklisted servers, restarting the bot, etc.
# 12) Other:
#       Random assortment of functions, like computing a SHA1 hash, zipping and
#       unzipping files, making a text table, etc.

require 'active_record'
require 'damerau-levenshtein'
require 'digest'
require 'net/http'
require 'unicode/emoji'
require 'zip'

require_relative 'constants.rb'
require_relative 'models.rb'

# <---------------------------------------------------------------------------->
# <------                           LOGGING                              ------>
# <---------------------------------------------------------------------------->

if LOG_SQL
  ActiveRecord::Base.logger = ActiveSupport::Logger.new(STDOUT)
  if LOG_SQL_TO_FILE
    ActiveRecord::Base.logger.extend(
      ActiveSupport::Logger.broadcast(
        ActiveSupport::Logger.new(PATH_LOG_SQL)
      )
    )
  end
end

# Custom logging class, that supports:
#   - 9 modes (info, error, debug, etc)
#   - 5 levels of verbosity (from silent to all)
#   - 3 outputs (terminal, file and Discord DMs)
#   - Both raw and rich format (colored, unicode, etc)
#   - Methods to config it on the fly from Discord
module Log

  MODES = {
    fatal: { long: 'FATAL', short: 'F', fmt: "\x1B[41m" }, # Red background
    error: { long: 'ERROR', short: '✗', fmt: "\x1B[31m" }, # Red
    warn:  { long: 'WARN' , short: '!', fmt: "\x1B[33m" }, # Yellow
    good:  { long: 'GOOD' , short: '✓', fmt: "\x1B[32m" }, # Green
    info:  { long: 'INFO' , short: 'i', fmt: ""         }, # Normal
    msg:   { long: 'MSG'  , short: 'm', fmt: "\x1B[34m" }, # Blue
    in:    { long: 'IN'   , short: '←', fmt: "\x1B[35m" }, # Magenta
    out:   { long: 'OUT'  , short: '→', fmt: "\x1B[36m" }, # Cyan
    debug: { long: 'DEBUG', short: 'D', fmt: "\x1B[90m" }  # Gray
  }

  LEVELS = {
    silent: [],
    quiet:  [:fatal, :error, :warn],
    normal: [:fatal, :error, :warn, :good, :info, :msg],
    debug:  [:fatal, :error, :warn, :good, :info, :msg, :debug],
    all:    [:fatal, :error, :warn, :good, :info, :msg, :debug, :in, :out]
  }

  BOLD  = "\x1B[1m"
  RESET = "\x1B[0m"

  @fancy = LOG_FANCY
  @modes = LEVELS[LOG_LEVEL] || LEVELS[:normal]
  @modes_file = LEVELS[LOG_LEVEL_FILE] || LEVELS[:quiet]

  def self.fmt(str, mode)
    "#{MODES[mode][:fmt]}#{str}#{RESET}"
  end

  def self.bold(str)
    "#{BOLD}#{str}#{RESET}"
  end

  def self.level(l)
   return dbg("Logging level #{l} does not exist") if !LEVELS.key?(l)
    @modes = LEVELS[l]
    dbg("Changed logging level to #{l.to_s}")
  rescue
    dbg("Failed to change logging level")
  end

  def self.fancy
    @fancy = !@fancy
    @fancy ? dbg("Enabled fancy logs") : dbg("Disabled fancy logs")
  rescue
    dbg("Failed to change logging fanciness")
  end

  def self.set_modes(modes)
    @modes = modes.select{ |m| MODES.key?(m) }
    dbg("Set logging modes to #{@modes.join(', ')}.")
  rescue
    dbg("Failed to set logging modes")
  end

  def self.change_modes(modes)
    added = []
    removed = []
    modes.each{ |m|
      next if !MODES.key?(m)
      if !@modes.include?(m)
        @modes << m
        added << m
      else
        @modes.delete(m)
        removed << m
      end
    }
    ret = []
    ret << "added logging modes #{added.join(', ')}" if !added.empty?
    ret << "removed logging modes #{removed.join(', ')}" if !removed.empty?
    dbg(ret.join("; ").capitalize)
  rescue
    dbg("Failed to change logging modes")
  end

  def self.modes
    @modes
  end

  # Main function to log text
  def self.write(
    text,            # The text to log
    mode,            # The type of log (info, error, debug, etc)
    app = 'BOT',     # The origin of the log (outte, discordrb, webrick, etc)
    newline:  true,  # Add a newline at the end or not
    pad:      false, # Pad each line of the text to a fixed width
    progress: false, # Progress log line (pad + no newline)
    fancy:    nil,   # Use rich logs (color, bold, etc)
    console:  true,  # Log to the console
    file:     true,  # Log to the log file
    discord:  false, # Log to the botmaster's DMs in Discord
    event:    nil    # Log to the Discord's channel, if any
  )
    # Return if we don't need to log anything
    mode = :info if !MODES.key?(mode)
    log_to_console = LOG_TO_CONSOLE && console && @modes.include?(mode)
    log_to_file    = LOG_TO_FILE    && file    && @modes_file.include?(mode)
    log_to_discord = LOG_TO_DISCORD && discord
    return text if !log_to_console && !log_to_file && !log_to_discord && !event

    # Determine parameters
    fancy = @fancy if ![true, false].include?(fancy)
    fancy = false if !LOG_FANCY
    stream = STDOUT
    stream = STDERR if [:fatal, :error, :warn].include?(mode)
    pad, newline = true, false if progress
    m = MODES[mode] || MODES[:info]

    # Message prefixes (timestamp, symbol, source app)
    date = Time.now.strftime(DATE_FORMAT_LOG)
    type = {
      fancy: bold(fmt(m[:short], mode)),
      plain: "[#{m[:long]}]".ljust(7, ' ')
    }
    app = " (#{app.ljust(3, ' ')[0...3]})"
    app = {
      fancy: LOG_APPS ? bold(app) : '',
      plain: LOG_APPS ? app : ''
    }

    # Format text
    header = {
      fancy: "[#{date}] #{type[:fancy]}#{app[:fancy]} ",
      plain: "[#{date}] #{type[:plain]}#{app[:plain]} ",
    }
    lines = {
      fancy: text.split("\n").map{ |l| (header[:fancy] + fmt(l, mode)).strip },
      plain: text.split("\n").map{ |l| (header[:plain] + l).strip }
    }
    lines = {
      fancy: lines[:fancy].map{ |l| l.ljust(LOG_PAD, ' ') },
      plain: lines[:plain].map{ |l| l.ljust(LOG_PAD, ' ') }
    } if pad
    msg = {
      fancy: "\r" + lines[:fancy].join("\n"),
      plain: "\r" + lines[:plain].join("\n")
    }

    # Log to the terminal, if specified
    if log_to_console
      t_msg = fancy ? msg[:fancy] : msg[:plain]
      newline ? stream.puts(t_msg) : stream.print(t_msg)
      stream.flush
    end

    # Log to a file, if specified and possible
    if log_to_file
      if File.size?(PATH_LOG_FILE).to_i >= LOG_FILE_MAX
        File.rename(PATH_LOG_FILE, PATH_LOG_OLD)
        warn("Log file was filled!", file: false, discord: true)
      end
      File.write(PATH_LOG_FILE, msg[:plain].strip + "\n", mode: 'a')
    end

    # Log to Discord DMs, if specified
    discord(text) if log_to_discord
    send_message(event, content: text, edit: false) if event

    # Return original text
    text
  rescue => e
    puts "Failed to log text: #{e.message}"
    puts e.backtrace.join("\n") if LOG_BACKTRACES
  ensure
    exit if mode == :fatal
  end

  # Handle exceptions
  def self.exception(e, msg = '', **kwargs)
    write(msg, :error, **kwargs)
    write(e.message, :error)
    write(e.backtrace.join("\n"), :debug) if LOG_BACKTRACES
    msg
  end

  # Send DM to botmaster
  def self.discord(msg)
    send_message(botmaster.pm, content: msg) if LOG_TO_DISCORD rescue nil
  end

  # Clear the current terminal line
  def self.clear
    write(' ' * LOG_PAD, :info, newline: false, pad: true)
  end
end

# Shortcuts for different logging methods
def log   (msg, **kwargs)    Log.write(msg, :info,  **kwargs) end
def warn  (msg, **kwargs)    Log.write(msg, :warn,  **kwargs) end
def err   (msg, **kwargs)    Log.write(msg, :error, **kwargs) end
def msg   (msg, **kwargs)    Log.write(msg, :msg,   **kwargs) end
def succ  (msg, **kwargs)    Log.write(msg, :good,  **kwargs) end
def dbg   (msg, **kwargs)    Log.write(msg, :debug, **kwargs) end
def lin   (msg, **kwargs)    Log.write(msg, :in,    **kwargs) end
def lout  (msg, **kwargs)    Log.write(msg, :out,   **kwargs) end
def fatal (msg, **kwargs)    Log.write(msg, :fatal, **kwargs) end
def lex   (e, msg, **kwargs) Log.exception(e, msg, **kwargs)  end
def ld    (msg)              Log.discord(msg)                 end

# <---------------------------------------------------------------------------->
# <------                     EXCEPTION HANDLING                         ------>
# <---------------------------------------------------------------------------->

# Custom exception classes.
#   Note: We inherit from Exception, rather than StandardError, because that
#   way they will go past normal "rescues"

# Used when there is user error, its message gets sent to Discord by default.
#   log     - Log message to terminal
#   discord - Log message to Discord
class OutteError < Exception
  attr_reader :log, :discord

  def initialize(msg = 'Unknown outte error', log: false, discord: true)
    @discord = discord
    @log = log
    super(msg)
  end
end

def perror(msg = '', log: false, discord: true)
  raise OutteError.new(msg.to_s, log: log, discord: discord)
end

# <---------------------------------------------------------------------------->
# <------                          NETWORKING                            ------>
# <---------------------------------------------------------------------------->

# Make a request to N++'s server.
# Since we need to use an open Steam ID, the function goes through all
# IDs until either an open is found (and stored), or the list ends and we fail.
#   - uri_proc:  A Proc returning the exact URI, takes Steam ID as parameter
#   - data_proc: A Proc that handles response data before returning it
#   - err:       Error string to log if the request fails
#   - vargs:     Extra variable arguments to pass to the uri_proc
#   - fast:      Only try the recently active Steam IDs
def get_data(uri_proc, data_proc, err, *vargs, fast: false)
  attempts ||= 0
  ids = Player.where.not(steam_id: nil)
  ids = ids.where(active: true) if fast
  count = ids.count
  i = 0
  initial_id = GlobalProperty.get_last_steam_id
  response = Net::HTTP.get_response(uri_proc.call(initial_id, *vargs))
  while response.body == INVALID_RESP
    GlobalProperty.update_last_steam_id(fast)
    i += 1
    break if GlobalProperty.get_last_steam_id == initial_id || i > count
    response = Net::HTTP.get_response(uri_proc.call(GlobalProperty.get_last_steam_id, *vargs))
  end
  return nil if response.body == INVALID_RESP
  raise "502 Bad Gateway" if response.code.to_i == 502
  GlobalProperty.activate_last_steam_id
  data_proc.call(response.body)
rescue => e
  if (attempts += 1) < RETRIES
    err("#{err}: #{e}") if LOG_DOWNLOAD_ERRORS
    sleep(0.25)
    retry
  else
    return nil
  end
end

# Forward an arbitrary request to Metanet, return response's body if 200, nil else
def forward(req)
  return nil if req.nil?

  # Parse request elements
  host = 'dojo.nplusplus.ninja'
  path = req.request_uri.path
  path.sub!(/\/[^\/]+/, '') if path[/\/(.+?)\//, 1] != 'prod'
  body = req.body

  # Create request
  uri = URI.parse("https://#{host}#{path}?#{req.query_string}")
  case req.request_method.upcase
  when 'GET'
    new_req = Net::HTTP::Get.new(uri)
  when 'POST'
    new_req = Net::HTTP::Post.new(uri)
  else
    return nil
  end

  # Add headers and body (clean default ones first)
  new_req.to_hash.keys.each{ |h| new_req.delete(h) }
  req.header.each{ |k, v| new_req[k] = v[0] }
  new_req['host'] = host
  new_req.body = body

  # Execute request
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 5){ |http|
    http.request(new_req)
  }
  res.code.to_i < 200 || res.code.to_i > 299 ? nil : res.body.to_s
rescue => e
  lex(e, 'Failed to forward request to Metanet')
  nil
end

# Send a multipart post-form to N++'s servers.
#   args:  Hash with additional URL-encoded query arguments.
#   parts: Array of body parts, each being a hash with 3 keys: name, value, binary.
def post_form(host: 'dojo.nplusplus.ninja', path: '', args: {}, parts: [])
  # Create request
  def_args = {
    app_id:     APP_ID,
    steam_auth: ''
  }
  query = def_args.merge(args).map{ |k, v| "#{k}=#{v}" }.join('&')
  uri = URI.parse("https://#{host}#{path}?#{query}")
  post = Net::HTTP::Post.new(uri)

  # Generate boundary
  blen = 8
  boundary = ''
  while parts.any?{ |p| p[:name].to_s.include?(boundary) || p[:value].to_s.include?(boundary) }
    boundary = blen.times.map{ rand(36).to_s(36) }.join
  end

  # Build and set body
  body = ''
  parts.each{ |p|
    body << '--' + boundary + "\r\n"
    body << "Content-Disposition: form-data; name=\"#{p[:name]}\""
    body << "; filename=\"#{p[:name]}\"\r\nContent-Type: application/octet-stream" if p[:binary]
    body << "\r\n\r\n#{p[:value]}\r\n"
  }
  body << '--' + boundary + "--\r\n"
  post.body = body

  # Add headers and clean default ones
  post.to_hash.keys.each{ |h| post.delete(h) }
  post['user-agent']     = 'libcurl-agent/1.0'
  post['host']           = host
  post['accept']         = '*/*'
  post['cache-control']  = 'no-cache'
  post['content-length'] = body.size.to_s
  post['expect']         = '100-continue'
  post['content-type']   = "multipart/form-data; boundary=#{boundary}"

  # Execute request
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 5){ |http|
    http.request(post)
  }
  res.code.to_i < 200 || res.code.to_i > 299 ? nil : res.body.to_s
rescue => e
  lex(e, 'Failed to send multipart post-form to Metanet')
  nil
end

# <---------------------------------------------------------------------------->
# <------                       SYSTEM OPERATIONS                        ------>
# <---------------------------------------------------------------------------->

# Execute code block in another process
#
# Technical note: We disconnect from the db before forking and reconnect after,
# because otherwise the forked process inherits the same connection, and if
# it's broken there (e.g. by an unhandled exception), then it's also broken
# in the parent, thus losing connection until we restart.
def _fork
  read, write = IO.pipe
  ActiveRecord::Base.connection.disconnect!

  pid = fork do
    read.close
    result = yield
    Marshal.dump(result, write)
    exit!(0)
  rescue => e
    lex(e, 'Error in forked process')
    nil
  end

  ActiveRecord::Base.connection.reconnect!
  write.close
  result = read.read
  Process.wait(pid)
  return nil if result.empty?
  Marshal.load(result)
rescue => e
  lex(e, 'Forking failed')
  nil
end

# Light wrapper to execute code block in thread
# Release db connection at the end if specified, also rescue errors
def _thread(release: false)
  Thread.new do
    yield
  rescue => e
    lex(e, 'Error in thread')
    nil
  ensure
    release_connection if release
  end
rescue => e
  lex(e, 'Threading failed')
  nil
end

# Execute a shell command
#   stream - Redirect STDOUT/STDERR to Ruby's terminal so we can see
#   output - Return the output (STDOUT/STDERR/status) as an array of strings
def shell(cmd, stream: LOG_SHELL, output: false)
  cmd += ' > /dev/null 2>&1' if !stream && !output
  output ? Open3.capture3(cmd) : system(cmd)
rescue => e
  lex(e, "Failed to execute shell command: #{cmd}")
end

# Represents a proc that will be queued in a worker thread but executed in the
# main thread. Once enqueued, this blocks the calling thread until the main
# one is done processing the command, and the result is filled.
class QueuedCmd
  attr_reader :proc, :thread
  attr_writer :result

  def initialize(proc, thread = Thread.current)
    @proc   = proc
    @thread = thread
    @result = nil
  end

  def enqueue
    $main_queue << self
    sleep
    @result
  end
end

# Return this process's memory usage in MB (Linux only)
# Spawning ps is slower but has broader support
def getmem(ps = false)
  return `ps -p #{Process.pid} -o rss=`.to_i / 1024.0 if ps
  line = nil
  File.open("/proc/#{Process.pid}/status", 'rb') do |f|
    line = f.find{ |l| l=~ /vmrss/i }
  end
  return 0 if !line
  _, value, unit = line.downcase.split
  conversion = 1024 ** ['b', 'kb', 'mb', 'gb', 'tb'].index(unit)
  value.to_f * conversion / 1024 ** 2
rescue
  0
end

# Return system's memory info in MB as a hash (Linux only)
def meminfo
  File.read("/proc/meminfo").split("\n").map{ |f| f.split(':') }
      .map{ |name, value| [name, value.to_i / 1024.0] }.to_h
rescue
  {}
end

# <---------------------------------------------------------------------------->
# <------                         BENCHMARKING                           ------>
# <---------------------------------------------------------------------------->

# Wrapper to benchmark a piece of code
def bench(action, msg = nil, pad_str: 1, pad_num: 8)
  now      = Time.now
  @t     ||= now
  @total ||= 0
  @step  ||= 0
  case action
  when :start
    @step  = 0
    @total = 0
    @t     = now
  when :step
    int = now - @t
    @step  += 1
    @total += int
    @t      = now
    dbg("Benchmark #{msg.nil? ? ("%02d" % @step) : ("%#{pad_str}s" % msg)}: #{"%#{pad_num}.3fms" % (int * 1000)} (Total: #{"%#{pad_num}.3fms" % (@total * 1000)}).")
  end
end

# Wrapper to do memory profiling for a piece of code
def profile(action)
  case action
  when :start
    MemoryProfiler.start
  when :stop
    MemoryProfiler.stop.pretty_print(
      to_file:         File.join(DIR_LOGS, 'memory_profile.txt'),
      scale_bytes:     true,
      detailed_report: true,
      normalize_paths: true
    )
  end
rescue => e
  lex(e, 'Failed to do memory profiling')
end

# <---------------------------------------------------------------------------->
# <------                      STRING MANIPULATION                       ------>
# <---------------------------------------------------------------------------->

# Convert a string to strict ASCII, replacing all invalid characters to underscores
# Optionally, also remove non-printable characters
def to_ascii(str, printable = true, extended: false)
  charset = extended ? 'ISO-8859-1' : 'ASCII'
  str = str.to_s
  str = str.encode(charset, invalid: :replace, undef: :replace, replace: "_")
  str = str.bytes.reject{ |b| b < 32 || b > 126 }.map(&:chr).join if printable
  str
rescue
  str.to_s
end

def to_utf8(str)
  str.bytes.reject{ |b| b < 32 || b == 127 }.map(&:chr).join.force_encoding('UTF-8').scrub('')
end

def parse_str(str)
  to_utf8(str.split("\x00")[0].to_s).strip
end

def is_num(str)
  return false if !str.is_a?(String)
  str.strip == str[/\d+/i]
end

# Escape problematic chars (e.g. quotes or backslashes)
def escape(str)
  str.dump[1..-2]
end

# Inverse of the function above
def unescape(str)
  "\"#{str}\"".undump
rescue
  str
end

# Make a string safe for filenames, by:
# - Leaving only printable ASCII characters
# - Substituting Windows' reserved characters by an underscore
def sanitize_filename(str)
  reserved = "\"*/:<>?\\|"
  to_ascii(str).tr(reserved, '')
end

# Sanitize a string so that it is safe within an SQL LIKE statement
def sanitize_like(string, escape_character = "\\")
  pattern = Regexp.union(escape_character, "%", "_")
  string.gsub(pattern) { |x| [escape_character, x].join }
end

def truncate_ellipsis(str, pad = DEFAULT_PADDING)
  str if !str.is_a?(String) || !pad.is_a?(Integer) || pad < 0
  str.length <= pad ? str : (pad > 3 ? str[0...pad - 3] + '...' : str[0...pad])
end

def pad_truncate_ellipsis(str, pad = DEFAULT_PADDING, max_pad = MAX_PAD_GEN)
  truncate_ellipsis(format_string(str, pad, max_pad, false))
end

# Conditionally pluralize word
# If 'pad' we pad string to longest between singular and plural, for alignment
def cplural(word, n, pad = false)
  sing = word
  plur = word.pluralize
  word = n == 1 ? sing : plur
  pad  = [sing, plur].map(&:length).max
  "%-#{pad}s" % word
end

def clean_userlevel_message(msg)
  msg.sub(/(for|of)?\w*userlevel\w*/i, '').squish
end

# Removes the first instance of a substring and removes extra spaces
def remove_word_first(msg, word)
  msg.sub(/\w*#{word}\w*/i, '').squish
end

# Strip off the @outte++ mention, if present
# IDs might have an exclamation mark
def remove_mentions!(msg)
  msg.gsub!(/<@!?[0-9]*>\s*/, '')
end

# Remove the command part of a special command
def remove_command(msg)
  msg.sub(/^!\w+\s*/i, '').strip
end

# Function to pad (and possibly truncate) a string according to different
# padding methods, determined by the constants defined at the start.
# It's a general function, but with a boolean we specify if we're formatting
# player names for leaderboards in particular, in which case, the maximum
# padding length is different.
def format_string(str, padding = DEFAULT_PADDING, max_pad = MAX_PADDING, leaderboards = true)
  # Compute maximum padding length
  max_pad = !max_pad.nil? ? max_pad : (leaderboards ? MAX_PADDING : MAX_PAD_GEN)

  # Compute actual padding length, based on the different constraints
  pad = DEFAULT_PADDING
  pad = padding if padding > 0
  pad = max_pad if max_pad > 0 && max_pad < padding
  pad = SCORE_PADDING if SCORE_PADDING > 0

  # Adjust padding if there are emojis or kanjis (characters with different widths)
  # We basically estimate their widths and cut the string at the closest integer
  # match to the desired padding
  widths = str.chars.map{ |s|
    s =~ Unicode::Emoji::REGEX ? WIDTH_EMOJI : (s =~ /\p{Han}|\p{Hiragana}|\p{Katakana}/i ? WIDTH_KANJI : 1)
  }
  total = 0
  totals = widths.map{ |w| total += w }
  width = totals.min_by{ |t| (t - pad).abs }
  chars = totals.index(width) + 1
  pad = pad > width ? chars + (pad - width).round : chars

  # Truncate and pad string
  "%-#{"%d" % [pad]}s" % [TRUNCATE_NAME ? str.slice(0, pad) : str]
end

# Converts an array of strings into a regex string that matches any of them
# with non-capturing groups (it can also take a string)
def regexize_words(words)
  return '' if !words.is_a?(Array) && !words.is_a?(String)
  words = [words] if words.is_a?(String)
  words = words.reject{ |w| !w.is_a?(String) || w.empty? }
  return '' if words.empty?
  words = '(?:' + words.map{ |w| "(?:\\b#{Regexp.escape(w.strip)}\\b)" }.join('|') + ')'
rescue
  ''
end

# DISTANCE BETWEEN STRINGS
# * Find distance between two strings using the classic Damerau-Levenshtein
# * Returns nil if the threshold is surpassed
# * Read 'string_distance_list_mixed' for detailed docs
def string_distance(word1, word2, max: 3, th: 3)
  d = DamerauLevenshtein.distance(word1, word2, 1, max)
  (d - [word1.length, word2.length].min).abs < th ? nil : d
end

# DISTANCE BETWEEN STRING AND PHRASE
# Same as before, but compares a word with a phrase, but comparing word by word
#   and taking the MINIMUM (for single-word matches, which is common)
# Returns nil if the threshold is surpassed for EVERY word
def string_distance_chunked(word, phrase, max: 3, th: 3)
  phrase.split(/\W|_/i).reject{ |chunk| chunk.strip.empty? }.map{ |chunk|
    string_distance(word, chunk, max: max, th: th)
  }.compact.min
end

# DISTANCE BETWEEN WORD AND LIST
# (read 'string_distance_list_mixed' for docs)
def string_distance_list(word, list, max: 3, th: 3, chunked: false)
  # Determine if IDs have been provided
  ids = list[0].is_a?(Array)
  # Sort and group by distance, rejecting invalids
  list = list.each_with_index.map{ |n, i|
                if chunked
                  [string_distance_chunked(word, ids ? n[1] : n, max: max, th: th), n]
                else
                  [string_distance(word, ids ? n[1] : n, max: max, th: th), n]
                end
              }
              .reject{ |d, n| d.nil? || d > max || (!th.nil? && (d - (ids ? n[1] : n).length).abs < th) }
              .group_by{ |d, n| d }
              .sort_by{ |g| g[0] }
              .map{ |g| [g[0], g[1].map(&:last)] }
              .to_h
  # Complete the hash with the distance values that might not have appeared
  # (this allows for more consistent use of the list, e.g., when zipping)
  (0..max).each{ |i| list[i] = [] if !list.key?(i) }
  list
end

# DISTANCE-MATCH A STRING IN A LIST
#   --- Description ---
# Sort list of strings based on a Damerau-Levenshtein-ish distance to a string.
#
# The list may be provided as:
#   A list of strings
#   A list of pairs, where the string is the second element
# This is used when there may be duplicate strings that we don't want to
# ditch, in which case the first element would be the ID that makes them
# unique. Obviously, this is done with level and player names in mind, that
# may have duplicates.
#
# The comparison between strings will be performed both normally and 'chunked',
# which splits the strings in the list in words. These resulting lists are then
# zipped (i.e. first distance 0, then chunked distance 0, the distance 1, etc.)
#   --- Parameters ---
# word       - String to match in the list
# list       - List of strings / pairs to match in
# min        - Minimum distance, all matches below this distance are keepies
# max        - Maximum distance, all matches above this distance are ignored
# th         - Threshold of maximum difference between the calculated distance
#              and the string length to consider. The reason we do this is to
#              ignore trivial results, eg, the distance between 'old' and 'new'
#              is 3, not because the words are similar, but because they're only
#              3 characters long
# soft_limit - Limit of matches to show, assuming there aren't more keepies
# hard_limit - Limit of matches to show, even if there are more keepies
# Returns nil if the threshold is surpassed
def string_distance_list_mixed(word, list, min: 1, max: 3, max2: 2, th: 3, soft_limit: 10, hard_limit: 20)
  matches1 = string_distance_list(word, list, max: max,  th: th, chunked: false)
  matches2 = string_distance_list(word, list, max: max2, th: th, chunked: true)
  max = [max, max2].max
  matches = (0..max).map{ |i| [i, ((matches1[i] || []) + (matches2[i] || [])).uniq(&:first)] }.to_h
  keepies = matches.select{ |k, v| k <= min }.values.map(&:size).sum
  to_take = [[keepies, soft_limit].max, hard_limit].min
  matches.values.flatten(1).take(to_take)
end

# <---------------------------------------------------------------------------->
# <------                      BINARY MANIPULATION                       ------>
# <---------------------------------------------------------------------------->

# Convert an integer into a little endian binary string of 'size' bytes and back
# TODO: Substitute most/all uses of this with Ruby's native pack/unpack functions
def _pack_raw(n, size)
  n.to_s(16).rjust(2 * size, "0").scan(/../).reverse.map{ |b|
    [b].pack('H*')[0]
  }.join.force_encoding("ascii-8bit")
end

def _pack(n, arg)
  if arg.is_a?(String)
    [n].pack(arg)
  else
    _pack_raw(n, arg.to_i)
  end
rescue
  _pack_raw(n, arg.to_i)
end

def _unpack(bytes, fmt = nil)
  if bytes.is_a?(Array) then bytes = bytes.join end
  if !bytes.is_a?(String) then bytes.to_s end
  i = bytes.unpack(fmt)[0] if !fmt.nil?
  i ||= bytes.unpack('H*')[0].scan(/../).reverse.join.to_i(16)
rescue
  if bytes.is_a?(Array) then bytes = bytes.join end
  bytes.unpack('H*')[0].scan(/../).reverse.join.to_i(16)
end

# Verifies if an arbitrary floating point can be a valid score
def verify_score(score)
  decimal = (score * 60) % 1
  [decimal, 1 - decimal].min < 0.03
end

# <---------------------------------------------------------------------------->
# <------                        DISCORD RELATED                         ------>
# <---------------------------------------------------------------------------->

# Find the botmaster's Discord user
def botmaster
  $bot.servers.each{ |id, server|
    member = server.member(BOTMASTER_ID)
    return member if !member.nil?
  }
  err("Couldn't find botmaster")
  nil
rescue => e
  lex(e, "Error finding botmaster")
  nil
end

# Get a specific component from a message, by type and ID
def get_component(msg, type: nil, id: nil)
  components = msg.components.map{ |row| row.components }.flatten
  components.select!{ |c|
    case type
    when :button
      c.is_a?(Discordrb::Components::Button)
    when :select_menu
      c.is_a?(Discordrb::Components::SelectMenu)
    else
      false
    end
  } if type
  components.select!{ |c| c.custom_id == id } if id
  components.first
rescue => e
  lex(e, 'Error getting component')
  nil
end

# Find Discord server the bot is in, by ID or name
def find_server(id: nil, name: nil)
  if id
    $bot.servers[id]
  elsif name
    $bot.servers.values.find{ |s| s.name.downcase.include?(name.downcase) }
  else
    nil
  end
rescue
  nil
end

def find_channel_in_server(id: nil, name: nil, server: nil)
  return nil if server.nil?
  if id
    server.channels.find{ |c| c.id == id }
  elsif name
    server.channels.find{ |c| c.name.downcase.include?(name.downcase) }
  else
    nil
  end
rescue
  nil
end

# Find Discord channel by ID or name, server optional
def find_channel(id: nil, name: nil, server_id: nil, server_name: nil)
  server = find_server(id: server_id, name: server_name)
  if server
    find_channel_in_server(id: id, name: name, server: server)
  else
    $bot.servers.each{ |_, s|
      channel = find_channel_in_server(id: id, name: name, server: s)
      return channel if !channel.nil?
    }
    nil
  end
rescue
  nil
end

# Find emoji by ID or name
def find_emoji(key, server = nil)
  server = server || $bot.servers[SERVER_ID] || $bot.servers.first.last
  return if server.nil?
  if key.is_a?(Integer)
    server.emojis[key]
  elsif key.is_a?(String)
    res = server.emojis.find{ |id, e| e.name == key }
    res = server.emojis.find{ |id, e| e.name.downcase == key.downcase } unless res
    res = server.emojis.find{ |id, e| e.name.downcase.include?(key.downcase) } unless res
    res ? res[1] : nil
  else
    nil
  end
rescue
  nil
end

# Find user by name and tag in a given server
def find_users_in_server(name: nil, tag: nil, server: nil)
  return [] if !server || !name
  server.users.select{ |u|
    u.name.downcase == name.downcase && (!tag.nil? ? u.tag == tag : true)
  }
rescue
  []
end

def find_users(name: nil, tag: nil)
  $bot.servers.map{ |_, server|
    find_users_in_server(name: name, tag: tag, server: server)
  }.flatten
rescue
  []
end

# React to a Discord msg (by ID) with an emoji (by Unicode or name)
def react(channel, msg_id, emoji)
  channel = find_channel(name: channel) rescue nil
  perror('Channel not found') if channel.nil?
  msg = channel.message(msg_id.to_i) rescue nil
  perror('Message not found') if msg.nil?
  emoji = find_emoji(emoji, channel.server) if emoji.ascii_only? rescue nil
  perror('Emoji not found') if emoji.nil?
  msg.react(emoji)
end

def unreact(channel, msg_id, emoji = nil)
  channel = find_channel(name: channel) rescue nil
  perror('Channel not found') if channel.nil?
  msg = channel.message(msg_id.to_i) rescue nil
  perror('Message not found') if msg.nil?
  if emoji.nil?
    msg.my_reactions.each{ |r|
      emoji = r.name.ascii_only? ? find_emoji(r.name, channel.server) : r.name
      msg.delete_own_reaction(emoji)
    }
  else
    emoji = find_emoji(emoji, channel.server) if emoji.ascii_only? rescue nil
    perror('Emoji not found') if emoji.nil?
    msg.delete_own_reaction(emoji)
  end
end

# Pings a role by name (returns ping string)
def ping(rname)
  server = TEST ? $bot.servers.values.first : $bot.servers[SERVER_ID]
  if server.nil?
    log("Server not found")
    return ""
  end

  role = server.roles.select{ |r| r.name == rname }.first
  if role != nil
    if role.mentionable
      return role.mention
    else
      log("Role #{rname} in server #{server.name} not mentionable")
      return ""
    end
  else
    log("Role #{rname} not found in server #{server.name}")
    return ""
  end
rescue => e
  lex(e, "Failed to ping role #{rname}")
  ""
end

# Return the string that produces a clickable channel mention in Discord
def mention_channel(name: nil, id: nil, server_name: nil, server_id: nil)
  channel = find_channel(id: id, name: name, server_id: server_id, server_name: server_name)
  return '' if channel.nil?
  channel.mention
rescue => e
  lex(e, 'Failed to mention Discord channel')
  ''
end

# Format a string as a one-line block, which removes all special Markdown
# formatting and just shows the raw text.
# Current, this is done by enclosing the text within backticks.
def verbatim(str)
  str = str.to_s.tr('`', '')
  str = ' ' if str.empty?
  "`#{str}`"
end

# Format a string as a multi-line block.
# Currently, this is done by enclosing the text within triple backticks.
def format_block(str)
  str = str.to_s.gsub('```', '')
  str = ' ' if str.empty?
  "```\n#{str}```"
end

# Format a string as a spoiler, by enclosing it within double vertical bars.
def spoiler(str)
  str = str.to_s
  return "|| ||" if str.empty?
  "||#{str.gsub('||', '')}||"
end

# Send or edit a Discord message in parallel
# We actually send an array of messages, not only so that we can edit them all,
# but mainly because that way we actually can edit the original message object.
# (i.e. simulate pass-by-reference via encapsulation)
def concurrent_edit(event, msgs, content)
  Thread.new do
    msgs.map!{ |msg|
      msg.nil? ? send_message(event, content: content) : msg.edit(content)
    }
  rescue
    msgs
  end
rescue
  msgs
end

# Set the avatar to an image given the name
def change_avatar(avatar)
  File::open(File.join(PATH_AVATARS, avatar)) do |f|
    $bot.profile.avatar = f
  end
rescue
  perror("Too many changes! Wait and try again.")
end

# Return the channel type as per Discord's API
#  0 Text channel
#  1 DM
#  2 Voice
#  3 Group
#  4 Category
#  5 News / announcements
#  6 Store
# 10 News thread
# 11 Public thread
# 12 Private thread
# 13 Stage voice
# 14 Directory (channel in server hub)
# 15 Forum (thread container)
# 16 Media channel
def channel_type(type)
  Discordrb::Channel::TYPES[type.to_s.downcase.to_sym]
end

# Return a default mappack based on the user and channel
def default_mappack(user, channel)
  # User-specific global default
  return user.mappack if user && user.mappack_default_always && user.mappack

  # Channel-specific default
  pack = MappackChannel.find_by(id: channel.id).mappack rescue nil
  return pack if pack

  # User-specific channel default
  return nil if !user || !channel || !user.mappack
  return user.mappack if user.mappack_default_dms && channel.type == channel_type(:dm)

  nil
rescue
  nil
end

# <---------------------------------------------------------------------------->
# <------                         N++ SPECIFIC                           ------>
# <---------------------------------------------------------------------------->

# Sometimes we need to make sure there's exactly one valid type
def ensure_type(type, mappack: false)
  base = mappack ? MappackLevel : Level
  type.nil? ? base : (type.is_a?(Array) ? (type.include?(base) ? base : type.flatten.first) : type)
end

# Converts any type input to an array of type classes
# Also converts types to mappack ones if necessary
def normalize_type(type, empty: false, mappack: false)
  type = DEFAULT_TYPES.map(&:constantize) if type.nil?
  type = [type] if !type.is_a?(Array)
  type = DEFAULT_TYPES.map(&:constantize) if !empty && type.empty?
  type.map{ |t|
    t = t.constantize if t.is_a?(String)
    mappack ? t.mappack : t.vanilla
  }
end

# Normalize how highscoreable types are handled.
# A good example:
#   [Level, Episode]
# Bad examples:
#   nil   (transforms to [Level, Episode])
#   Level (transforms to [Level])
# 'single' means we return a single type instead
def fix_type(type, single = false)
  if single
    ensure_type(type)
  else
    type.nil? ? DEFAULT_TYPES.map(&:constantize) : (!type.is_a?(Array) ? [type] : type)
  end
end

# find the optimal score / amount of whatever rankings or stat
def find_max_type(rank, type, tabs, mappack = nil, board = 'hs')
  # Filter scores by type and tabs
  type = Level if rank == :gm
  type = mappack || rank == :gp ? type.mappack : type.vanilla
  query = mappack || rank == :gp ? type.where(mappack: mappack) : type
  query = query.where(tab: tabs) if !tabs.empty?

  # Distinguish ranking type
  case rank
  when :points
    query.count * 20
  when :avg_points
    20
  when :avg_rank
    0
  when :maxable
    Highscoreable.ties(type, tabs, nil, false, true, mappack, board).size
  when :maxed
    Highscoreable.ties(type, tabs, nil, true, true, mappack, board).size
  when :gp
    query.sum(:gold)
  when :gm
    klass = mappack.nil? ? Score : MappackScore.where(mappack: mappack)
    query = klass.where(highscoreable_type: type)
    query = query.where(tab: tabs) if !tabs.empty?
    # query.group(:highscoreable_id).minimum(:gold).values.sum
    MappackScore.from(
      query.group(:highscoreable_id).select('MIN(gold) AS gold'),
      :t
    ).sum('t.gold')
  when :clean
    0.0
  when :score
    klass  = !mappack ? Score  : MappackScore.where(mappack: mappack)
    rfield = !mappack ? :rank  : "rank_#{board}".to_sym
    sfield = !mappack ? :score : "score_#{board}".to_sym
    scale  = mappack && board == 'hs' ? 60.0 : 1.0

    query = klass.where(highscoreable_type: type, rfield => 0)
    query = query.where(tab: tabs) if !tabs.empty?
    query = query.sum(sfield) / scale
    mappack && board == 'sr' ? query.to_i : query.to_f
  else
    query.count
  end
end

# Finds the maximum value a player can reach in a certain ranking
# If 'empty' we allow no types, otherwise default to Level and Episode
def find_max(rank, types, tabs, empty = false, mappack = nil, board = 'hs')
  # Normalize params
  types = normalize_type(types, empty: empty)

  # Compute type-wise maxes, and add
  maxes = [types].flatten.map{ |t| find_max_type(rank, t, tabs, mappack, board) }
  [:avg_points, :avg_rank].include?(rank) ? maxes.first : maxes.sum
end

# Finds the minimum number of scores required to appear in a certain
# average rank/point rankings
# If 'empty' we allow no types, otherwise default to Level and Episode
# If 'a' and 'b', we weight the min scores by the range size
# If 'star' then we're dealing with only * scores, and we should again be
# more gentle
def min_scores(type, tabs, empty = false, a = 0, b = 20, star = false, mappack = nil)
  # We ignore mappack mins for now
  return 0 if !mappack.nil?

  # Normalize types
  types = normalize_type(type, empty: empty)

  # Compute mins per type, and add
  mins = types.map{ |t|
    if tabs.empty?
      type_min = TABS[t.to_s].sum{ |k, v| v[2] }
    else
      type_min = tabs.map{ |tab| TABS[t.to_s][tab][2] if TABS[t.to_s].key?(tab) }.compact.sum
    end
    [type_min, TYPES[t.to_s][:min_scores]].min
  }.sum

  # Compute final count
  c = star ? 1 : b - a
  ([mins, MAXMIN_SCORES].min * c / 20.0).to_i
end

# round float to nearest frame
def round_score(score)
  score.is_a?(Integer) ? score : (score * 60).round / 60.0
end

# Calculate episode splits based on the 5 level scores
def splits_from_scores(scores, start: 90.0, factor: 1, offset: 90.0)
  acc = start
  scores.map{ |s| round_score(acc += (s / factor - offset)) }
end

def scores_from_splits(splits, offset: 90.0)
  splits.each_with_index.map{ |s, i|
    round_score(i == 0 ? s : s - splits[i - 1] + offset)
  }
end

# Computes the name of a highscoreable based on the ID and type, e.g.:
# Type = 0, ID = 2637 ---> SU-C-09-02
# The complexity of this function lies in:
#   1) The type itself (Level, Episode, Story) changes the computation.
#   2) Only some tabs have X row.
#   3) Only some tabs are secret.
#   4) Lastly, and perhaps most importantly, some tabs in Coop and Race are
#      actually split in multiple files, with the corresponding bits of
#      X row staggered at the end of each one.
# NOTE: Some invalid IDs will return valid names rather than nil, e.g., if
# type is Story and ID = 120, it will return "!-00", a non-existing story.
# This is a consequence of the algorithm, but it's harmless if only correct
# IDs are inputted.
def compute_name(id, type)
  return nil if ![0, 1, 2].include?(type)
  f = 5 ** type # scaling factor

  # Fetch corresponding tab
  tab = TABS_NEW.find{ |_, t| (t[:start]...t[:start] + t[:size]).include?(id * f) }
  return nil if tab.nil?
  tab = tab[1]

  # Get stories out of the way
  return "#{tab[:code]}-#{"%02d" % (id - tab[:start] / 25)}" if type == 2

  # Compute offset in tab and file
  tab_offset = id - tab[:start] / f
  file_offset = tab_offset
  file_count = tab[:files].values[0] / f
  tab[:files].values.inject(0){ |sum, n|
    if sum <= tab_offset
      file_offset = tab_offset - sum
      file_count = n / f
    end
    sum + n / f
  }

  # If it's a secret level tab, its numbering is episode-like
  if type == 0 && tab[:secret]
    type = 1
    f = 5
  end

  # Compute episode and column offset in file
  rows = tab[:x] ? 6 : 5
  file_eps = file_count * f / 5
  file_cols = file_eps / rows
  episode_offset = file_offset * f / 5
  if tab[:x] && episode_offset >= 5 * file_eps / 6
    letter = 'X'
    column_offset = episode_offset % file_cols
  else
    letter = ('A'..'E').to_a[episode_offset % 5]
    column_offset = episode_offset / 5
  end

  # Compute column (and level number)
  prev_count = tab_offset - file_offset
  prev_eps = prev_count * f / 5
  prev_cols = prev_eps / rows
  col = column_offset + prev_cols
  lvl = tab_offset % 5

  # Return name
  case type
  when 0
    "#{tab[:code]}-#{letter}-#{"%02d" % col}-#{"%02d" % lvl}"
  when 1
    "#{tab[:code]}-#{letter}-#{"%02d" % col}"
  end
end

# Execute ntrace and parse the output.
def ntrace(map_data, demo_data, silent: false, debug: false, splits: false)
  # Export files for ntrace to read
  if splits
    File.binwrite(NTRACE_INPUTS_E, demo_data)
    map_data.each_with_index{ |map, i| File.binwrite(NTRACE_MAP_DATA_E % i, map) }
  else
    demo_data.each_with_index{ |demo, i| File.binwrite(NTRACE_INPUTS % i, demo) }
    File.binwrite(NTRACE_MAP_DATA, map_data)
  end

  # Execute ntrace and save output
  stdout, stderr, status = shell("python3 #{PATH_NTRACE}", output: true)
  ret = [stdout, stderr].join("\n\n")
  if splits
    FileUtils.rm([NTRACE_INPUTS_E, *Dir.glob(NTRACE_MAP_DATA_E % '*')])
  else
    FileUtils.rm([NTRACE_MAP_DATA, *Dir.glob(NTRACE_INPUTS % '*')])
  end
  output = splits ? NTRACE_OUTPUT_E : NTRACE_OUTPUT

  # If ntrace failed, return or perror
  if !status.success? || !File.file?(output)
    FileUtils.rm([output]) if File.file?(output)
    return { success: false } if silent
    str = "ntrace failed, please contact the botmaster for details."
    if debug
      if ret.length < DISCORD_CHAR_LIMIT - 100
        str << "\n"
        str << format_block(ret)
      else
        _thread do
          sleep(0.5)
          event.send_file(
            tmp_file(ret, 'ntrace_output.txt', binary: false),
            caption: 'ntrace output:'
          )
        end
      end
    end
    perror(str)
  end

  # Parse output file
  valid = []
  coords = []
  objs = []
  File.open(output, 'rb') do |f|
    n = f.read(1).unpack('C')[0]
    valid = f.read(n).bytes.map{ |b| b > 0 }
    n.times do |i|
      obj_count = f.read(2).unpack('S<')[0]
      obj_count.times { objs << f.read(20).unpack("S<CEEC") }
      frames = f.read(2).unpack('S<')[0]
      coords << f.read(16 * frames).unpack("E#{2 * frames}").each_slice(2).to_a
    end
  end
  FileUtils.rm([output])
  objs.uniq!
  objs = objs.group_by(&:first).to_h
  objs.each{ |frame, list|
    list.each{ |o|
      o.shift
      o[0] = 1 if o[0] == 21
      o[0] = 7 if o[0] == 6
      o[0] = 9 if o[0] == 8
      o[1] = (o[1] / 6).round
      o[2] = (o[2] / 6).round
    }
  }

  { success: true, valid: valid, coords: coords, collisions: objs, msg: ret }
end

# <---------------------------------------------------------------------------->
# <------                           GRAPHICS                             ------>
# <---------------------------------------------------------------------------->

def create_svg(
    filename: 'graph.svg',
    title:    'Plot',
    x_name:   'X',
    y_name:   'Y',
    x_res:    1920,
    y_res:    1080,
    data:     [[]],
    names:    [],
    labels:   [],
    fmt:      '%d'
  )
  titles = title.split("\n")
  # There are more options available:
  # https://github.com/lumean/svg-graph2/blob/master/lib/SVG/Graph/Graph.rb
  options = {
    # Geometry
    width:                      x_res,
    height:                     y_res,
    stack:                      :side,  # The stack option is valid for Bar graphs only

    # Title
    show_graph_title:           true,
    graph_title:                titles[0],
    show_graph_subtitle:        titles.size > 1,
    graph_subtitle:             titles[1],

    # Axis
    show_x_title:               true,
    x_title:                    x_name,
    x_title_location:           :middle,
    show_y_title:               true,
    y_title:                    y_name,
    y_title_location:           :end,
    y_title_text_direction:     :bt, # :bt, :tb

    # Legend
    key:                        true,
    key_width:                  nil,
    key_position:               :right, # :bottom, :right

    # X labels
    fields:                     labels,
    show_x_labels:              true,
    stagger_x_labels:           false,
    rotate_x_labels:            false,
    step_x_labels:              1,
    step_include_first_x_label: true,
    show_x_guidelines:          false,

    # Y labels
    show_y_labels:              true,
    rotate_y_labels:            false,
    stagger_y_labels:           false,
    show_y_guidelines:          true,

    # Fonts
    font_size:                  12,
    title_font_size:            16,
    subtitle_font_size:         14,
    x_label_font_size:          12,
    y_label_font_size:          12,
    x_title_font_size:          14,
    y_title_font_size:          14,
    key_font_size:              10,
    key_box_size:               12,
    key_spacing:                5,

    # Other
    number_format:              fmt,
    scale_divisions:            (data.map(&:max).max.to_f / 6).round,
    scale_integers:             true,
    no_css:                     false,
    bar_gap:                    false,
    show_data_values:           false,

    # Line/Plot specific
    area_fill:                  true,
    show_data_points:           false
  }
  g = SVG::Graph::Line.new(options)
  data.each_with_index{ |plot, i|
    g.add_data({data: plot, title: names[i].to_s})
  }
  File.open(filename, 'w'){ |f| f.write(g.burn_svg_only) }
end

# Parse a TGA image and read the pixel data (very incomplete)
# Unpacking takes some time, but makes comparisons faster. If more than
# 13k pixels need to be used (~200 font chars at 11px), it's faster.
def parse_tga(file, unpack: true)
  tga = File.binread(file)
  perror("Invalid TGA file.") if tga.size < 18

  # Parse header
  id_length, colormap_type, image_type = tga.unpack('C3')
  cm_index, cm_length, cm_size = tga[3 ... 8].unpack('S<2C')
  x, y, width, height, depth, desc = tga[8 ... 18].unpack('S<4C2')

  return [] if image_type == 0
  perror("Color-mapped TGA files not supported.") if colormap_type != 0
  perror("RLE TGA files not supported.") if image_type > 3
  perror("True color TGA files not supported.") if image_type < 3
  perror("Reverse-storage TGAs not supported.") unless desc[5] == 1
  warn("Trying to parse a sub-8bit depth TGA.") if depth < 8

  # Parse image data
  offset = 18 + id_length + cm_length
  perror("Incomplete TGA image data.") if tga.size < offset + width * height
  image_data = tga[offset ... offset + width * height]
  image_data = image_data.unpack('C*') if unpack

  image_data
rescue => e
  lex(e, 'Failed to parse TGA file.')
  nil
end

# Parses a BMFont-generated .fnt file to read a bitmap font
def parse_bmfont(name)
  file = File.join(DIR_FONTS, name + '.fnt')
  perror("Font file not found.") if !File.file?(file)

  font = File.read(file).split("\n").map{ |l|
    [
      l[/^\w+/],
      l.scan(/(\w+)=(?:(?:"((?:[^"\\]|\\.)*)")|(\S+))/).map(&:compact).map{ |k, v|
        [k, v =~ /^-?\d+$/ ? v.to_i : v]
      }.to_h
    ]
  }.group_by(&:first).map{ |k, v| [k, v.map(&:last)] }.to_h
  font['char'] = font['char'].map{ |c| [c['id'], c] }.to_h
  font['pages'] = {}
  font['page'].each{ |page|
    file = File.join(DIR_FONTS, page['file'])
    perror("Font TGA not found.") if !File.file?(file)
    font['pages'][page['id'].to_i] = parse_tga(file)
  }
  font
rescue => e
  lex(e, 'Failed to parse BMFont.')
  nil
end

# Add a string of text to a Gifenc::Image using a BMFont
# TODO: Implement bound checks, wrapping logic, limit text to a certain bbox,
#   rolling text (usng modulo)... and add to Gifenc
def txt2gif(str, image, font, x, y, color, pad_x: 0, pad_y: 0, wrap: false, align: :left, max_length: nil, max_lines: nil, max_width: nil, max_height: nil)
  # Parse GIF image and font texture
  image_width    = image.width
  image_height   = image.height
  texture_width  = font['common'][0]['scaleW']
  texture_height = font['common'][0]['scaleH']
  wildcard       = font['char']['?'.ord]

  # Init params
  color      = color.chr if color.is_a?(Integer)
  factor     = { left: 0, center: 0.5, right: 1 }[align]
  start_x    = x - strlen(str, font) * factor
  start_y    = y - font['common'][0]['base'] + 1
  max_width  = [max_width, image_width - start_x].compact.min
  max_height = [max_height, image_height - start_y].compact.min
  max_length = max_width unless max_length
  max_lines  = max_height unless max_lines

  # Render each character
  cursor_x = start_x
  cursor_y = start_y
  str.each_codepoint.with_index{ |c, i|
    # Fetch canvas offsets
    char        = font['char'][c] || wildcard
    image_x     = cursor_x + char['xoffset']
    image_y     = cursor_y + char['yoffset']
    texture     = font['pages'][char['page']]
    texture_off = texture_width * char['y'] + char['x']
    break if image_x + char['width'] - start_x > max_width || i >= max_length

    # Paint each pixel
    char['height'].times.each{ |y|
      char['width'].times.each{ |x|
        if texture[texture_off] > 0
          image[image_x, image_y] = color
        end
        texture_off += 1
        image_x += 1
      }
      texture_off += texture_width - char['width']
      image_y += 1
      image_x -= char['width']
    }

    # Advance cursor
    cursor_x += char['xadvance'] + pad_x
  }
  # cursor_y += font['common'][0]['lineHeight'] + pad_y

  image
rescue => e
  lex(e, 'Failed to render text in GIF from TGA font.')
  image
end

# Find the pixel length of a string in the given font
def strlen(str, font, pad_x: 0)
  length = 0
  str.each_codepoint{ |c|
    char = font['char'][c] || font['char']['?'.ord]
    length += char['xadvance'] + pad_x
  }
  length
end

# <---------------------------------------------------------------------------->
# <------                        BOT MANAGEMENT                          ------>
# <---------------------------------------------------------------------------->

# Permission system:
#   Support for different roles (unrelated to Discord toles). Each role can
#   be determined by whichever system we choose (Discord user IDs, Discord
#   roles, etc.). We can restrict each function to only specific roles.
#
#   Currently implemented roles:
#     1) botmaster: Only the manager of the bot can execute them (matches
#                   Discord's user ID with a constant). This role has permission
#                   to perform any other task as well.
#     2) dmmc:      For executing the function to batch-generate screenies of DMMC.
#     3) ntracer:   Those who can update ntrace.
#
#   The following functions then check if the user who tried to execute a
#   certain function belongs to any of the permitted roles for it.
def check_permission(event, role)
  case role
  when 'botmaster'
    {
      granted: event.user.id == BOTMASTER_ID,
      allowed: ['botmasters']
    }
  else
    {
      granted: Role.exists(event.user.id, role) || event.user.id == BOTMASTER_ID,
      allowed: role.pluralize #names
    }
  end
end

def assert_permissions(event, roles = [])
  roles.push('botmaster') # Can do everything
  permissions = roles.map{ |role| check_permission(event, role) }
  granted = permissions.map{ |p| p[:granted] }.count(true) > 0
  error = "Sorry, only #{permissions.map{ |p| p[:allowed] }.flatten.to_sentence} are allowed to execute this command."
  perror(error) if !granted
rescue
  perror("Permission check failed")
end

# This function sets up the potato parameters correctly in case outte was closed,
# so that the food chain may not be broken
def fix_potato
  last_msg = $nv2_channel.history(1)[0] rescue nil
  $last_potato = last_msg.timestamp.to_i rescue Time.now.to_i
  if last_msg.author.id == $config['discord_client']
    $potato = ((FOOD.index(last_msg.content) + 1) % FOOD.size) rescue 0
  end
rescue
  nil
end

# Set global variables holding references to the main Discord channels the bot uses
def set_channels(event = nil)
  if !event.nil?
    $channel         = event.channel
    $mapping_channel = event.channel
    $nv2_channel     = event.channel
    $content_channel = event.channel
    $ctp_channel     = event.channel
  elsif !TEST
    channels = $bot.servers[SERVER_ID].channels
    $channel         = channels.find{ |c| c.id == CHANNEL_HIGHSCORES }
    $mapping_channel = channels.find{ |c| c.id == CHANNEL_USERLEVELS }
    $nv2_channel     = channels.find{ |c| c.id == CHANNEL_NV2 }
    $content_channel = channels.find{ |c| c.id == CHANNEL_CONTENT }
    $ctp_channel     = channels.find{ |c| c.id == CHANNEL_CTP_HIGHSCORES }
  else
    return
  end
  fix_potato
  log("Main channel:    #{$channel.name}")         if !$channel.nil?
  log("Mapping channel: #{$mapping_channel.name}") if !$mapping_channel.nil?
  log("Nv2 channel:     #{$nv2_channel.name}")     if !$nv2_channel.nil?
  log("Content channel: #{$content_channel.name}") if !$content_channel.nil?
  log("CTP channel:     #{$ctp_channel.name}")     if !$ctp_channel.nil?
end

# Leave all the servers the bot is in which are not specifically white-listed
#
# This is used because, in rare cases, 3rd parties could add outte to their
# Discord servers, because it's a public bot (otherwise, the botmaster would
# need mod powers in all servers the bot is in).
def leave_unknown_servers
  names = []
  $bot.servers.each{ |id, s|
    if !SERVER_WHITELIST.include?(id)
      names << s.name
      s.leave
    end
  }
  warn("Left #{names.count} unknown servers: #{names.join(', ')}") if names.count > 0
end

def update_bot_status
  $bot.update_status(BOT_STATUS, BOT_ACTIVITY, nil, 0, false, 0)
end

# Immediately kill process and restart the bot
def force_restart(reason = 'Unknown reason')
  warn("Restarting outte due to: #{reason}.", discord: true)
  shutdown(false)
  exec('./inne')
end

# Schedule a restart as soon as possible, i.e., as soon as no maintainance tasks
# are being executed, like publishing lotd or downloading the scores.
def restart(reason = 'Unknown reason')
  log("Attempting to restart outte due to: #{reason}.")
  tasks = $active_tasks.select{ |k, v| v }.to_h
  log("Waiting for active tasks to finish... (#{tasks.keys.map(&:to_s).join(', ')})") if tasks.size > 0
  sleep(5) while $active_tasks.values.count(true) > 0
  force_restart(reason)
rescue => e
  lex(e, 'Failed to restart outte', discord: true)
  sleep(5)
  retry
end

# <---------------------------------------------------------------------------->
# <------                             OTHER                              ------>
# <---------------------------------------------------------------------------->

# Compute the SHA1 hash. It uses Ruby's native version, unless 'c' is specified,
# in which case it uses the external C util that implements STB's function.
# It transforms the result to an ASCII hex string if 'hex' is specified.
#
# This is done, not for speed, but because the implementations differ, and
# the STB one is the exact one used by N++, so it's the one we need to verify
# the integrity of the hashes generated by the game.
def sha1(data, c: false, hex: false)
  if c && $linux && File.file?(PATH_SHA1)
    suffix = ((1 << 16) * rand).to_i.to_s(16)
    name_in = File.join(DIR_UTILS, HASH_INPUT_FN + '_' + suffix)
    name_out = File.join(DIR_UTILS, HASH_OUTPUT_FN + '_' + suffix)

    File.binwrite(name_in, data)
    code = shell("#{PATH_SHA1} #{name_in} #{name_out}", output: true).last
    return nil if !code.success?
    hash = File.binread(name_out)
    FileUtils.rm([name_in, name_out])
  else
    hash = Digest::SHA1.digest(data)
  end
  hex ? hash.unpack('H*')[0] : hash
rescue => e
  lex(e, 'Failed to compute SHA1 hash')
  nil
end

def md5(data, hex: false)
  hash = Digest::MD5.digest(data)
  hex ? hash.unpack('H*')[0] : hash
rescue => e
  lex(e, 'Failed to compute MD5 hash')
  nil
end

# Create a ZIP file. Provided data should be a Hash with the filenames
# as keys and the file contents as values.
def zip(data)
  Zip::OutputStream.write_buffer{ |zip|
    data.each{ |name, content|
      zip.put_next_entry(name)
      zip.write(content)
    }
  }.string
end

def unzip(data)
  res = {}
  Zip::File.open_buffer(data){ |zip|
    zip.each{ |entry|
      res[entry.name] = entry.get_input_stream.read
    }
  }
  res
end

def acquire_connection
  ActiveRecord::Base.connection.reconnect!
end

def release_connection
  #ActiveRecord::Base.connection_pool.release_connection
  ActiveRecord::Base.connection.disconnect!
rescue
  nil
end

# Perform arbitrary SQL command
def sql(command)
  ActiveRecord::Base.connection.exec_query(command)
end

# Fetch value of certain MySQL variables and statuses
def update_sql_status
  $sql_vars   = sql("SHOW SESSION VARIABLES").rows.to_h
  $sql_status = sql("SHOW GLOBAL STATUS").rows.to_h
  $sql_conns  = sql("SHOW FULL PROCESSLIST").to_a
end

# Weighed average
def wavg(arr, w)
  return -1 if arr.size != w.size
  arr.each_with_index.map{ |a, i| a*w[i] }.sum.to_f / w.sum
end

def numlen(n, float = true)
  n.to_i.to_s.length + (float ? 4 : 0)
end

# This corrects a datetime in the database when it's out of phase
# (e.g. after a long downtime of the bot).
def correct_time(time, frequency)
  time -= frequency while time > Time.now
  time += frequency while time < Time.now
  time
end

# Transform a table (2-dim array) into a text table
# Individual entries can be either strings or numbers:
#   - Strings will be left-aligned
#   - Numbers will be right-aligned
#   - Floats will also be formatted with 3 decimals
# Additionally, all entries will be padded.
# An entry could also be the symbol :sep, will will insert a separator in that row
def make_table(rows, header = nil, sep_x = "=", sep_y = "|", sep_i = "x")
  text_rows = rows.select{ |r| r.is_a?(Array) }
  count = text_rows.map(&:size).max
  rows.each{ |r| if r.is_a?(Array) then r << "" while r.size < count end }
  widths = (0..count - 1).map{ |c| text_rows.map{ |r| (r[c].is_a?(Float) ? "%.3f" % r[c] : r[c].to_s).length }.max }
  sep = widths.map{ |w| sep_i + sep_x * (w + 2) }.join + sep_i + "\n"
  table = sep.dup
  table << sep_y + " " * (((sep.size - 1) - header.size) / 2) + header + " " * ((sep.size - 1) - ((sep.size - 1) - header.size) / 2 - header.size - 2) + sep_y + "\n" + sep if !header.nil?
  rows.each{ |r|
    if r == :sep
      table << sep
    else
      r.each_with_index{ |s, i|
        table << sep_y + " " + (s.is_a?(Numeric) ? (s.is_a?(Integer) ? s : "%.3f" % s).to_s.rjust(widths[i], " ") : s.to_s.ljust(widths[i], " ")) + " "
      }
      table << sep_y + "\n"
    end
  }
  table << sep
  return table
end
