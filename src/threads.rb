# This file sets up the background jobs that are running concurrently in separate
# threads, regularly performing periodic tasks such as updating Metanet scores or
# userlevels, posting the level of the day, checking new Twitch streams, etc.
#
# Each of these operations is encapsulated as a Task object, which is a light
# wrapper than handles them gracefully. A task, together with all the necessary
# scheduling functionality, is a Job. Finally, a custom Scheduler module manages
# all the jobs, and includes an event handler to signal other threads for things
# such as task completions.
#
# See also the TASK VARIABLES in src/constants.rb for configuration. See the end
# of the file for the list of tasks.


# Light wrapper that represents an abstract task whose execution is controlled.
# We have graceful exception handling, we know when the task is active, etc.
# @name  - Identifier, for logging purposes. If nil, the task won't be logged.
# @db    - Whether a MySQL database connection is required for this task. In that
#          case, it will be acquired on start and released on stop.
# @log   - Whether to log the task start/end to the terminal.
# @block - The Proc object containing the code of the task to execute.
class Task
  attr_reader :name, :success, :active

  def initialize(name, db: true, log: true, &block)
    # Parameters
    @name  = name
    @db    = db
    @log   = log
    @block = block

    # Other members
    @active  = false
    @success = false
  end

  def start
    log("TASK: Starting \"#{@name}\".") if @log && @name
    @active = true
    acquire_connection if @db
  end

  def stop
    release_connection if @db
    @active = false
    return if !@log || !@name
    if @success
      succ("TASK: Finished \"#{@name}\" successfully.")
    else
      err("TASK: Finished \"#{@name}\" with errors.")
    end
  end

  def execute
    @block.call if @block
    true
  rescue => e
    lex(e, "Running task \"#{@name}\".")
    false
  end

  def run
    start
    @success = execute
    stop
    @success
  end
end

# A job represents a task that is scheduled to be performed regularly or periodically.
# @force - If true, this job will prevent restarting the bot when it's active.
#          A shutdown can still be forced with Ctrl+C.
# @freq  - Frequency of execution in seconds (e.g. daily). 0 means to execute
#          it constantly, and <0 means to execute it only once. It measures the
#          time passed between finishing the task and starting again, ignoring
#          the time execution itself takes.
# @time  - Task initial start time. If it's a String, it's the key name in the
#          GlobalProperties table of the db containing the start time.
# @start - Start running job immediately after creation, following schedule.
# See Task class below for other parameters.
class Job
  cattr_reader :states
  attr_reader :task, :count

  @@states = {
    :init     => { order: 3, desc: 'init'     },
    :ready    => { order: 2, desc: 'ready'    },
    :sleeping => { order: 1, desc: 'sleeping' },
    :running  => { order: 0, desc: 'running'  },
  }

  def initialize(task, force: true, freq: 0, time: nil, start: true)
    # Members
    @task   = task
    @force  = force
    @freq   = nil
    @time   = nil
    @thread = nil
    @count  = 0
    @date_created = Time.now
    @date_started = nil
    @date_last    = nil
    @date_next    = nil
    @should_stop  = true

    # Schedule and start job
    time = Time.now if !time
    reschedule(freq, time)
    start() if start
  end

  def scheduled?
    !!@freq && !!@time
  end

  def running?
    !!@thread && @thread.alive?
  end

  def active?
    @task.active
  end

  def free?
    !active? || !@force
  end

  # Changes scheduling information
  def reschedule(freq, time)
    @freq = freq
    @time = time
  end

  # Cancels scheduling, doesn't stop job if already running
  def cancel
    @freq = nil
    @time = nil
  end

  # Starts running job according to the specified schedule
  def start
    # Ensure we can start the job
    if !scheduled?
      err("Job is not scheduled.")
      return false
    end
    if running?
      err("Job is already running.")
      return false
    end

    # Execute job in a separate thread, inside infinite loop
    @should_stop = false
    @date_started = Time.now
    @thread = Thread.new do
      while true
        sleep(WAIT)

        # If a start time has been provided, parse it. Otherwise, start now.
        if @time.is_a?(String)
          start = with_connection do
            start = correct_time(GlobalProperty.get_next_update(@time), @freq)
            GlobalProperty.set_next_update(@time, start)
            start
          end
        else
          @time = Time.now unless @time.is_a?(Time)
          start = @time
        end

        # Suspend thread until it's time to run the task
        @date_next = start
        now = Time.now
        sleep(start - now) unless start <= now
        @task.run

        # Update state based on task success
        if @task.success
          @count += 1
          @date_last = Time.now
        end
        Scheduler.trigger(:stopped)

        # Prepare next iteration, if necessary
        break if @should_stop
        next if !@task.success
        break if @freq < 0
        @time = Time.now + @freq if @time.is_a?(Time)
      end
    rescue => e
      lex(e, "Error scheduling job \"#{@task.name}\".")
      retry unless @should_stop
    ensure
      reset
    end

    true
  end

  # Reset some state variables between thread restarts
  def reset
    @date_next    = nil
    @date_started = nil
  end

  # Try to stop execution of the job gently (waits till task is completed)
  def stop
    return if !running?
    @should_stop = true
    kill if free?
  end

  # Forcefully stops execution of the job, even if task is currently running
  def kill
    return if !running?
    reset
    @thread.kill
    @thread = nil
    Scheduler.trigger(:killed)
  end

  # Descriptive status of the job
  def state
    return :running  if active?
    return :sleeping if running?
    return :ready    if scheduled?
    :init
  end

  # When was the last last executed
  def time
    @date_last
  end

  # How long since we started the job
  def runtime
    return nil if !@date_started
    [Time.now - @date_started, 0.0].max
  end

  # How long till the task is executed again
  def eta
    return nil if !@date_next
    [@date_next - Time.now, 0.0].max
  end

