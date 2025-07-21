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
#       maintenance, running Python scripts, etc.
#  5) Benchmarking:
#       Functions to benchmark code, perform memory profiling, etc.
#  6) String manipulation:
#       Converting between formats (ASCII, UTF8, ...), string escaping/unescaping,
#       string sanitization (for filenames, SQL, ...), string truncation/padding,
#       string distance (Damerau-Levenshtein), etc.
#  7) Binary manipulation:
#       Basically packing and unpacking binary data into/from strings.
#  8) File manipulation:
#       Helpers for parsing binary files and zipping/unzipping stuff.
#  9) Discord related:
#       Finding Discord users, channels, servers, emojis, etc. Pinging users,
#       reacting or unreacting to comments, mentioning channels... Formatting
#       strings (as code blocks, spoilers, ...), etc.
# 10) N++ specific:
#       Stuff like sanitizing parameters for N++ functions, finding maximum values
#       for rankings, calculating episode splits, or computing a highscoreable's
#       name from its ID.
# 11) Graphics:
#       Text-based and image-based graphics generation. Includes things such as
#       progress bars, tables, histograms, and plots.
# 12) Bot management:
#       Permission system for commands with custom roles, setting the bot's main
#       channels, leaving blacklisted servers, restarting the bot, etc.
# 13) SQL:
#       Acquire/release db connections, perform raw SQL queries, monitor SQL
#       resources, check Rails version, etc.
# 14) Maths:
#       Operations (e.g. weighted averages), geometry (e.g. intersection and
#       areas of rectangles), hashing (SHA1, MD5), etc.

