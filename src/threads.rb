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

require_relative 'constants.rb'
require_relative 'utils.rb'
require_relative 'models.rb'

# Light wrapper that represents an abstract task whose execution is controlled.
# We have graceful exception handling, we know when the task is active, etc.
# @name  - Identifier, for logging purposes. If nil, the task won't be logged.
# @db    - Whether a MySQL database connection is required for this task. In that
#          case, it will be acquired on start and released on stop.
# @force - If true, this task will prevent restarting the bot when it's running.
#          A shutdown can still be forced with Ctrl+C.
# @log   - Whether to log the task start/end to the terminal.
# @block - The Proc object containing the code of the task to execute.
class Task
  attr_reader :name, :active, :success

  def initialize(name, db: true, force: true, log: true, &block)
    # Parameters
    @name  = name
    @db    = db
    @force = force
    @log   = log
    @block = block

    # Other members
    @active  = false
    @success = false
  end

  def start
    log("TASK: Starting \"#{@name}\".") if @log && @name
    @active = true if @force
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
# @freq  - Frequency of execution in seconds (e.g. daily). 0 means to execute
#          it constantly, and <0 means to execute it only once. It measures the
#          time passed between finishing the task and starting again, ignoring
#          the time execution itself takes.
# @time  - Task initial start time. If it's a String, it's the key name in the
#          GlobalProperties table of the db containing the start time.
# @start - Start running job immediately after creation, following schedule.
# See Task class below for other parameters.
class Job
  attr_reader :count

  def initialize(task, freq: 0, time: nil, start: true)
    # Members
    @task   = task
    @freq   = nil
    @time   = nil
    @thread = nil
    @count  = 0
    @should_stop = false

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
    @thread = Thread.new do
      while true
        sleep(WAIT)
        now = Time.now

        # If a start time has been provided, parse it. Otherwise, start now.
        if @time.is_a?(String)
          start = correct_time(GlobalProperty.get_next_update(@time), @freq)
          GlobalProperty.set_next_update(@time, start)
        elsif @time.is_a?(Time)
          start = @time
        else
          @time = now
          start = now
        end

        # Suspend thread until it's time to run the task
        sleep(start - now) unless start <= now
        @task.run
        @count += 1 if @task.success
        Scheduler.trigger(:finish)
        break if @should_stop

        # Prepare next iteration
        next if !@task.success
        break if @freq < 0
        @time = Time.now + @freq if @time.is_a?(Time)
      end
    rescue => e
      lex(e, "Error scheduling job \"#{@task.name}\".")
      retry
    end

    true
  end

  # Try to stop execution of the job gently (waits till task is completed)
  def stop
    return if !running?
    active? ? (@should_stop = true) : kill
  end

  # Forcefully stops execution of the job, even if task is currently running
  def kill
    return if !running?
    @thread.kill
    @thread = nil
  end

  def state
    active? ? 'running' : running? ? 'scheduled' : scheduled? ? 'ready' : 'created'
  end

end

# Manager class that takes care of scheduling and running jobs
# A job is a task that needs to be executed periodically or regularly
module Scheduler extend self
  @@jobs = []
  @@listeners = []

  def add(name, freq: 0, time: nil, db: true, force: true, log: true, &block)
    task = Task.new(name, db: db, force: force, log: log, &block)
    job = Job.new(task, freq: freq, time: time)
    @@jobs << job
  end

  # Getters
  def list()           @@jobs                                end
  def list_scheduled() @@jobs.select{ |job| job.scheduled? } end
  def list_running()   @@jobs.select{ |job| job.running?   } end
  def list_active ()   @@jobs.select{ |job| job.active?    } end

  # Counters
  def count()           @@jobs.count                         end
  def count_scheduled() @@jobs.count{ |job| job.scheduled? } end
  def count_running()   @@jobs.count{ |job| job.running?   } end
  def count_active ()   @@jobs.count{ |job| job.active?    } end

  # Gracefully stop all jobs
  def clear
    @@jobs.each{ |job| job.stop }
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
    when :finish
      broadcast(:clear) if count_active == 0
    end
  end
end

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