end

# Manager class that takes care of scheduling and running jobs
# A job is a task that needs to be executed periodically or regularly
module Scheduler extend self
  @@jobs = []
  @@listeners = []

  def add(name, freq: 0, time: nil, db: true, force: true, log: true, &block)
    task = Task.new(name, db: db, log: log, &block)
    job = Job.new(task, force: force, freq: freq, time: time)
    @@jobs << job
  end

  # Getters
  def list()           @@jobs                                end
  def list_scheduled() @@jobs.select{ |job| job.scheduled? } end
  def list_running()   @@jobs.select{ |job| job.running?   } end
  def list_active()    @@jobs.select{ |job| job.active?    } end
  def list_blocking()  @@jobs.select{ |job| !job.free?     } end

  # Counters
  def count()           @@jobs.count                         end
  def count_scheduled() @@jobs.count{ |job| job.scheduled? } end
  def count_running()   @@jobs.count{ |job| job.running?   } end
  def count_active()    @@jobs.count{ |job| job.active?    } end
  def count_blocking()  @@jobs.count{ |job| !job.free?     } end

  # Whether no forced background tasks are active
  def free?
    @@jobs.all?(&:free?)
  end

  # Gracefully stop all jobs
  def clear
    @@jobs.each{ |job| job.stop }
    broadcast(:clear) if free?
  end

  # Forcefully kill all jobs
  def terminate
    @@jobs.each{ |job| job.kill }
  end

  # A thread can register to be woken up by a specific event
  def listen(event)
    @@listeners << { event: event, thread: Thread.current }
    sleep
  end

  # Broadcast an event to all threads listening to it
  def broadcast(event)
    @@listeners.each{ |ls|
      ls[:thread].run if ls[:event] == event
    }
  end

  # Handle what happens when an event is raised
  def trigger(event)
    # Always broadcast the main event
    broadcast(event)

    # Test if other events need to be broadcasted
    case event
    when :stopped
      broadcast(:clear) if free?
    end
  end
end

# <---------------------------------------------------------------------------->
# <------                      TASK DEFINITIONS                          ------>
# <---------------------------------------------------------------------------->

# Periodically (every ~5 mins) perform several useful tasks.
def update_status
  if !OFFLINE_STRICT
    # Download newest userlevels from all 3 modes
    [MODE_SOLO, MODE_COOP, MODE_RACE].each do |mode|
      Userlevel.browse(mode: mode, update: true) rescue next
    end

    # Update scores for lotd, eotw and cotm
    GlobalProperty.get_current(Level).update_scores
    GlobalProperty.get_current(Episode).update_scores
    GlobalProperty.get_current(Story).update_scores
  end

  # Update bot's status and activity (it only lasts so much)
  update_bot_status

  # Clear old message logs and userlevel query cache
  Message.clean
  UserlevelCache.clean

  # Finish
  $status_update = Time.now.to_i
