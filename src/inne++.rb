################################################################################
#                                                                              #
#                      READ THE FOLLOWING INSTRUCTIONS                         #
#                   TO SET UP THE BOT FOR THE FIRST TIME                       #
#                                                                              #
# ////// Dependencies and pre-requirements:                                    #
#                                                                              #
#   - MySQL 5.7 or higher. Use utf8mb4 for both encoding and collation, either #
#     server-wide or at least for outte's database. I recommend to use         #
#     the my.cnf configuration file provided in ./util/my.cnf                  #
#                                                                              #
#   - Ruby 2.7 or higher. If you have other versions you want to maintain,     #
#     I recommend to install rbenv and use it to manage multiple simultaneous  #
#     Ruby installations in your environment.                                  #
#                                                                              #
#     To ensure you have the correct version of all the gems (libraries)       #
#     required by outte, install the bundler gem and then run "bundle install" #
#                                                                              #
# ////// Optional dependencies:                                                #
#                                                                              #
#   - Python 3 for the replay tracing capabilities. To disable it, toggle the  #
#     FEATURE_NTRACE variable off in src/constants.rb                          #
#                                                                              #
# ////// Setting up the bot:                                                   #
#                                                                              #
# 0)  Create a Discord bot associated to your account, you may follow any      #
#     standard guide for this. Typically, a moderator will have to authorize   #
#     your bot into the server.                                                #
#                                                                              #
#     Optionally, but recommended, create another bot for development. You can #
#     use this one in a custom server or via DMs, without interferring with    #
#     the production bot.                                                      #
#                                                                              #
# 1)  Set up the following environment variables:                              #
#         * DISCORD_CLIENT : Discord's application client ID for your bot.     #
#         * DISCORD_TOKEN  : Discord's application secret for your bot.        #
#                                                                              #
#     Optionally, set up the following environment variables:                  #
#                                                                              #
#     If you want Twitch integration, to fetch new N++-related streams:        #
#         * TWITCH_CLIENT : Client ID for your Twitch app.                     #
#         * TWITCH_SECRET : Secret for your Twitch app.                        #
#     Alternatively, toggle the UPDATE_TWITCH constant off.                    #
#                                                                              #
#     If you have a secondary bot for development:                             #
#         * DISCORD_CLIENT_TEST : Same as DISCORD_CLIENT for your test bot.    #
#         * DISCORD_TOKEN_TEST  : Same as DISCORD_TOKEN for your test bot.     #
#     Alternatively, never toggle the TEST constant on.                        #
#                                                                              #
#     If you want the security hash integrity checks for score submission:     #
#         * NPP_HASH : Secret password used by N++, contact Eddy for it.       #
#     Alternatively, toggle INTEGRITY_CHECKS off.                              #
#                                                                              #
# 2)  Configure the database environment in ./db/config.yml, by either:        #
#       - Setting up the "outte" environment, or                               #
#       - Creating a new one, and renaming the DATABASE constant.              #
#     If you don't need to change anything, the default outte environment      #
#     provided in that file should work well.                                  #
#                                                                              #
# 3)  Set up the database, by either:                                          #
#       - Creating a database named "inne", running all the migrations, and    #
#         seeding the data. Then, the first time the bot is run, userlevels    #
#         and scores will be downloaded.                                       #
#       - Asking for a current copy of the database. This is simpler, as it    #
#         skips many delicate aspects about setting and configuring the        #
#         database properly (see Contact).                                     #
#                                                                              #
# 4)  Configure additional settings in src/constants.rb. For example:          #
#         BOTMASTER_ID       - Your Discord user ID.                           #
#         SERVER_ID          - N++'s Discord server ID.                        #
#         CHANNEL_HIGHSCORES - #highscores channel ID in N++'s server.         #
#         TEST               - Toggles between production and development bot. #
#         DO_NOTHING         - Don't execute any threads (e.g. score update).  #
#         DO_EVERYTHING      - Execute all threads.                            #
#                                                                              #
# ////// Other notes:                                                          #
#                                                                              #
# - Edit and save the source files in UTF8.                                    #
# - Always run outte from the root directory, NOT from the src directory or    #
#   any other one.                                                             #
#                                                                              #
# ////// Contact:                                                              #
#                                                                              #
# Eddy @ https://discord.gg/nplusplus                                          #
#                                                                              #
################################################################################