# Compute and send the weekly highscoring report and the daily summary
def send_report
  if $channel.nil?
    err("Not connected to a channel, not sending highscoring report")
    return false
  end

  base  = Time.new(2020, 9, 3, 0, 0, 0, "+00:00").to_i # when archiving begun
  time  = [Time.now.to_i - REPORT_UPDATE_SIZE,  base].max
  time2 = [Time.now.to_i - SUMMARY_UPDATE_SIZE, base].max
  now   = Time.now.to_i
  pad   = [2, DEFAULT_PADDING, 6, 6, 6, 5, 4]
  log   = [] if LOG_REPORT

  changes = Archive.where("unix_timestamp(date) > #{time}")
                   .order('date desc')
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

  sleep(1)
  # Compute, for levels, episodes and stories, the following quantities:
  # Seconds of total score gained.
  # Seconds of total score in 19th gained.
  # Total number of changes.
  # Total number of involved players.
  # Total number of involved highscoreables.
  total = { "Level" => [0, 0, 0, 0, 0], "Episode" => [0, 0, 0, 0, 0], "Story" => [0, 0, 0, 0, 0] }
  changes = Archive.where("unix_timestamp(date) > #{time2}")
                   .order('date desc')
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
                total[h.class.to_s][0] += Archive.scores(h, now).first[1] - Archive.scores(h, time2).first[1]
                total[h.class.to_s][1] += Archive.scores(h, now).last[1] - Archive.scores(h, time2).last[1]
              }

  total = total.map{ |klass, n|
    "• There were **#{n[2]}** new scores by **#{n[3]}** players in **#{n[4]}** #{klass.downcase.pluralize}, making the boards **#{"%.3f" % [n[1].to_f / 60.0]}** seconds harder and increasing the total 0th score by **#{"%.3f" % [n[0].to_f / 60.0]}** seconds."
  }.join("\n")
  send_message($channel, content: "**Daily highscoring summary**:\n" + total)
end

# Compute and send the daily userlevel highscoring report for the newest
# 500 userlevels.
def send_userlevel_report
  if $channel.nil?
    err("Not connected to a channel, not sending userlevel report")
    return false
  end

  zeroes = Userlevel.rank(:rank, true, 0)
                    .each_with_index
                    .map{ |p, i| "#{"%02d" % i}: #{format_string(p[0].name)} - #{"%3d" % p[1]}" }
                    .join("\n")
  points = Userlevel.rank(:points, false, 0)
                    .each_with_index
                    .map{ |p, i| "#{"%02d" % i}: #{format_string(p[0].name)} - #{"%3d" % p[1]}" }
                    .join("\n")

  send_message($mapping_channel, content: "**Userlevel highscoring update [Newest #{USERLEVEL_REPORT_SIZE} maps]**")
  sleep(0.25)
  send_message($mapping_channel, content: "Userlevel 0th rankings with ties on #{Time.now.to_s}:\n#{format_block(zeroes)}")
  sleep(0.25)
  send_message($mapping_channel, content: "Userlevel point rankings on #{Time.now.to_s}:\n#{format_block(points)}")
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
def send_channel_episode_reminder(ctp = false)
  channel = ctp ? $ctp_channel : $channel
  eotw = GlobalProperty.get_current(Episode, ctp)
  return if eotw.nil?
  send_message(channel, content: "Also, remember that the current #{ctp ? 'CTP ' : ''}episode of the week is #{eotw.format_name}.")
rescue => e
  lex(e, 'Failed to send eotw reminder')
end

def send_channel_story_reminder(ctp = false)
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
  # Check if the channel is available
  channel = ctp ? $ctp_channel : $channel
  while channel.nil?
    err("#{ctp ? 'CTP h' : 'H'}ighscoring channel not found, not sending level of the day")
    sleep(WAIT)
    channel = ctp ? $ctp_channel : $channel
  end

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

# Driver for the function above (takes care of timing, db update, etc)
def start_level_of_the_day(ctp = false)
  while true
    sleep(WAIT)
    acquire_connection
    episode_day = false
    story_day = false

    # Test lotd/eotw/cotm immediately
    if TEST
      if (ctp ? TEST_CTP_LOTD : TEST_LOTD)
        send_channel_next(Level, ctp)
        send_channel_next(Episode, ctp)
        send_channel_next(Story, ctp)
        send_channel_episode_reminder(ctp)
        send_channel_story_reminder(ctp)
      end
      return
    end

    # Update lotd update time (every day)
    next_level_update = correct_time(GlobalProperty.get_next_update(Level, ctp), LEVEL_UPDATE_FREQUENCY)
    GlobalProperty.set_next_update(Level, next_level_update, ctp)

    # Update eotw update time (every week)
    next_episode_update = correct_time(GlobalProperty.get_next_update(Episode, ctp), EPISODE_UPDATE_FREQUENCY)
    GlobalProperty.set_next_update(Episode, next_episode_update, ctp)

    # Update cotm update time (1st of each month)
    # TODO: Compare against current month
    next_story_update = GlobalProperty.get_next_update(Story, ctp)
    next_story_update_new = next_story_update
    month = next_story_update_new.month
    next_story_update_new += LEVEL_UPDATE_FREQUENCY while next_story_update_new.month == month
    GlobalProperty.set_next_update(Story, next_story_update_new, ctp)

    # Wait until post time
    delay = next_level_update - Time.now
    sleep(delay) unless delay < 0

    # Start and post whatever is enabled
    start_task(:lotd, "Starting #{ctp ? 'CTP ' : ''}level of the day")
    level_cond   = ((ctp ? UPDATE_CTP_LEVEL   : UPDATE_LEVEL)   || DO_EVERYTHING) && !DO_NOTHING
    episode_cond = ((ctp ? UPDATE_CTP_EPISODE : UPDATE_EPISODE) || DO_EVERYTHING) && !DO_NOTHING
    story_cond   = ((ctp ? UPDATE_CTP_STORY   : UPDATE_STORY)   || DO_EVERYTHING) && !DO_NOTHING

    # Post lotd, if enabled
    if level_cond
      send_channel_next(Level, ctp)
      succ("Sent #{ctp ? 'CTP ' : ''}level of the day")
    end

    # Post eotw, if enabled
    if episode_cond && next_episode_update < Time.now
      sleep(0.25)
      send_channel_next(Episode, ctp)
      succ("Sent #{ctp ? 'CTP ' : ''}episode of the week")
      episode_day = true
    end

    # Post cotm, if enabled
    if story_cond && next_story_update < Time.now
      sleep(0.25)
      send_channel_next(Story, ctp)
      succ("Sent #{ctp ? 'CTP ' : ''}story of the month")
      story_day = true
    end

    # Post reminders
    if !episode_day && level_cond
      sleep(0.25)
      send_channel_episode_reminder(ctp)
    end

    if !story_day && level_cond
      sleep(0.25)
      send_channel_story_reminder(ctp)
    end

    end_task(:lotd)
  end