end

# Check for new Twitch streams, and send notices.
def update_twitch
  Twitch::update_twitch_streams
  Twitch::new_streams.each{ |game, list|
    list.each{ |stream|
      Twitch::post_stream(stream)
    }
  }
end

# Update missing demos (e.g., if they failed to download originally)
def download_demos
  archives = Archive.where(lost: false)
                    .joins("LEFT JOIN demos ON demos.id = archives.id")
                    .where("demos.demo IS NULL")
                    .pluck(:id, :replay_id, :highscoreable_type)
  archives.each_with_index do |ar, i|
    attempts ||= 0
    Demo.find_or_create_by(id: ar[0]).update_demo
  rescue => e
    lex(e, "Updating demo with ID #{ar[0].to_s}")
    ((attempts += 1) < ATTEMPT_LIMIT) ? retry : next
  end
end

# Compute and send the weekly highscoring report
def send_report
  base  = Time.new(2020, 9, 3, 0, 0, 0, "+00:00").to_i # when archiving begun
  now   = Time.now.to_i
  time  = [now - REPORT_UPDATE_SIZE,  base].max
  pad   = [2, DEFAULT_PADDING, 6, 6, 6, 5, 4]
  log   = [] if LOG_REPORT

  changes = Archive.where("UNIX_TIMESTAMP(`date`) > #{time} AND `cheated` = 0")
                   .order('`date` DESC')
                   .map{ |ar| [ar.metanet_id, ar.find_rank(time), ar.find_rank(now), ar.highscoreable, ar.score] }
                   .group_by{ |s| s[0] }
                   .map{ |id, scores|
                         [
                           id,
                           scores.group_by{ |s| s[3] }
                                 .map{ |highscoreable, versions|
                                       max = versions.map{ |v| v[4] }.max
                                       versions.select{ |v| v[4] == max }.first
                                     }
                         ]
                       }
                   .map{ |id, scores|
                         log << [Player.find_by(metanet_id: id).name, scores.sort_by{ |s| [s[2], s[3].id] }] if LOG_REPORT
                         {
                           player: Player.find_by(metanet_id: id).name,
                           points: scores.map{ |s| s[1] - s[2] }.sum,
                           top20s: scores.select{ |s| s[1] == 20 }.size,
                           top10s: scores.select{ |s| s[1] > 9 && s[2] <= 9 }.size,
                           top05s: scores.select{ |s| s[1] > 4 && s[2] <= 4 }.size,
                           zeroes: scores.select{ |s| s[2] == 0 }.size
                         }
                       }
                   .sort_by{ |p| -p[:points] }
                   .each_with_index
                   .map{ |p, i|
                         values = p.values.prepend(i)
                         values.each_with_index.map{ |v, j|
                           s = v.to_s.rjust(pad[j], " ")[0..pad[j]-1]
                           s += " |" if [0, 1, 2].include?(j)
                           s
                         }.join(" ")
                       }
                   .take(20)
                   .join("\n")

  header = ["", "Player", "Points", "Top20s", "Top10s", "Top5s", "0ths"]
             .each_with_index
             .map{ |h, i|
                   s = h.ljust(pad[i], " ")
                   s += " |" if [0, 1, 2].include?(i)
                   s
                 }
             .join(" ")
  sep = "-" * (pad.sum + pad.size + 5)

  send_message($channel, content: "**Weekly highscoring report**:#{format_block([header, sep, changes].join("\n"))}")

  if LOG_REPORT
    log_text = log.sort_by{ |name, scores| name }.map{ |name, scores|
      scores.map{ |s|
        name[0..14].ljust(15, " ") + " " + (s[1] == 20 ? " x  " : s[1].ordinalize).rjust(4, "0") + "->" + s[2].ordinalize.rjust(4, "0") + " " + s[3].name.ljust(10, " ") + " " + ("%.3f" % (s[4].to_f / 60.0))
      }.join("\n")
    }.join("\n")
    File.write(PATH_LOG_REPORT, log_text)
  end
end