$boot_time = Time.now

# We use some gems directly from Github repositories. This is supported by
# Bundler but not by RubyGems directly. The next two lines makes these gems
# available / visible.
require 'rubygems'
require 'bundler/setup'

# Gems useful throughout the entire program
# (each source file might contain further specific gems)
require 'discordrb'
require 'fileutils'
require 'json'
require 'memory_profiler'
require 'net/http'
require 'open3'
require 'pry-byebug'
require 'rbconfig'
require 'time'
require 'yaml'
require 'zlib'

# Import all other source files (the order matters!)
require_relative 'constants.rb'
require_relative 'utils.rb'
require_relative 'io.rb'
require_relative 'interactions.rb'
require_relative 'maps.rb'
require_relative 'models.rb'
require_relative 'userlevels.rb'
require_relative 'mappacks.rb'
require_relative 'messages.rb'
require_relative 'admin.rb'
require_relative 'threads.rb'

# We monkey patch a few core classes (Enumerable, Array, boolean classes...)
# and several of the gems (ActiveRecord, Discordrb, Webrick...)
# See the MonkeyPatch module in models.rb for the details
def monkey_patch
  MonkeyPatches.apply
  log("Applied monkey patches")
rescue => e
  fatal("Failed to apply monkey patches: #{e}")
end

# Initialize the global variables used by the bot
# Also set some environment variables and ensure some folders are created
def initialize_vars
  # Initialize global variables
  $config          = nil
  $channel         = nil
  $components      = nil
  $mapping_channel = nil
  $nv2_channel     = nil
  $content_channel = nil
  $last_potato     = Time.now.to_i
  $potato          = 0
  $last_mishu      = nil
  $status_update   = Time.now.to_i
  $twitch_token    = nil
  $twitch_streams  = {}
  $active_tasks    = {}
  $memory_warned   = false
  $memory_warned_c = false
  $linux           = RbConfig::CONFIG['host_os'] =~ /linux/i
  $mutex           = { ntrace: Mutex.new, tmp_msg: Mutex.new }
  $threads         = []
  $main_queue      = Queue.new
  $sql_vars        = {}
  $sql_status      = {}
  $sql_conns       = []
  $trace_context   = {
    h:       nil,
    theme:   "",
    bg:      nil,
    nsim:    [],
    markers: [],
    texts:   []
  }

  # Set environment variables
  ENV['DISCORDRB_NONACL'] = '1' # Prevent libsodium warning message

  # Create additional needed folders
  [DIR_LOGS].each{ |d| Dir.mkdir(d) unless Dir.exist?(d) }

  log("Initialized global variables")
rescue => e
  fatal("Failed to initialize global variables: #{e}")
end

# Parse the database configuration file, as well as some environment variables
def load_config
  $config = YAML.load_file(CONFIG)[DATABASE]
  $config['discord_client'] = (TEST ? ENV['DISCORD_CLIENT_TEST'] : ENV['DISCORD_CLIENT']).to_i
  $config['discord_secret'] =  TEST ? ENV['DISCORD_TOKEN_TEST']  : ENV['DISCORD_TOKEN']
  $config['twitch_client']  = ENV['TWITCH_CLIENT']
  $config['twitch_secret']  = ENV['TWITCH_SECRET']
  log("Loaded config")
rescue => e
  fatal("Failed to load config: #{e}")
end

# Connect to the database
def connect_db
  ActiveRecord::Base.establish_connection($config)
  GlobalProperty.status_init
  log("Connected to database")
rescue => e
  fatal("Failed to connect to the database: #{e}")
end