rescue => e
  lex(e, "Updating level of the day")
  end_task(:lotd)
  retry
ensure
  end_task(:lotd)
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
      restart("Lack of memory (#{str})")
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

Scheduler.add("Update status",  freq: STATUS_UPDATE_FREQUENCY) { update_status }
Scheduler.add("Update Twitch",  freq: TWITCH_UPDATE_FREQUENCY) { update_twitch }
Scheduler.add("Download demos", freq: DEMO_UPDATE_FREQUENCY, time: 'demo') { download_demos }
Scheduler.add("Highscoring report", freq: TEST && TEST_REPORT ? -1 : REPORT_UPDATE_FREQUENCY, time: TEST && TEST_REPORT ? nil : 'report') { send_report }
Scheduler.add("Userlevel report", freq: USERLEVEL_REPORT_FREQUENCY, time: 'userlevel_report') { send_userlevel_report }
Scheduler.add("Download scores", freq: HIGHSCORE_UPDATE_FREQUENCY, time: 'score') { download_high_scores }
Scheduler.add("Userlevel histories", freq: USERLEVEL_HISTORY_FREQUENCY, time: 'userlevel_history') { update_userlevel_histories }
Scheduler.add("Userlevel scores", freq: USERLEVEL_SCORE_FREQUENCY, time: 'userlevel_score') { download_userlevel_scores }
Scheduler.add("Userlevel chunk", force: false, log: false) { update_all_userlevels_chunk }
Scheduler.add("Userlevel tabs", freq: USERLEVEL_TAB_FREQUENCY, time: 'userlevel_tab') { update_userlevel_tabs }
Scheduler.add("Monitor memory", freq: MEMORY_DELAY, db: false, force: false, log: false) { monitor_memory }

# Start all the tasks in this file in independent threads.
# We separate them in 3 categories:
# - Main threads: These are completely autonomous threads that don't depend
#   on any other service being up, such as starting the CLE server or monitoring
#   memory. They're the first ones to be started.
# - Metanet threads: These are the ones that perform periodic operations querying
#   Metanet's database (e.g. to fetch scores or new userlevels). They depend on
#   their server being up, but we always start them up.
# - Discord threads: These are the ones that perform Discord-related tasks,
#   such as posting lotd or the highscoring report. They require a connection
#   to Discord, which means that they otherwise fail. We start these last, and
#   only on the condition that the connection has been established.

def start_main_threads
  $threads << Thread.new { monitor_memory                } if $linux
  $threads << Thread.new { Server::on                    } if SOCKET && !DO_NOTHING
end

def start_metanet_threads
  $threads << Thread.new { start_high_scores             } if (UPDATE_SCORES     || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { start_demos                   } if (UPDATE_DEMOS      || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { start_userlevel_scores        } if (UPDATE_USERLEVELS || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { update_all_userlevels         } if (UPDATE_USER_GLOB  || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { start_userlevel_histories     } if (UPDATE_USER_HIST  || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { start_userlevel_tabs          } if (UPDATE_USER_TABS  || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
end

def start_discord_threads
  $threads << Thread.new { update_status                 } if (UPDATE_STATUS     || DO_EVERYTHING) && !DO_NOTHING
  $threads << Thread.new { update_twitch                 } if (UPDATE_TWITCH     || DO_EVERYTHING) && !DO_NOTHING
  $threads << Thread.new { start_level_of_the_day(true)  } # No checks here because they're done individually there
  $threads << Thread.new { start_level_of_the_day(false) } # No checks here because they're done individually there
  $threads << Thread.new { start_report                  } if (REPORT_METANET    || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { start_userlevel_report        } if (REPORT_USERLEVELS || DO_EVERYTHING) && !DO_NOTHING && !OFFLINE_MODE
  $threads << Thread.new { potato                        } if POTATO && !DO_NOTHING
end