# Compute and send the daily highscoring summary:
# 1) Seconds of total score gained.
# 2) Seconds of total score in 19th gained.
# 3) Total number of changes.
# 4) Total number of involved players.
# 5) Total number of involved highscoreables.
def send_summary
  base  = Time.new(2020, 9, 3, 0, 0, 0, "+00:00").to_i # when archiving begun
  now   = Time.now.to_i
  time  = [now - SUMMARY_UPDATE_SIZE, base].max
  total = { "Level" => [0, 0, 0, 0, 0], "Episode" => [0, 0, 0, 0, 0], "Story" => [0, 0, 0, 0, 0] }

  changes = Archive.where("UNIX_TIMESTAMP(`date`) > #{time}", cheated: false)
                   .order('`date` DESC')
                   .map{ |ar|
                     total[ar.highscoreable.class.to_s][2] += 1
                     [ar.metanet_id, ar.highscoreable]
                   }
  changes.group_by{ |s| s[1].class.to_s }
         .each{ |klass, scores|
                total[klass][3] = scores.uniq{ |s| s[0]    }.size
                total[klass][4] = scores.uniq{ |s| s[1].id }.size
              }
  changes.map{ |h| h[1] }
         .uniq
         .each{ |h|
                total[h.class.to_s][0] += Archive.scores(h, now).first[1] - Archive.scores(h, time).first[1]
                total[h.class.to_s][1] += Archive.scores(h, now).last[1] - Archive.scores(h, time).last[1]
              }

  total = total.map{ |klass, n|
    "• There were **#{n[2]}** new scores by **#{n[3]}** players " +
    "in **#{n[4]}** #{klass.downcase.pluralize}, " +
    "making the boards **#{"%.3f" % [n[1].to_f / 60.0]}** seconds harder " +
    "and increasing the total 0th score by **#{"%.3f" % [n[0].to_f / 60.0]}** seconds."
  }.join("\n")
  send_message($channel, content: "**Daily highscoring summary**:\n" + total)
end

# Compute and send the daily userlevel highscoring report for the newest
# 500 userlevels.
def send_userlevel_report
  while $mapping_channel.nil?
    err("Not connected to a channel, not sending userlevel report")
    sleep(5)
  end

  send_message($mapping_channel, content: UserlevelHistory.report(1))
  sleep(0.25)
  send_message($mapping_channel, content: UserlevelHistory.report(-1))
  update_userlevel_histories
end

# Update database scores for Metanet Solo levels, episodes and stories
def download_high_scores
  [Level, Episode, Story].each do |type|
    type.all.each do |o|
      attempts ||= 0
      o.update_scores
    rescue => e
      lex(e, "Downloading high scores for #{o.class.to_s.downcase} #{o.id.to_s}")
      ((attempts += 1) <= ATTEMPT_LIMIT) ? retry : next
    end
  end
end

# Precompute and store several useful userlevel rankings daily, so that we
# can check the history later, since we don't have a differential table here.
def update_userlevel_histories
  now = Time.now
  [-1, 1, 5, 10, 20].each{ |rank|
    rankings = Userlevel.rank(rank == -1 ? :points : :rank, rank == 1 ? true : false, rank - 1, true)
    attrs    = UserlevelHistory.compose(rankings, rank, now)
    ActiveRecord::Base.transaction do
      UserlevelHistory.create(attrs)
    end
  }
end

# Download the scores for the scores for the latest 500 userlevels, for use in
# the daily userlevel highscoring rankings.
def download_userlevel_scores
  Userlevel.where(mode: :solo).order(id: :desc).take(USERLEVEL_REPORT_SIZE).each do |u|
    attempts ||= 0
    u.update_scores
  rescue => e
    lex(e, "Downloading scores for userlevel #{u.id}")
    ((attempts += 1) <= ATTEMPT_LIMIT) ? retry : next
  end
end