require 'active_record'
require 'damerau-levenshtein'
require 'digest'
require 'net/http'
require 'unicode/emoji'
require 'zip'


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
module Log extend self

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
    debug:  [:fatal, :error, :warn, :good, :info, :msg, :debug, :in, :out]
  }

  BOLD  = "\x1B[1m"
  RESET = "\x1B[0m"

  @fancy = LOG_FANCY
  @modes = LEVELS[LOG_LEVEL] || LEVELS[:normal]
  @modes_file = LEVELS[LOG_LEVEL_FILE] || LEVELS[:quiet]

  def fmt(str, mode)
    "#{MODES[mode][:fmt]}#{str}#{RESET}".force_encoding('UTF-8')
  end

  def bold(str)
    "#{BOLD}#{str}#{RESET}"
  end

  def level(l)
   return dbg("Logging level #{l} does not exist") if !LEVELS.key?(l)
    @modes = LEVELS[l]
    dbg("Changed logging level to #{l.to_s}")
  rescue
    dbg("Failed to change logging level")
  end

  def fancy
    @fancy = !@fancy
    @fancy ? dbg("Enabled fancy logs") : dbg("Disabled fancy logs")
  rescue
    dbg("Failed to change logging fanciness")
  end

  def socket
    $log[:socket] = !$log[:socket]
    $log[:socket] ? dbg("Enabled socket logs") : dbg("Disabled socket logs")
  rescue
    dbg("Failed to change socket logging")
  end

  def set_modes(modes)
    @modes = modes.select{ |m| MODES.key?(m) }
    dbg("Set logging modes to #{@modes.join(', ')}.")
  rescue
    dbg("Failed to set logging modes")
  end

  def change_modes(modes)
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

  def modes
    @modes
  end

  # Main function to log text
  def write(
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
    text = text.to_s
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
        alert("Log file was filled!", file: false, discord: true)
      end
      File.write(PATH_LOG_FILE, msg[:plain].strip + "\n", mode: 'a')
    end

    # Log to Discord DMs, if specified
    discord(text) if log_to_discord
    TmpMsg.update(event, text, temp: false) if event

    # Log occurrence to db
    action_inc('logs')
    action_inc('errors') if [:error, :fatal].include?(mode)
    action_inc('warnings') if mode == :warn

    # Return original text
    text
  rescue => e
    puts "Failed to log text: #{e.message}"
    puts e.backtrace.join("\n") if LOG_BACKTRACES
  ensure
    exit if mode == :fatal
  end

  # Handle exceptions
  def exception(e, msg = '', **kwargs)
    write(msg, :error, **kwargs)
    write(e.message, :error)
    write(e.backtrace.join("\n"), :debug) if LOG_BACKTRACES
    action_inc('exceptions')
    msg
  end

  # Send DM to botmaster
  def discord(msg)
    send_message(botmaster.pm, content: msg) if LOG_TO_DISCORD rescue nil
  end

  # Clear the current terminal line
  def clear
    write(' ' * LOG_PAD, :info, newline: false, pad: true)
  end
end

# Shortcuts for different logging methods
def log   (msg, **kwargs)    Log.write(msg, :info,  **kwargs) end
def alert (msg, **kwargs)    Log.write(msg, :warn,  **kwargs) end
def err   (msg, **kwargs)    Log.write(msg, :error, **kwargs) end
def msg   (msg, **kwargs)    Log.write(msg, :msg,   **kwargs) end
def succ  (msg, **kwargs)    Log.write(msg, :good,  **kwargs) end
def dbg   (msg, **kwargs)    Log.write(msg, :debug, **kwargs) end
def lin   (msg, **kwargs)    Log.write(msg, :in,    **kwargs) end
def lout  (msg, **kwargs)    Log.write(msg, :out,   **kwargs) end
def fatal (msg, **kwargs)    Log.write(msg, :fatal, **kwargs) end
def lex   (e, msg, **kwargs) Log.exception(e, msg, **kwargs)  end
def ld    (msg)              Log.discord(msg)                 end

# Shortcuts for logging bot's status (action counters) to db
def action_inc(key)
  GlobalProperty.status_set(key, GlobalProperty.status_get(key) + 1) rescue -1
end

def action_dec(key)
  GlobalProperty.status_set(key, GlobalProperty.status_get(key) - 1) rescue -1
end

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

# Get the required server endpoint to perform the desired request to N++ server
def npp_uri(type, steam_id, **args)
  # Build path component.
  request = case type
  when :scores
    METANET_GET_SCORES
  when :replay
    METANET_GET_REPLAY
  when :levels
    METANET_GET_LEVELS
  when :search
    METANET_GET_SEARCH
  when :submit
    METANET_POST_SCORE
  when :publish
    METANET_POST_LEVEL
  when :login
    METANET_POST_LOGIN
  else
    return
  end
  path = METANET_PATH + '/' + request

  # Build query component. We always add 2 default attributes plus the Steam ID.
  args.merge!({ app_id: APP_ID, steam_auth: '', steam_id: steam_id })
  query = URI.encode_www_form(args)

  # Build full URI
  URI::HTTPS.build(host: METANET_HOST, path: path, query: query)
end

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
  while response.body == METANET_INVALID_RES
    GlobalProperty.update_last_steam_id(fast)
    i += 1
    break if GlobalProperty.get_last_steam_id == initial_id || i > count
    response = Net::HTTP.get_response(uri_proc.call(GlobalProperty.get_last_steam_id, *vargs))
  end
  return nil if response.body == METANET_INVALID_RES
  raise "502 Bad Gateway" if response.code.to_i == 502
  GlobalProperty.activate_last_steam_id
  data_proc.call(response.body)
rescue => e
  if (attempts += 1) < RETRIES
    lex(e, err) if LOG_DOWNLOAD_ERRORS
    sleep(0.25)
    retry
  else
    return nil
  end
end

# Forward an arbitrary request to Metanet, return response's body if 200, nil else
def forward(req)
  return nil if req.nil?
  action_inc('http_forwards')

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

# Simple way to cache results and avoid quick-repeat of (HTTP/db/...) requests
# TODO: Make thread-safe
class Cache

  # For web content the key is the URL
  Entry = Struct.new(:key, :size, :content, :expiry)

  # Capacity in MB, duration in minutes
  def initialize(capacity: 10, duration: 5)
    @capacity = 1024 ** 2 * capacity
    @duration = 60 * duration
    @entries  = {}
    start
  end

  # Check that an entry exists
  def check(key)
    @entries.key?(key)
  end

  # Get the content of an entry
  def get(key)
    check(key) ? @entries[key].content : nil
  end

  # Update the expiry of an entry
  def tap(key)
    return if !check(key)
    @entries[key].expiry = Time.now + @duration
  end

  # Add or overwrite an entry
  def add(key, content)
    remove(key) if check(key)
    return if !guarantee(content.size)
    @entries[key] = Entry.new(key, content.size, content, Time.now + @duration)
  end

  # Remove an entry from the cache
  def remove(key)
    @entries.delete(key)
  end

  # Clear the entire cache
  def clear
    @entries = {}
  end

  private

  # Prune expired entries
  def prune
    @entries.each{ |key, entry| remove(key) if entry.expiry <= Time.now }
  end

  # Start monitoring expired entries
  def start
    @thread = Thread.new do
      loop do
        sleep(60)
        prune
      end
    end
  end

  # Stop monitoring expired entries
  def stop
    @thread.kill
    @thread = nil
  end

  # Compute the total storage of the cache
  def size
    @entries.map{ |key, entry| entry.size }.sum
  end

  # Return the available space remaining in the cache
  def available
    @capacity - size
  end

  # Free _at least_ "space" MB from the cache in order of closest to expiry
  def free(space)
    return if space <= 0
    return clear if space >= @capacity
    @entries.sort_by{ |key, entry| entry.expiry }
            .each{ |key, entry|
              break if space <= 0
              space -= entry.size
              remove(key)
            }
  end

  # Ensure there's enough space in the cache, if possible
  def guarantee(space)
    return false if space > @capacity
    avail = available
    return true if space <= avail
    free(space - avail)
    true
  end
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
  rescue => e
    lex(e, 'Error in forked process')
  ensure
    exit!(0)
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

# Togglable threads are keyed by name so that we can dynamically work with them
# from other threads, even from Discord commands.
def toggle_thread_get(name) $threads_tmp[name] end
def toggle_thread_set(name, &block) $threads_tmp[name] = Thread.new(&block) end

# Execute a shell command
#   stream - Redirect STDOUT/STDERR to Ruby's terminal so we can see
#   output - Return the output (STDOUT/STDERR/status) as an array of strings
def shell(cmd, stream: LOG_SHELL, output: false)
  cmd += ' > /dev/null 2>&1' if !stream && !output
  output ? Open3.capture3(cmd) : system(cmd)
rescue => e
  lex(e, "Failed to execute shell command: #{cmd}")
end

# Execute a python script
def python(cmd, stream: LOG_SHELL, output: false, fast: false)
  shell("#{fast ? 'pypy3' : 'python3'} #{cmd}", stream: stream, output: output)
rescue => e
  lex(e, "Failed to run Python script.")
  nil
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
  converted = 1024 ** ['b', 'kb', 'mb', 'gb', 'tb'].index(unit)
  value.to_f * converted / 1024 ** 2
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

def is_float(str)
  Float(str)
  true
rescue
  false
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

# Make a string extra safe for Windows filenames (more restrictive than UNIX ones):
# - Convert to ASCII, replacing invalid and undefined chars by underscores
# - Remove non-printable characters
# - Replace reserved characters by underscores
# - Replace trailing periods and spaces by underscores
# TODO: Handle reserved names (e.g. CON, COM1, LPT1, etc)
def sanitize_filename(str, limit: FILENAME_LIMIT)
  reserved = "\"*/:<>?\\|"
  to_ascii(str).tr(reserved, '_').sub(/[\.\s]+$/) { |s| '_' * s.length }[0, limit]
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

module ANSI extend self
  # Format
  NONE   = 0
  BOLD   = 1
  FAINT  = 2 # No Discord support
  ITALIC = 3 # No Discord support
  UNDER  = 4

  # Text colors
  BLACK   = 30
  RED     = 31
  GREEN   = 32
  YELLOW  = 33
  BLUE    = 34
  MAGENTA = 35
  CYAN    = 36
  WHITE   = 37

  # Background colors
  BLACK_BG   = 40
  RED_BG     = 41
  GREEN_BG   = 42
  YELLOW_BG  = 43
  BLUE_BG    = 44
  MAGENTA_BG = 45
  CYAN_BG    = 46
  WHITE_BG   = 47

  # Bright text colors (no Discord support)
  BRIGHT_BLACK   = 90
  BRIGHT_RED     = 91
  BRIGHT_GREEN   = 92
  BRIGHT_YELLOW  = 93
  BRIGHT_BLUE    = 94
  BRIGHT_MAGENTA = 95
  BRIGHT_CYAN    = 96
  BRIGHT_WHITE   = 97

  # Bright background colors (no Discord support)
  BRIGHT_BLACK_BG   = 100
  BRIGHT_RED_BG     = 101
  BRIGHT_GREEN_BG   = 102
  BRIGHT_YELLOW_BG  = 103
  BRIGHT_BLUE_BG    = 104
  BRIGHT_MAGENTA_BG = 105
  BRIGHT_CYAN_BG    = 106
  BRIGHT_WHITE_BG   = 107

  def esc(nums = [0])
    "\x1B[#{nums.join(';')}m"
  end

  def unesc(str)
    str.gsub(/\x1B\[[\d;]*m/, '')
  end

  def get_esc(str)
    str[/\x1B\[[\d;]*m/]
  end

  def format(str, bold: false, faint: false, italic: false, underlined: false, fg: nil, bg: nil, close: true)
    str = str.to_s
    codes = []
    codes << BOLD   if bold
    codes << FAINT  if faint
    codes << ITALIC if italic
    codes << UNDER  if underlined
    codes << fg     if fg
    codes << bg     if bg
    str.prepend(esc(codes)) unless codes.empty?
    str << esc if close && !codes.empty?
    str
  end

  # Format code shortcuts
  def none()    esc()        end
  def bold()    esc([BOLD])    end
  def under()   esc([UNDER])   end
  alias_method :clear, :none
  alias_method :reset, :none

  # Basic color code shortcuts
  def black()   esc([BLACK])   end
  def red()     esc([RED])     end
  def green()   esc([GREEN])   end
  def yellow()  esc([YELLOW])  end
  def blue()    esc([BLUE])    end
  def magenta() esc([MAGENTA]) end
  def cyan()    esc([CYAN])    end
  def white()   esc([WHITE])   end

  # Other color shortcuts
  alias_method :good,  :green
  alias_method :bad,   :red
  alias_method :alert, :yellow
  def bool(b) b ? good : bad end
  def tri(n) n > 0 ? good : n < 0 ? bad : none end

end

# Format Markdown text
def mdtext(str, header: 0, url: nil, embed: true)
  # Header stuff
  str.prepend(' ') unless header == 0
  str.prepend('#' * header.abs)
  str.prepend('-') if header < 0

  # URL stuff
  if url
    url = '<' + url + '>' unless embed
    str = "[#{str}](#{url})"
  end

  str
end

# MarkDown shotcuts
def mdurl(text, url, embed = true) mdtext(text, url: url, embed: embed) end
def mdhdr1(text) '# ' + text end
def mdhdr2(text) '## ' + text end
def mdhdr3(text) '### ' + text end
def mdsub(text) '-# ' + text end

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

# This class represents each unit of a document, it's used primarily for building
# the documentation that's shown with the "help" command. Each Doc can have sections,
# which are Docs themselves, thus building the entire documentation in book fashion.
class Doc
  attr_accessor :parent
  attr_writer :index, :level
  attr_reader :sections, :title

  def initialize(title, content = '')
    @title    = title
    @content  = content
    @sections = []
    @index    = 0
    @parent   = nil
    @level    = 1
  end

  def <<(doc)
    @sections << doc
    doc.index = @sections.length
    doc.parent = self
    doc.level = @level + 1
    self
  end

  def write(content)
    @content << content
  end

  def leaf?
    @sections.empty?
  end

  def root?
    @index == 0
  end

  def seq
    return '' if root?
    (@parent.root? ? '' : @parent.seq + '.') + @index.to_s
  end

  def breadcrumbs
    (@parent ? @parent.breadcrumbs + ' > ' : '') + @title
  end

  def toc
    return '' if @sections.empty?
    toc = ANSI.bold + ANSI.under + ANSI.blue + "Table of Contents\n" + ANSI.clear + ANSI.blue
    toc << @sections.map.with_index{ |s, i| "  %d. %s" % [i + 1, s.title] }.join("\n") + ANSI.clear
    format_block(toc)
  end

  def to_s
    "## 📄 [#{seq}] #{breadcrumbs}\n#{@content}\n#{toc}"
  end

  def render(*sects)
    node = self
    sects.each do |idx|
      break if node.leaf?
      node = node.sections[idx]
    end
    node.to_s
  end
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

# <---------------------------------------------------------------------------->
# <------                       FILE MANIPULATION                        ------>
# <---------------------------------------------------------------------------->

FMT_SIZES = {
  'a' => 1, 'A' => 1, 'Z' => 1,
  'c' => 1, 'C' => 1,
  's' => 2, 'S' => 2, 'n' => 2, 'v' => 2,
  'l' => 4, 'L' => 4, 'i' => 4, 'I' => 4, 'N' => 4, 'V' => 4,
  'f' => 4, 'F' => 4, 'e' => 4, 'g' => 4,
  'q' => 8, 'Q' => 8, 'j' => 8, 'J' => 8,
  'd' => 8, 'D' => 8, 'E' => 8, 'G' => 8
}

# Helper for reading files. Raises if not n bytes left to read.
def assert_left(f, n)
  raise "Not enough bytes left (#{f.size} < #{f.pos + n})" if f.size - f.pos < n
end

# Computes the size in bytes of a binary string given the packing format string.
def fmtsz(fmt)
  fmt.tr('<>!_', '').scan(/([A-Za-z])(\d+)?/)
     .inject(0){ |sum, pat| sum + FMT_SIZES[pat[0]] * (pat[1] || 1).to_i }
end

# Unpacks a series of bytes from an open IO object. Only works for unpacking numeric
# types (e.g. integers or floats) and strings.
def ioparse(f, fmt)
  sz = fmtsz(fmt)
  assert_left(f, sz)
  f.read(sz).unpack(fmt)
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

# <---------------------------------------------------------------------------->
# <------                        DISCORD RELATED                         ------>
# <---------------------------------------------------------------------------->

# Discord API version currently in use by Discordrb
def discord_api_version
  Discordrb::API.api_base[/v(\d+)/, 1].to_i
end

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

# Find an app emoji (Discordrb still doesn't support it, so we rawdog it)
def app_emoji(name)
  return if !APP_EMOJIS.key?(name)
  id = APP_EMOJIS[name][TEST ? :test : :prod]
  return if !id
  "<:#{name}:#{id}>"
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
  "```ansi\n#{str}```"
end

# Format a string as a spoiler, by enclosing it within double vertical bars.
def spoiler(str)
  str = str.to_s
  return "|| ||" if str.empty?
  "||#{str.gsub('||', '')}||"
end

# Class to hold a temporary message sent to Discord, whose content may be updated
# and eventually deleted. Intended for easy manipulation of things like progress
# indicators for long processes.
class TmpMsg

  @@msgs = {}

  def self.fetch(event)
    @@msgs[event]
  end

  def self.update(event, content, temp: true)
    if !@@msgs.key?(event)
      @@msgs[event] = new(event, content, temp: temp)
    else
      @@msgs[event].edit(content, temp: temp)
    end
  end

  def self.delete(event)
    return false if !@@msgs.key?(event)
    @@msgs[event].delete
    @@msgs.delete(event)
    true
  end

  def initialize(event, content, temp: true)
    @event   = event
    @content = content
    @temp    = temp
    @mutex   = Mutex.new
    @msg     = nil

    @@msgs[event] = self
    send
  end

  def send
    _thread do
      @mutex.synchronize do
        content = @content
        @content = nil
        @msg = send_message(@event, content: content) rescue nil
      end
    end
    self
  end

  def edit(content, temp: true)
    @content = content
    @temp = false if !temp
    _thread do
      @mutex.synchronize do
        next if !@content || !@msg
        content = @content
        @content = nil
        @msg.edit(content) rescue nil
      end
    end
    self
  end

  def delete
    @@msgs.delete(@event)
    if @temp
      @mutex.synchronize do
        @msg.delete rescue nil
      end
    end
    @event = nil
  end

  def ready?
    !!@content
  end

  def sent?
    !!@msg
  end
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

# Download the files attached to a Discord message
# TODO: Use this for update_ntrace
def fetch_attachments(event, filter: nil, limit_size: 5 * 1024 ** 2, limit_files: 10, log: true)
  # Fetch attachment list, filter by name pattern, and truncate
  files = event.message.attachments
  files.select!{ |f| f.filename =~ filter } if filter
  if files.size > limit_files
    event << "-# **Warning**: Only reading the first #{limit_files} files (too many files)" if log
    files.pop(files.size - limit_files)
  end

  files.map{ |f|
    # Skip files over the size limit
    if f.size > limit_size
      event << "-# **Warning**: File #{f.filename} skipped (too large)" if log
      next
    end

    # Skip corrupt files
    body = Net::HTTP.get(URI(f.url)) rescue nil
    if !body || body.size != f.size
      event << "-# **Warning**: File #{f.filename} skipped (corrupt data received)" if log
      next
    end

    [f.filename, body]
  }.compact.to_h
end

# <---------------------------------------------------------------------------->
# <------                         N++ SPECIFIC                           ------>
# <---------------------------------------------------------------------------->

# Verifies if an arbitrary floating point can be a valid score
def verify_score(score)
  decimal = (score * 60) % 1
  [decimal, 1 - decimal].min < 0.03
end

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
def find_max_type(rank, type, tabs, mappack = nil, board = 'hs', dev = false, frac = false)
  # Filter scores by type and tabs
  type = Level if rank == :gm
  type = mappack || rank == :gp ? type.mappack : type.vanilla
  query = mappack || rank == :gp ? type.where(mappack: mappack) : type
  query = query.where(tab: tabs) if !tabs.empty?
  query = query.where.not("dev_#{board}" => nil) if mappack && dev

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
    total, count = Scorish.total_scores(Level, tabs, type.include?(Levelish), !type.include?(Storyish), mappack, board, frac)
    size = TYPES[type.vanilla.to_s][:size]
    total -= count * (size - 1) * 90.0 / size if board == 'hs'
    mappack && board == 'sr' && !frac ? total.to_i : total.to_f
  else
    query.count
  end
end

# Finds the maximum value a player can reach in a certain ranking
# If 'empty' we allow no types, otherwise default to Level and Episode
def find_max(rank, types, tabs, empty = false, mappack = nil, board = 'hs', dev = false, frac = false)
  # Normalize params
  types = normalize_type(types, empty: empty)

  # Compute type-wise maxes, and add
  maxes = [types].flatten.map{ |t| find_max_type(rank, t, tabs, mappack, board, dev, frac) }
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
  c = star ? 1 : a && b ? b - a : 20
  ([mins, MAXMIN_SCORES].min * c / 20.0).to_i
end

# round float to nearest frame
def round_score(score)
  score.is_a?(Integer) ? score : (score * 60).round / 60.0
end

# Calculate episode splits based on the 5 level scores
def splits_from_scores(scores, start: 90.0, factor: 1, offset: 90.0, frac: false)
  acc = start
  splits = scores.map{ |s| acc += (s / factor - offset) }
  splits = splits.map{ |s| round_score(s) } unless frac
  splits
end

# TODO: Generalize with scale param to sr mode and userlevels/mappacks
def scores_from_splits(splits, offset: 90.0, frac: false)
  scores = splits.each_with_index.map{ |s, i| i == 0 ? s : s - splits[i - 1] + offset }
  scores = scores.map{ |s| round_score(s) } unless frac
  scores
end

# Convert N v1.4 coordinates to N++ coordinates. Since map sizes differ, we
# may want to offset the map data by an integer number of tiles (normally,
# ox = 6, oy = 0, to center it). If the object is out of bounds but still within
# valid range, we set a boolean. If it doesn't even fit in a byte,
# we set another boolean.
def nv14_coord(x, y, ox, oy)
  xf, yf = 4 * (x / Map::NV14_UNITS + ox), 4 * (y / Map::NV14_UNITS + oy)
  zsnap = true if !is_int(xf) || !is_int(yf)
  x, y = xf.round, yf.round
  oob = true if !x.between?(4, 4 * (Map::COLUMNS + 1)) || !y.between?(4, 4 * (Map::ROWS + 1))
  skip = true if !x.between?(0, 0xFF) || !y.between?(0, 0xFF)
  [x, y, xf, yf, zsnap, oob, skip]
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

# Stores all the information related to an NSim simulation, including the input
# map data and demo data, the resulting position and collision information, etc.
# It may contain multiple simulations for the same level, since they're all traced
# together.
class NSim

  attr_reader :count, :success, :correct, :valid, :valid_flags, :complexity, :splits, :scores, :stats
  attr_accessor :ppc
  Collision = Struct.new(:id, :index, :state)

  # One-shot usage of the simulator, shortcut to avoid creation and cleanup of NSim objects
  def self.run(map_data, demo_data, basic_sim: true, basic_render: true, silent: false, &block)
    return if !block_given?
    nsim = new(map_data, demo_data)
    nsim.run(basic_sim: basic_sim, basic_render: basic_render, silent: silent)
    ret = yield(nsim)
    nsim.destroy
    ret
  end

  def initialize(map_data, demo_data)
    @splits_mode    = map_data.is_a?(Array)
    @map_data       = map_data
    @demo_data      = @splits_mode ? demo_data : demo_data.take(MAX_TRACES)
    @demos          = @splits_mode ? Demo.decode(@demo_data) : @demo_data.map{ |d| Demo.decode(d) }
    @count          = @splits_mode ? 1 : @demo_data.size
    @success        = false # Was nsim executed successfully?
    @correct        = false # Was nsim output parsed correctly?
    @valid          = false # Was nsim result a valid run?
    @output         = ''
    @valid_flags    = []
    @scores         = []
    @splits         = []
    @raw_coords     = 40.times.map{ |id| [id, {}] }.to_h
    @raw_chunks     = 40.times.map{ |id| [id, {}] }.to_h
    @raw_collisions = {}
    @ppc            = 0 # Determines the default scaling factor for coordinates
    @complexity     = 0 # Total coordinates
    @stats          = {}
  end

  # Export input files for nsim
  private def export
    if @splits_mode
      File.binwrite(NTRACE_INPUTS_E, @demo_data)
      @map_data.each_with_index{ |map, i| File.binwrite(NTRACE_MAP_DATA_E % i, map) }
    else
      @demo_data.each_with_index{ |demo, i| File.binwrite(NTRACE_INPUTS % i, demo) }
      File.binwrite(NTRACE_MAP_DATA, @map_data)
    end
  end

  # Execute simulation
  # TODO: Store all scores in trace mode into @scores
  private def execute(basic_sim: true, basic_render: true, silent: false)
    t = Time.now
    path = PATH_NTRACE + (basic_sim ? ' --basic-sim' : '') + (basic_render ? '' : ' --full-export')
    stdout, stderr, status = python(path, output: true, fast: false)
    @output = [stdout, stderr].join("\n\n")
    dbg("NSim simulation time: %.3fs" % [Time.now - t]) unless silent
    @success = status.success? && File.file?(@splits_mode ? NTRACE_OUTPUT_E : NTRACE_OUTPUT)
  end

  # Remove all temp files
  private def clean
    if @splits_mode
      FileUtils.rm_f([NTRACE_INPUTS_E, *Dir.glob(NTRACE_MAP_DATA_E % '*')])
    else
      FileUtils.rm_f([NTRACE_MAP_DATA, *Dir.glob(NTRACE_INPUTS % '*')])
    end
    FileUtils.rm_f([@splits_mode ? NTRACE_OUTPUT_E : NTRACE_OUTPUT])
  end

  # Parse nsim's output file in trace mode and read coordinates and collisions
  private def parse_splits(f)
    body = f.read
    @valid_flags = body.scan(/True|False/).map{ |b| b == 'True' }
    @splits = body.split(/True|False/)[1..-1].map{ |d|
      round_score(d.strip.to_i.to_f / 60.0)
    }
    @scores = scores_from_splits(splits, offset: 90.0)
  end

  # Parse nsim's output in splits mode and read level splits and valid flags
  # TODO: Should we deduplicate collisions, or handle it later?
  private def parse_trace(f)
    # Run count and valid flags
    n, = ioparse(f, 'C')
    @valid_flags = ioparse(f, 'C' * n).map{ |b| b > 0 }

    n.times do |i|
      # Entity coordinate section
      entity_count, = ioparse(f, 'S<')
      entity_count.times do
        id, index, chunk_count = ioparse(f, 'CS<S<')
        chunks = ioparse(f, "S<#{2 * chunk_count}").each_slice(2).to_a.transpose
        @raw_chunks[id][index] = chunks unless @raw_chunks[id][index]
        frames = chunks.last.sum
        next f.seek(4 * frames, :CUR) if @raw_coords[id][index]
        @raw_coords[id][index] = f.read(4 * frames)
      end

      # Entity collision section
      collision_count, = ioparse(f, 'L<')
      collision_count.times do
        collision = f.read(6)
        frame, = collision.unpack('S<')
        @raw_collisions[frame] ||= ""
        @raw_collisions[frame] << collision[2, 4]
      end
    end
  end

  # Read and parse nsim's output file
  private def parse(silent: false)
    fn = @splits_mode ? NTRACE_OUTPUT_E : NTRACE_OUTPUT
    return if !File.file?(fn)
    f = File.open(fn, 'rb')
    dbg("NSim output size: %.3fKiB" % [File.size(fn) / 1024.0]) unless silent
    t = Time.now
    @correct = true
    begin
      @splits_mode ? parse_splits(f) : parse_trace(f)
    rescue => e
      lex(e, 'Failed to parse NSim output')
      @correct = false
    end
    dbg("NSim read size: %.3fKiB" % [f.pos / 1024.0]) unless silent
    dbg("NSim parse time: %.3fms" % [1000.0 * (Time.now - t)]) unless silent
  ensure
    f&.close
  end

  # Parse the stats printed to the terminal after execution
  private def parse_stats
    start = @output.strip.rindex("\n").to_i
    @stats = JSON.parse(@output[start..]) rescue {}
  end

  # Print debug information
  def dbg(event)
    if @output.length < DISCORD_CHAR_LIMIT - 100
      output = @output.strip.empty? ? 'None' : "\n" + format_block(@output)
      return "Debug info (terminal output): " + output
    end

    _thread do
      sleep(0.5)
      event.send_file(
        tmp_file(@output, 'nsim_output.txt', binary: false),
        caption: "Debug info (terminal output):"
      )
    end

    ''
  end

  # Check if nsim was executed successfully, its output parsed correctly, and
  # its result is a valid run
  private def validate
    @valid = @success && @correct && @valid_flags.all?
  end

  # Run simulation and parse result inside the NSim mutex
  def run(basic_sim: true, basic_render: true, silent: false)
    $mutex[:nsim].synchronize do
      export
      execute(basic_sim: basic_sim, basic_render: basic_render, silent: silent)
      parse(silent: silent) if @success
    rescue => e
      lex(e, 'Error running NSim')
    ensure
      clean
    end
    parse_stats if @success
    compute_complexity(silent: silent) if @correct
    validate
  end

  # Ensure simulation correctness or halt otherwise
  # @par debug:  Include debug information in error msg
  # @par strict: Force simulation to be valid
  def check(event, debug: false, strict: true)
    return true if @valid || !strict && @correct
    if !@success
      str = 'Simulation failed'
    elsif !@correct
      str = 'Simulation results are corrupt'
    else
      str = 'Simulation isn\'t valid'
    end
    str << ', contact the botmaster for details.'
    if debug
      debug_info = dbg(event)
      str << ' ' + debug_info unless debug_info.empty?
    end
    perror(str)
    false
  end

  # Free references to allocated data so that it's hopefully garbage collected
  def destroy
    @map_data.each(&:clear) if @splits_mode
    @map_data.map!{ nil } if @splits_mode
    @map_data.clear
    @map_data = nil

    @demo_data.each(&:clear) if !@splits_mode
    @demo_data.map!{ nil } if !@splits_mode
    @demo_data.clear
    @demo_data = nil

    @demos.each(&:clear)
    @demos.map!{ nil }
    @demos.clear
    @demos = nil

    return if @splits_mode

    @raw_collisions.each{ |frame, cols| cols.clear }
    @raw_collisions.keys.each{ |frame| @raw_collisions[frame] = nil }
    @raw_collisions.clear
    @raw_collisions = nil

    clear_coords(true)
    @raw_coords.keys.each{ |id| @raw_coords[id] = nil }
    @raw_coords.clear
    @raw_coords = nil
    @raw_chunks.keys.each{ |id| @raw_chunks[id] = nil }
    @raw_chunks.clear
    @raw_chunks = nil

    @output.clear
    @output = nil
  end

  # Free coordinate data (we may just want to do this to disable full anims on command)
  def clear_coords(clear_ninja = false)
    @raw_coords.each{ |id, hash|
      next if id == Map::ID_NINJA && !clear_ninja
      hash.each{ |index, coords| coords.clear }
      hash.keys.each{ |index| hash[index] = nil }
      hash.clear
    }

    @raw_chunks.each{ |id, hash|
      next if id == Map::ID_NINJA && !clear_ninja
      hash.each{ |index, chunks|
        chunks.each(&:clear)
        chunks.clear
      }
      hash.keys.each{ |index| hash[index] = nil }
      hash.clear
    }
  end

  # Length of the simulation, in frames
  def length(index = nil)
    if @splits_mode
      index ? @demos[index].size : @demos.map(&:size).sum
    else
      index ? @raw_chunks[0][index][1].sum : @raw_chunks[0].map{ |index, chunks| chunks[1].sum }.max
    end
  end

  # Run score taken from nclone's terminal output
  def score(index = 0)
    return if !@valid_flags[index]
    round_score(@stats['scores'][index]) rescue nil
  end

  # Run fractional score taken from nclone's terminal output
  # Note: (1 - fraction) is how much of the frame has elapsed, thus it must be
  # in [0, 1). If it were 1, collision wouldn't have happened on this frame.
  def frac(index = 0)
    return if !@valid_flags[index]
    1 - @stats['fractions'][index] rescue nil
  end

  # Run is finished for this ninja on this frame
  def finished?(index, frame, trace: false)
    length(index) < frame + 1 + (trace ? 1 : 0)
  end

  # Run just finished on the given frame range (of width "step")
  def just_finished?(index, frame, step, trace: false)
    length(index).between?(
      frame +    1 + (trace ? 1 : 0),
      frame + step + (trace ? 1 : 0)
    )
  end

  # Return coordinates of an entity for the given frame
  # ppc contains the scale (in pixels per coordinate) if the coordinates need
  # to be scaled for drawing
  def coords(id, index, frame, ppc: @ppc)
    pos = fetch_coords(id, index, frame)
    return nil if !pos
    rescale(pos, ppc)
  end

  # Return coordinates of a ninja for the given frame
  def ninja(index, frame, ppc: @ppc)
    coords(0, index, frame, ppc: ppc)
  end

  # Return inputs of a ninja during the given frame
  def inputs(index, frame)
    @demos&.[](index)&.[](frame)
  end

  # Return array of collisions for the given frame
  def collisions(frame)
    return [] if !@raw_collisions[frame]
    @raw_collisions[frame].scan(/..../m).map{ |c|
      id, index, state = c.unpack('CS<C')
      id = id == 6 ? 7 : id == 8 ? 9 : id # Change doors to switches
      Collision.new(id, index, state)
    }
  end

  # Return entity movements for the given frame range
  def movements(frame, step, ppc: @ppc)
    res = []
    @raw_coords.each{ |id, list|
      list.each{ |index, _|
        pos = fetch_coords(id, index, frame, step)
        next if !pos
        res << { id: id, index: index, coords: rescale(pos, ppc) }
      }
    }
    res
  end

  private

  # Coordinates are exported and stored scaled and packed for memory reasons,
  # so before using them we must unpack them and scale them
  def fetch_coords(id, index, frame, step = 1)
    poslog = @raw_coords[id]&.[](index)
    chunks = @raw_chunks[id]&.[](index)
    return nil if !poslog || !chunks
    max_frame = chunks[0].last + chunks[1].last - 1
    return nil if frame > max_frame
    chunk_index = chunks[0].rindex{ |f| f <= frame }
    chunk_frame = chunks[0][chunk_index]
    chunk_length = chunks[1][chunk_index]
    d = [frame - chunk_frame, chunk_length - 1].min
    f = chunks[1].take(chunk_index).sum + d
    poslog[4 * f, 4].unpack('s<2').map{ |c| c / 10.0 }
  end

  def fetch_coords_old(id, index, frame, step = 1)
    poslog = @raw_coords[id]&.[](index)
    return nil if !poslog || poslog.length / 4 < frame + 1
    f = [frame + step - 1, poslog.length / 4 - 1].min
    poslog[4 * f, 4].unpack('s<2').map{ |c| c / 10.0 }
  end

  # Rescale coordinates (which are given in game units) for drawing
  def rescale(pos, ppc = @ppc)
    ppc == 0 ? pos : pos.map{ |c| (c * ppc * 4.0 / Map::UNITS).round }
  end

  # Measure the complexity of a run by adding up all coordinates of moving entities
  # Used for limiting when full animations can be done
  def compute_complexity(silent: false)
    @complexity = @raw_chunks.map{ |id, hash|
      hash.map{ |index, chunks|
        chunks[1].sum
      }.sum
    }.sum
    dbg("NSim coordinates: %d" % [@complexity]) unless silent
  end
end

# Pack the rank and replay ID of a mappack score into a single (signed) integer
# that is sent to the game. We use the lower 24 bits for the replay ID, which
# allows IDs up to ~16M, and the higher 7 bits for the rank, which allows ranks
# up to 128, although we only need 20 (since we only ever send 1 page at a time)
def pack_replay_id(rank, replay_id)
  rank << REPLAY_ID_BITS | replay_id
end

# Unpack the rank and replay ID from a single integer. See previous function.
def unpack_replay_id(id)
  [id >> REPLAY_ID_BITS, id & ((1 << REPLAY_ID_BITS) - 1)]
end

# <---------------------------------------------------------------------------->
# <------                           GRAPHICS                             ------>
# <---------------------------------------------------------------------------->

# A nice looking progress bar. The style can be split, filled or ascii.
def progress_bar(cur, tot, size: 20, style: :split, single: true)
  return '' if tot < 0
  size += 1 if single
  cur = cur.clamp(0, tot)
  full = (cur * size / tot).to_i

  case style
  when :split
    full_char = '🔘'
    empty_char = '▬'
  when :filled
    full_char = '■'
    empty_char = '□'
  else
    full_char = '#'
    empty_char = '-'
  end

  if single
    empty_char * [full, size - 1].min + full_char + empty_char * [(size - full - 1), 0].max
  else
    full_char * full + empty_char * (size - full)
  end
end

# Transform a table (2-dim array) into a text table
# Individual entries can be either strings or numbers:
#   - Strings will be left-aligned
#   - Numbers will be right-aligned
#   - Floats will also be formatted with 3 decimals
# Additionally, all entries will be padded.
# An entry could also be the symbol :sep, will will insert a separator in that row
def make_table(
    rows,            # List of rows, each being an array of fields
    header = nil,    # Add a header to the table as a row with a single column
    sep_x  = nil,    # Explicitly set the horizontal border character
    sep_y  = nil,    # Explicitly set the vertical border character
    sep_i  = nil,    # Explicitly set the intersection character
    heavy:   false,  # Use the heavy variants of the table borders
    double:  false,  # Use the double-lined variants of the table borders
    hor_pad: true,   # Add one space between the cell border and its contents
    color_b: nil,    # Color for the table border
    color_h: nil,    # Color for the header text
    color_1: nil,    # Color for the even rows' contents
    color_2: nil     # Color for the odd rows' contents
  )
  # Convert all non-integer numbers to floats
  rows.each{ |r|
    next unless r.is_a?(Array)
    r.map!{ |e| e.nil? ? '' : e.is_a?(Numeric) && !e.integer? ? e.to_f : e }
  }

  # Compute column widths
  text_rows = rows.select{ |r| r.is_a?(Array) }
  count = text_rows.map(&:size).max
  rows.each{ |r| if r.is_a?(Array) then r << "" while r.size < count end }
  widths = (0..count - 1).map{ |c| text_rows.map{ |r| (r[c].is_a?(Float) ? "%.3f" % r[c] : ANSI.unesc(r[c].to_s)).length }.max }
  length = widths.sum + (hor_pad ? 2 * widths.size : 0) + widths.size + 1

  # Build connectors
  ver        = sep_y ? sep_y : double ? '║' : heavy ? '┃' : '│'
  hor        = sep_x ? sep_x : double ? '═' : heavy ? '━' : '─'
  up_left    = sep_i ? sep_i : double ? '╔' : heavy ? '┏' : '┌'
  up_mid     = sep_i ? sep_i : double ? '╦' : heavy ? '┳' : '┬'
  up_right   = sep_i ? sep_i : double ? '╗' : heavy ? '┓' : '┐'
  mid_left   = sep_i ? sep_i : double ? '╠' : heavy ? '┣' : '├'
  mid_mid    = sep_i ? sep_i : double ? '╬' : heavy ? '╋' : '┼'
  mid_right  = sep_i ? sep_i : double ? '╣' : heavy ? '┫' : '┤'
  down_left  = sep_i ? sep_i : double ? '╚' : heavy ? '┗' : '└'
  down_mid   = sep_i ? sep_i : double ? '╩' : heavy ? '┻' : '┴'
  down_right = sep_i ? sep_i : double ? '╝' : heavy ? '┛' : '┘'
  sep_up     = up_left   + widths.map{ |w| hor * (w + (hor_pad ? 2 : 0)) }.join(up_mid)   + up_right
  sep_mid    = mid_left  + widths.map{ |w| hor * (w + (hor_pad ? 2 : 0)) }.join(mid_mid)  + mid_right
  sep_down   = down_left + widths.map{ |w| hor * (w + (hor_pad ? 2 : 0)) }.join(down_mid) + down_right
  clean_up   = up_left   + widths.map{ |w| hor * (w + (hor_pad ? 2 : 0)) }.join(hor)      + up_right
  clean_mid  = mid_left  + widths.map{ |w| hor * (w + (hor_pad ? 2 : 0)) }.join(hor)      + mid_right
  clean_down = mid_left  + widths.map{ |w| hor * (w + (hor_pad ? 2 : 0)) }.join(up_mid)   + mid_right

  # Optionally, add color
  color = color_h || color_b || color_1 || color_2
  clear_line = (color ? ANSI.clear : '') + "\n"
  if color
    color_h = ANSI.none if !color_h
    color_b = ANSI.none if !color_b
    color_1 = ANSI.none if !color_1
    color_2 = ANSI.none if !color_2

    ver        = color_b + ver
    sep_up     = color_b + sep_up
    sep_mid    = color_b + sep_mid
    sep_down   = color_b + sep_down
    clean_up   = color_b + clean_up
    clean_mid  = color_b + clean_mid
    clean_down = color_b + clean_down
  else
    color_h, color_b, color_1, color_2 = [''] * 4
  end

  # Build header
  table = ''
  if !!header
    header = ' ' + header + ' '
    table << clean_up + clear_line
    table << ver + color_h + ANSI.bold + header.center(length - 2, '░') + ANSI.clear + ver + clear_line
    table << clean_down + clear_line
  else
    table << sep_up + clear_line
  end

  # Build table rows
  even = true
  sp = hor_pad ? ' ' : ''
  rows.each{ |r|
    next table << sep_mid + clear_line if r == :sep
    clr = color ? (even ? color_1 : color_2) : ''
    r.each_with_index{ |s, i|
      if s.is_a?(String)
        og_fmt = ANSI.get_esc(s)
        s = ANSI.unesc(s)
      end
      sign = s.is_a?(Numeric) || is_float(ANSI.unesc(s)) ? '' : '-'
      fmt = s.is_a?(Integer) ? 'd' : s.is_a?(Float) ? '.3f' : 's'
      table << ver + sp + "#{og_fmt || clr}%#{sign}#{widths[i]}#{fmt}" % s + sp
      table << ANSI.none if og_fmt && !color
    }
    table << ver + clear_line
    even = !even
  }
  table << sep_down + clear_line

  return table
end

# Construct a simple text-based histogram (requires Unicode support)
def make_histogram(
    values, # List of pairs (value, amount)
    title:       'Histogram',   # Title of the histogram, will appear at the top
    steps:       10,            # Rough number of steps in the Y axis
    hor_step:    5,             # X axis grid lines separation (also for labels)
    vert_step:   4,             # Y axis grid lines separation
    grid:        false,         # Whether to draw the grid
    frame:       true,          # Whether to frame the histogram in a rectangle
    labels:      true,          # Whether to write X axis labels
    color_graph: ANSI.blue,     # ANSI color for the graph bars
    color_lines: ANSI.magenta,  # ANSI color for the lines (frame and axes)
    color_text:  ANSI.green     # ANSI color for the axes labels
  )
  max_y = values.max_by(&:last).last
  min_y = 0 #values.min_by(&:last).last
  range_y = max_y - min_y
  if range_y <= steps
    step = 1
    steps = range_y
  else
    step = range_y / steps.to_f
    exp = Math.log10(step).floor
    base_step = step / 10 ** exp
    base_steps = [1, 2, 5]
    step = base_steps.min_by{ |s| (s - base_step).abs } * 10 ** exp
    steps = (range_y / step.to_f).round
  end
  heights = values.map{ |_, n| (n / step.to_f).round }
  pad = range_y >= 1 ? Math.log10(range_y).floor + 1 : 0
  width = pad + 3 + values.size
  histogram = ""
  histogram << ANSI.bold + title.center(width + (frame ? 4 : 0)) + ANSI.clear << "\n" if title
  histogram << (color_lines || '') << '┌─' << '─' * width << '─┐' << "\n" if frame
  steps.times.reverse_each do |s|
    histogram << (color_lines || '') << '│ ' if frame
    histogram << (color_text || '') << "%*d" % [pad, step * (s + 1)] << (color_lines || '') << " │ "
    histogram << color_graph if color_graph
    is_row = grid && (s + 1) % vert_step == 0
    heights.each_with_index{ |h, i|
      is_col = grid && i % hor_step == 0
      empty_char = is_row ? (is_col ? '·' : '·') : (is_col ? '.' : ' ')
      histogram << (h >= (s + 1) ? '▌' : empty_char)
    }
    histogram << (color_lines || '') << ' │' if frame
    histogram << "\n"
  end
  x_axis = '─' * values.size
  i = -hor_step
  x_axis[i += hor_step] = '╥' while i < x_axis.size - hor_step if labels
  histogram << (frame ? (color_lines || '') + '│ ' : '') << '─' * pad + '─┴─' + x_axis << (frame ? ' │' : '')
  label_row = ' ' * x_axis.size
  if labels
    x_axis.each_char.with_index{ |c, i|
      next if c == '─'
      label = values[i][0].to_s
      label_row[i - label.size / 2, label.size] = label
    }
    label_row.prepend(' ' * (pad + 3))
    histogram << "\n" << (frame ? '│ ' : '') << (color_text || '') << label_row << (frame ? ((color_lines || '') + ' │') : '')
  end
  histogram << "\n" << (color_lines || '') << '└─' << '─' * width << '─┘' if frame
  histogram << ANSI.clear
  histogram
end

def create_svg(
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
  g.burn_svg_only
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
  alert("Trying to parse a sub-8bit depth TGA.") if depth < 8

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
#   rolling text (usng modulo), vertical text... and add to Gifenc
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
    $channel          = event.channel
    $mapping_channel  = event.channel
    $nv2_channel      = event.channel
    $content_channel  = event.channel
    $speedrun_channel = event.channel
    $ctp_channel      = event.channel
  elsif !TEST
    channels = $bot.servers[SERVER_ID].channels
    $channel          = channels.find{ |c| c.id == CHANNEL_HIGHSCORES }
    $mapping_channel  = channels.find{ |c| c.id == CHANNEL_USERLEVELS }
    $nv2_channel      = channels.find{ |c| c.id == CHANNEL_NV2 }
    $content_channel  = channels.find{ |c| c.id == CHANNEL_CONTENT }
    $speedrun_channel = channels.find{ |c| c.id == CHANNEL_SPEEDRUNNING }
    $ctp_channel      = channels.find{ |c| c.id == CHANNEL_CTP_HIGHSCORES }
  else
    return
  end
  fix_potato
  log("Main channel:     #{$channel.name}")          if !$channel.nil?
  log("Mapping channel:  #{$mapping_channel.name}")  if !$mapping_channel.nil?
  log("Nv2 channel:      #{$nv2_channel.name}")      if !$nv2_channel.nil?
  log("Content channel:  #{$content_channel.name}")  if !$content_channel.nil?
  log("Speedrun channel: #{$speedrun_channel.name}") if !$speedrun_channel.nil?
  log("CTP channel:      #{$ctp_channel.name}")      if !$ctp_channel.nil?
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
  alert("Left #{names.count} unknown servers: #{names.join(', ')}") if names.count > 0
end

def update_bot_status
  $bot.update_status(BOT_STATUS, BOT_ACTIVITY, nil, 0, false, 0)
end

# Schedule a restart as soon as possible, i.e., as soon as no maintainance tasks
# are being executed, like publishing lotd or downloading the scores.
# If force is true, the threads will be killed immediately.
def restart(reason = 'Unknown reason', force: false)
  alert("Restarting outte due to: #{reason}.", discord: true)
  shutdown(trap: false, force: force)
  exec('./inne')
rescue => e
  lex(e, 'Failed to restart outte', discord: true)
  sleep(5)
  retry
end

# <---------------------------------------------------------------------------->
# <------                             SQL                                ------>
# <---------------------------------------------------------------------------->

# This function needs to be called whenever we've spent a "long time" without
# querying the database, since we may've been disconnected due to inactivity.
# In practice, we call it before the initial request on every command, and
# after threading/forking.
def acquire_connection
  sql("SELECT 1")
  #ActiveRecord::Base.connection.reconnect!
rescue
  false
else
  true
end

# Release a db connection to prevent the pool from filling with zombie connections.
# We presumably are also reaping idle connections regularly, but this is just in case.
def release_connection
  ActiveRecord::Base.connection_pool.release_connection
  #ActiveRecord::Base.connection.disconnect!
rescue
  nil
end

# Shorthand to enclose a function call ensuring that we acquire a db connection
# at the start and release it at the end.
def with_connection(&block)
  return if !block_given?
  acquire_connection
  res = yield
  release_connection
  res
rescue
  nil
end

# Perform arbitrary raw SQL commands
def sql(command)
  ActiveRecord::Base.connection.exec_query(command) rescue nil
end

# Fetch value of certain MySQL variables and statuses
def update_sql_status
  $sql_vars   = sql("SHOW SESSION VARIABLES").rows.to_h
  $sql_status = sql("SHOW GLOBAL STATUS").rows.to_h
  $sql_conns  = sql("SHOW FULL PROCESSLIST").to_a
end

# Checks if current Rails version is at least the provided one
def rails_at_least(ver)
  ActiveRecord.version >= Gem::Version.create(ver)
end

# Checks if current Rails version is at most the provided one
def rails_at_most(ver)
  ActiveRecord.version <= Gem::Version.create(ver)
end

# Creates an enum in Rails. The syntax changed in Rails 7 from keyword to
# positional arguments. The content can be provided as an array of symbols, in
# which case the corresponding values will start at 0. Explicit values can
# be provided if a hash is used instead. An optional hash of options can be
# provided.
def create_enum(name, values, opts = {})
  if rails_at_least('7.0.0')
    enum(name, values, **opts)
  else
    opts[name] = values
    enum(opts)
  end
end

# <---------------------------------------------------------------------------->
# <------                             MATHS                              ------>
# <---------------------------------------------------------------------------->

# Floating point precision. It's the minimum threshold to consider two floats different.
FLT_PREC = 1E-7

# Convert an arbitrary vector given by its two components to a direction scalar
# ranging from -4 to 4. If it's an integer, it means the direction is a perfect
# multiple of PI/4.
def vec2dir(x, y)
  4 * Math::atan2(y, x) / Math::PI
end

# Convert a direction (float, -4 to 4) to an orientation (integer, 0 to 7), which
# is how N++ represents orientations in map data.
def dir2or(dir)
  dir.round % 8
end

# Convert a vector to an orientation
def vec2or(x, y)
  dir2or(vec2dir(x, y))
end

# Convert an N++ orientation (0 to 7) to the correspoding unit direction vector
def or2vec(o)
  r = 2 ** 0.5
  [[1, 0], [r, r], [0, 1], [-r, r], [-1, 0], [-r, -r], [0, -1], [r, -r]][o]
end

# Compute the left normal vector
def lnorm(x, y)
  [-y, x]
end

# Compute the right normal vector
def rnorm(x, y)
  [y, -x]
end

# Compute the Euclidean norm of a vector
def vecnorm(x, y)
  (x * x + y * y) ** 0.5
end

# Check if two numbers are equal, up to the floating precision
def num_eql?(x, y)
  (x - y).abs < FLT_PREC
end

# Check if a vector is unitary
def is_unit(x, y)
  num_eql?(x * x + y * y, 1)
end

# Check if a floating point number is an integer
def is_int(x)
  num_eql?(x, x.round)
end

# Weighted average
def wavg(arr, w)
  return -1 if arr.size != w.size
  arr.each_with_index.map{ |a, i| a*w[i] }.sum.to_f / w.sum
end

# Length of the string representing a number
def numlen(n, float = true)
  n.to_i.to_s.length + (float ? 4 : 0)
end

# Used for correcting a datetime in the database when it's out of phase
# (e.g. after a long downtime of the bot).
def correct_time(time, frequency)
  time -= frequency while time > Time.now
  time += frequency while time < Time.now
  time
end

# From now on, a bbox (short for bounding box) is a rectangle given in the form
# [X, Y, W, H], where [X, Y] are the coordinates of its upper left corner, and
# [W, H] are its dimensions.

# Compute the intersection of a list of bboxes. Returns a bbox if it exists, or
# nil otherwise.
def bbox_intersect(bboxes, round: false)
  bboxes.compact!
  return nil if bboxes.empty?
  x1 = bboxes.map{ |bbox| bbox[0] }.max
  y1 = bboxes.map{ |bbox| bbox[1] }.max
  x2 = bboxes.map{ |bbox| bbox[0] + bbox[2] }.min
  y2 = bboxes.map{ |bbox| bbox[1] + bbox[3] }.min
  x1, y1, x2, y2 = x1.round, y1.round, x2.round, y2.round if round
  w = x2 - x1
  h = y2 - y1
  [w, h].min > 0.01 ? [x1, y1, w, h] : nil
end

# Compute the rectangular hull of a list of bboxes.
def bbox_hull(bboxes, round: false)
  bboxes.compact!
  return nil if bboxes.empty?
  x1 = bboxes.map{ |bbox| bbox[0] }.min
  y1 = bboxes.map{ |bbox| bbox[1] }.min
  x2 = bboxes.map{ |bbox| bbox[0] + bbox[2] }.max
  y2 = bboxes.map{ |bbox| bbox[1] + bbox[3] }.max
  x1, y1, x2, y2 = x1.round, y1.round, x2.round, y2.round if round
  w = x2 - x1
  h = y2 - y1
  [w, h].min > 0.01 ? [x1, y1, w, h] : nil
end

# Computes the area of a bbox.
def bbox_area(bbox)
  bbox ? bbox[2] * bbox[3] : 0
end

# Compute the SHA1 hash. It uses Ruby's native version, unless 'c' is specified,
# in which case it uses our external C function that implements STB's version.
# It transforms the result to an ASCII hex string if 'hex' is specified.
#
# This is done, not for speed, but because the implementations differ, and
# the STB one is the exact one used by N++, so it's the one we need to verify
# the integrity of the hashes generated by the game.
def sha1(data, c: false, hex: false)
  hash = c && $c_inne ? c_stb_sha1(data) : Digest::SHA1.digest(data)
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