# Disconnect from the database
def disconnect_db
  ActiveRecord::Base.connection_handler.clear_active_connections!
  ActiveRecord::Base.connection.disconnect!
  ActiveRecord::Base.connection.close
  log("Disconnected from database")
rescue => e
  fatal("Failed to disconnect from the database: #{e}")
end

# Create and configure the bot
def create_bot
  $bot = Discordrb::Bot.new(
    token:     $config['discord_secret'],
    client_id: $config['discord_client'],
    log_mode:  :quiet,
    intents:   [
      :servers,
      :server_members,
      :server_bans,
      :server_emojis,
      :server_integrations,
      :server_webhooks,
      :server_invites,
      :server_voice_states,
      #:server_presences,
      :server_messages,
      :server_message_reactions,
      :server_message_typing,
      :direct_messages,
      :direct_message_reactions,
      :direct_message_typing
    ]
  )
  log("Created bot")
rescue => e
  fatal("Failed to create bot: #{e}")
end

# Prepare response to a command (new message / edit message)
def craft_response(event, func)
  func.call(event)
rescue OutteError => e
  # These exceptions are manually triggered errors, usually user errors that
  # we may want to log back to Discord

  msg = e.message.strip
  return if msg.empty?
  err(msg) if e.log
  return if !e.discord
  is_auto = event.is_a?(Discordrb::Events::Respondable)
  if tmp_msg = TmpMsg.fetch(event)
    tmp_msg.edit(msg, temp: false)
    event.drain if is_auto
  elsif is_auto
    event << msg
  else
    send_message(event, content: msg, log: false)
  end
  log_message(msg)
rescue => e
  # These exceptions are internal errors, so send warning to the channel and
  # log full trace to the terminal/log file

  lex(e, "Error parsing message.", event: event)
ensure
  TmpMsg.delete(event)
end

# Handle a new command, by crafting a response and sending it appropriately
def handle_command(event, &func)
  # Return if responding is disabled, unless we're the botmaster
  return if !RESPOND && event.user.id != BOTMASTER_ID
  special = false

  # Parse the command and log it
  case event
  when Discordrb::Events::MessageEvent
    msg = parse_message(event)
    remove_mentions!(msg)
    special = msg[0] == '!' && event.user.id == BOTMASTER_ID
    if special
      log_msg = "Special command: #{msg}"
    elsif event.channel.type == 1
      log_msg = "DM by [#{event.user.name}]: #{msg}"
    else
      log_msg = "Mention by [#{event.user.name}] in [#{event.channel.name}]: #{msg}"
    end
    special ? succ(log_msg) : msg(log_msg)
  when Discordrb::Events::ApplicationCommandEvent
    lin("Application command [#{event.command_name}] used by [#{event.user.name}] in [#{event.channel.name}]")
  when Discordrb::Events::ButtonEvent
    lin("Button [#{event.custom_id}] pressed by [#{event.user.name}] in [#{event.channel.name}]")
  when Discordrb::Events::StringSelectEvent
    lin("Select menu [#{event.custom_id}] used by [#{event.user.name}] in [#{event.channel.name}]: [#{event.values.join(', ')}]")
  end

  # Write up response and send it
  acquire_connection
  initialize_components
  func = special ? -> (e) { respond_special(e) } : -> (e) { respond(e) } if !func
  craft_response(event, func)
  send_message(event)
  initialize_components
ensure
  # Ensure to disconnect, otherwise connections leak and the pool fills
  release_connection
end