# Continuously, but more slowly, download the scores for ALL userlevels, to keep
# the database scores reasonably up to date.
# We select the userlevels to update in reverse order of last update, i.e., we
# always update the ones which haven't been updated the longest.
def update_all_userlevels_chunk
  dbg("Downloading next userlevel chunk scores...")
  Userlevel.where(mode: :solo).order('score_update IS NOT NULL, score_update').take(USERLEVEL_DOWNLOAD_CHUNK).each do |u|
    sleep(USERLEVEL_UPDATE_RATE)
    attempts ||= 0
    u.update_scores
  rescue => e
    lex(e, "Downloading scores for userlevel #{u.id}")
    ((attempts += 1) <= ATTEMPT_LIMIT) ? retry : next
  end
  dbg("Downloaded userlevel chunk scores")
end

# Download some userlevel tabs (best, top weekly, featured, hardest), for all
# 3 modes, to keep those lists up to date in the database
def update_userlevel_tabs
  [MODE_SOLO, MODE_COOP, MODE_RACE].each{ |m|
    USERLEVEL_TABS.select{ |k, v| v[:update] }.keys.each { |qt|
      page = 0
      page += 1 while Userlevel::update_relationships(qt, page, m)
      UserlevelTab.where(mode: m, qt: qt)
                  .where("`index` >= #{USERLEVEL_TABS[qt][:size]}")
                  .delete_all unless USERLEVEL_TABS[qt][:size] == -1
    }
  }
end

############ LOTD FUNCTIONS ############

# Daily reminders for eotw and cotm
def send_eotw_reminder(ctp = false)
  channel = ctp ? $ctp_channel : $channel
  eotw = GlobalProperty.get_current(Episode, ctp)
  return if eotw.nil?
  send_message(channel, content: "Also, remember that the current #{ctp ? 'CTP ' : ''}episode of the week is #{eotw.format_name}.")
rescue => e
  lex(e, 'Failed to send eotw reminder')
end

def send_cotm_reminder(ctp = false)
  channel = ctp ? $ctp_channel : $channel
  cotm = GlobalProperty.get_current(Story, ctp)
  return if cotm.nil?
  send_message(channel, content: "Also, remember that the current #{ctp ? 'CTP ' : ''}column of the month is #{cotm.format_name}.")
rescue => e
  lex(e, 'Failed to send cotm reminder')
end

# Publish the lotd/eotw/cotm
# This function also updates the scores of said board, and of the new one
def send_channel_next(type, ctp = false)
  # Get old and new levels/episodes/stories
  last = GlobalProperty.get_current(type, ctp)
  current = GlobalProperty.get_next(type, ctp)
  GlobalProperty.set_current(type, current, ctp)
  if current.nil?
    err("No more #{ctp ? 'CTP ' : ''}#{type.to_s.downcase.pluralize}")
    return false
  end

  # Update scores, if need be
  if !OFFLINE_STRICT && UPDATE_SCORES_ON_LOTD && !ctp
    last.update_scores if !last.nil?
    current.update_scores
  end

  # Format caption
  prefix = type == Level ? 'Time'  : "It's also time"
  type_n = type == Level ? 'level' : type == Episode ? 'episode' : 'column'
  period = type == Level ? 'day'   : type == Episode ? 'week'    : 'month'
  time   = type == Level ? 'today' : "this #{period}"
  caption = "#{prefix} for a new #{ctp ? 'CTP ' : ''}#{type_n} of the #{period}!"
  caption << " The #{type_n} for #{time} is #{current.format_name}."

  # Send screenshot and scores
  channel = ctp ? $ctp_channel : $channel
  screenshot = Map.screenshot(file: true, h: current.map) rescue nil
  caption += "\nThere was a problem generating the screenshot!" if screenshot.nil?
  channel.send(caption, false, nil, screenshot.nil? ? [] : [screenshot])
  sleep(0.25)
  channel.send("Current #{OFFLINE_STRICT ? "(cached) " : ""}high scores:\n#{format_block(current.format_scores(mode: 'dual'))}")
  sleep(0.25)

  # Send differences, if available
  old_scores = GlobalProperty.get_saved_scores(type, ctp)
  if last.nil? || old_scores.nil?
    channel.send("There was no previous #{ctp ? 'CTP ' : ''}#{type_n} of the #{period}.")
  elsif !OFFLINE_STRICT || ctp
    diff = last.format_difference(old_scores, 'dual')
    channel.send(last.format_difference_header(diff, past: true))
  end
  GlobalProperty.set_saved_scores(type, current, ctp)

  return true
end

# General driver for the function above
def start_level_of_the_day(ctp = false)
  # Ensure channel is available
  while (ctp ? $ctp_channel : $channel).nil?
    err("#{ctp ? 'CTP h' : 'H'}ighscoring channel not found, not sending level of the day")
    sleep(5)
  end

  # Flags
  eotw_day  = Time.now.sunday?
  cotm_day  = Time.now.day == 1
  post_lotd = (ctp ? POST_CTP_LOTD : POST_LOTD) || (ctp ? TEST_CTP_LOTD : TEST_LOTD) || DO_EVERYTHING
  post_eotw = (ctp ? POST_CTP_EOTW : POST_EOTW) || (ctp ? TEST_CTP_LOTD : TEST_LOTD) || DO_EVERYTHING
  post_cotm = (ctp ? POST_CTP_COTM : POST_COTM) || (ctp ? TEST_CTP_LOTD : TEST_LOTD) || DO_EVERYTHING

  # Post each highscoreable, if enabled
  send_channel_next(Level,   ctp) if post_lotd
  sleep(0.25)
  send_channel_next(Episode, ctp) if post_eotw && eotw_day
  sleep(0.25)
  send_channel_next(Story,   ctp) if post_cotm && cotm_day
  sleep(0.25)

  # Post reminders
  send_eotw_reminder(ctp) if post_lotd && !eotw_day
  sleep(0.25)
  send_cotm_reminder(ctp) if post_lotd && !cotm_day
  sleep(0.25)

  # Post report and summary
  if !ctp && (REPORT_METANET || TEST_LOTD || DO_EVERYTHING)
    send_report
    sleep(0.25)
    send_summary
  end
end

# Prevent running out of memory due to memory leaks and risking the OOM killer
# from obliterating outte by preemptively restarting it when no active tasks
# (e.g. lotd or score update) are being executed.
def monitor_memory
  # Gather memory info
  mem = getmem
  total = meminfo['MemTotal']
  available = meminfo['MemAvailable']
  used = total - available

  # If below 25% of available memory, take action
  available_ratio = available.to_f / total
  used_ratio = mem.to_f / used
  if available_ratio < MEMORY_LIMIT.clamp(0, 1)
    str = "#{"%.2f%%" % [100 - 100 * available_ratio]} used, #{"%.2f%%" % [100 * used_ratio]} by outte"
    if used_ratio > MEMORY_USAGE.clamp(0, 1)
      _thread do restart("Lack of memory (#{str})") end
    elsif !$memory_warned
      warn("Something's taking up excessive memory, and it's not outte! (#{str})", discord: true)
      $memory_warned = true
    end
  end

  # If below 5%, send another warning to Discord, regardless of outte usage
  if available_ratio < MEMORY_CRITICAL.clamp(0, 1) && !$memory_warned_c
    warn("Memory usage is critical! (#{"%.2f%%" % [100 - 100 * available_ratio]})", discord: true)
    $memory_warned_c = true
  end
end

# Prevent running out of available database connections
def monitor_db
  update_sql_status

  # MySQL threads
  cur = $sql_status['Threads_connected'].to_i
  max = $sql_vars['max_connections'].to_i
  ratio = cur.to_f / max
  restart("Lack of MySQL threads (#{cur} / #{max})") if ratio >= SQL_LIMIT

  # Rails pool
  stats = ActiveRecord::Base.connection_pool.stat
  cur = stats[:connections]
  max = stats[:size]
  ratio = cur.to_f / max
  warn("Lack of Rails pool connections (#{cur} / #{max})", discord: true) if ratio >= POOL_LIMIT
end

def potato
  return false if !$nv2_channel || !$last_potato
  return false if Time.now.to_i - $last_potato.to_i < POTATO_FREQ
  send_message($nv2_channel, content: FOOD[$potato], db: false)
  log(FOOD[$potato].gsub(/:/, '').capitalize + 'ed nv2')
  $potato = ($potato + 1) % FOOD.size
  $last_potato = Time.now.to_i
end

# <---------------------------------------------------------------------------->
# <------                        SCHEDULE TASKS                          ------>
# <---------------------------------------------------------------------------->