# Setup triggers for DMs, mentions, messages and interactions.
# Discordrb creates a new thread for each of these, so we must either take
# a db connection from the pool or remember to disconnect at the end to prevent
# zombie connections.
def setup_bot
  # Respond to DMs
  $bot.private_message do |event|
    action_inc('dms')
    handle_command(event)
  rescue => e
    lex(e, 'Failed to handle Discord DM')
  end

  # Respond to pings
  $bot.mention do |event|
    action_inc('pings')
    handle_command(event) unless event.channel.type == 1
  rescue => e
    lex(e, 'Failed to handle Discord ping')
  end

  # Parse all messages, and optionally respond
  $bot.message do |event|
    next if !RESPOND && event.user.id != BOTMASTER_ID
    msg = parse_message(event)
    remove_mentions!(msg)

    if event.channel == $nv2_channel
      $last_potato = Time.now.to_i
      $potato = 0
    end
    mishnub(event) if MISHU && msg.downcase.include?("mishu")
    robot(event) if !!msg[/eddy\s*is\s*a\s*robot/i]
  rescue => e
    lex(e, 'Failed to handle Discord message')
  end

  # Respond to button interactions
  $bot.button do |event|
    action_inc('interactions')
    handle_command(event) { |e| respond_interaction_button(e) }
  rescue => e
    lex(e, 'Failed to handle Discord button interaction')
  end

  # Respond to select menu interactions
  $bot.select_menu do |event|
    action_inc('interactions')
    handle_command(event) { |e| respond_interaction_menu(e) }
  rescue => e
    lex(e, 'Failed to handle Discord select menu interaction')
  end

  # Respond to text input interactions
  $bot.modal_submit do |event|
    action_inc('interactions')
    handle_command(event) { |e| respond_interaction_modal(e) }
  rescue => e
    lex(e, 'Failed to handle Discord text input interaction')
  end

  # Parse new reactions
  $bot.reaction_add do |event|
    handle_command(event) { |e| respond_reaction(e) }
  rescue => e
    lex(e, 'Failed to handle Discord reaction')
  end

  # Parse application commands
  handler = Proc.new do |event|
    handle_command(event) { |e| respond_application_command(e) }
  rescue => e
    lex(e, 'Failed to handle Discord application command')
  end
  register_command_handlers(&handler)

  log("Configured bot")
rescue => e
  fatal("Failed to configure bot: #{e}")
end

# Start running the bot, and set up an interrupt trigger to shut it down
def run_bot
  $bot.run(true)
  trap("INT") {
    shutdown(trap: true, force: true)
    exit
  }
  leave_unknown_servers
  register_commands
  log("Bot connected to servers: #{$bot.servers.map{ |id, s| s.name }.join(', ')}.")
rescue => e
  fatal("Failed to execute bot: #{e}")
end

# Stop running the bot
def stop_bot
  $bot.stop
  log("Stopped bot")
rescue => e
  fatal("Failed to stop the bot: #{e}")
end

# Routine to shutdown the program (exit should be called afterwards)
def shutdown(trap: false, force: false)
  log("Running shutdown tasks...")

  # Stop all background tasks gracefully, unless forcefully killing outte
  # We use a thread to ensure that this one is already listening by the time
  # the clear takes place.
  if !force && !Scheduler.free?
    names = Scheduler.list_blocking.map{ |job| job.task.name }.join(", ")
    names = 'blocking threads' if names.empty?
    alert("Waiting for background tasks to finish (#{names})")
    Scheduler.free
    sleep(0.1) while !Scheduler.free?
  end

  # Stop bot and CLE server, disconnect from DB
  stop_bot
  Sock.off
  #disconnect_db unless trap
  err("Shut down outte")
rescue => e
  fatal("Failed to shut down bot: #{e}")
end

# Bot initialization sequence
log("Loading outte...")
initialize_vars
monkey_patch
load_config
connect_db
create_bot
setup_bot
start_general_tasks
start_metanet_tasks
_thread do
  run_bot
  set_channels
  start_discord_tasks
  ld("Connected to Discord")
end
succ("Loaded outte (%.2fs)" % [Time.now - $boot_time])
binding.pry if DEBUG

# Idle until we need to execute commands on the main thread issued from
# different threads
while cmd = $main_queue.pop
  action_inc('main_commands')
  case cmd.proc
    # Matplotlib depends on PyCall, which is not thread safe
  when :trace
    cmd.result = Map::mpl_trace(**$trace_context)
  else
    action_dec('main_commands')
  end
  cmd.thread.run
end