# These tasks are completely autonomous and don't depend on any other service
# being up, such as Metanet's server or Discord's connection.
# They're the first ones to be started.
def start_general_tasks
  # Monitor machine's RAM regularly, restart outte when needed (Linux only).
  Scheduler.add("Monitor memory", freq: MEMORY_DELAY, db: false, force: false, log: false) { monitor_memory } if MEMORY_MONITOR && $linux

  # Monitor available MySQL threads regularly
  Scheduler.add("Monitor database", freq: SQL_DELAY, force: false, log: false) { monitor_db } if SQL_MONITOR

  # Custom Leaderboard Engine (provides native leaderboard support for mappacks).
  $threads << Thread.new { Server::on } if SOCKET && !DO_NOTHING
end

# These tasks perform periodic operations querying Metanet's database (e.g. to
# fetch scores or new userlevels), and thus, they rely on their server being up.
# We always start them up, but they will fail if it's not up.
def start_metanet_tasks
  return if DO_NOTHING || OFFLINE_MODE

  # Update all Metanet top20 highscores daily
  freq = TEST && TEST_SCORES ? -1 : HIGHSCORE_UPDATE_FREQUENCY
  time = TEST && TEST_SCORES ? nil : 'score'
  Scheduler.add("Download scores", freq: freq, time: time) { download_high_scores } if DO_EVERYTHING || UPDATE_SCORES || TEST && TEST_SCORES

  # Download demos for scores missing it daily
  Scheduler.add("Download demos", freq: DEMO_UPDATE_FREQUENCY, time: 'demo') { download_demos } if DO_EVERYTHING || UPDATE_DEMOS

  # Download scores for newest userlevels daily
  Scheduler.add("Userlevel scores", freq: USERLEVEL_SCORE_FREQUENCY, time: 'userlevel_score') { download_userlevel_scores } if DO_EVERYTHING || UPDATE_USERLEVELS

  # Update userlevels present in each tab (hardest, featured...) daily
  Scheduler.add("Userlevel tabs", freq: USERLEVEL_TAB_FREQUENCY, time: 'userlevel_tab') { update_userlevel_tabs } if DO_EVERYTHING || UPDATE_USER_TABS

  # Gradually update all userlevel scores (every 5 secs)
  Scheduler.add("Userlevel chunk", force: false, log: false) { update_all_userlevels_chunk } if DO_EVERYTHING || UPDATE_USER_GLOB
end

# These tasks perform operations relying on a Discord connection to the N++
# server, such as posting lotd or the highscoring report. We start these last,
# and only on the condition that the connection has been established.
def start_discord_tasks
  return if DO_NOTHING

  # Update the bot's status, update lotd scores, etc, every 5 mins
  Scheduler.add("Update status", freq: STATUS_UPDATE_FREQUENCY, log: false) { update_status } if DO_EVERYTHING  || UPDATE_STATUS

  # Check for new N++-related streams of Twitch every minute
  Scheduler.add("Update Twitch", freq: TWITCH_UPDATE_FREQUENCY, log: false, db: false) { update_twitch } if DO_EVERYTHING  || UPDATE_TWITCH

  # Post lotd daily, eotw weekly and cotm monthly
  freq = TEST && TEST_LOTD ? -1 : LEVEL_UPDATE_FREQUENCY
  time = TEST && TEST_LOTD ? nil : 'level'
  Scheduler.add("Level of the day", freq: freq, time: time) { start_level_of_the_day(false) }

  # Post CTP lotd daily, eotw weekly and cotm monthly
  freq = TEST && TEST_CTP_LOTD ? -1 : CTP_LEVEL_FREQUENCY
  time = TEST && TEST_CTP_LOTD ? nil : 'ctp_level'
  Scheduler.add("CTP level of the day", freq: freq, time: time) { start_level_of_the_day(true) }

  # Post highscoring report for newest userlevels, and save histories
  freq = TEST && TEST_UL_REPORT ? -1 : USERLEVEL_REPORT_FREQUENCY
  time = TEST && TEST_UL_REPORT ? nil : 'userlevel_report'
  Scheduler.add("Userlevel report", freq: freq, time: time) { send_userlevel_report } if DO_EVERYTHING  || REPORT_USERLEVELS || TEST_UL_REPORT

  # Regularly stun nv2 users with a fruit emoji
  Scheduler.add("Potato", db: false, log: false) { potato } if POTATO
end
