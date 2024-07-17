# This file contains all the functions that get executed in the background,
# usually in separate threads, because they perform periodic tasks like
# updating the database scores, publishing the lotd, etc.
#
# See the TASK VARIABLES in src/constants.rb for configuration. See the end
# of the file for the thread list and joining thread.

require_relative 'constants.rb'
require_relative 'utils.rb'
require_relative 'models.rb'

# Wrapper to start each periodic task.
# - id:    Symbol to identify task
# - desc:  Text to log (nil to not log)
# - db:    Acquire a db connection
# - block: Whether the execution of this task should prevent restarts
def start_task(id, desc = nil, db: true, block: true)
  log("TASK: #{desc}") if desc
  acquire_connection if db
  $active_tasks[id] = true if block
end

# Wrapper to end each periodic task.
def end_task(id, desc = nil, db: true)
  release_connection if db
  $active_tasks[id] = false
  succ("TASK: #{desc}") if desc
end

# Periodically (every ~5 mins) perform several useful tasks.
def update_status
  while(true)
    sleep(WAIT)
    start_task(:status)

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
    end_task(:status)
    sleep(STATUS_UPDATE_FREQUENCY)
  end
rescue => e
  lex(e, "Updating status")
  end_task(:status)
  retry
ensure
  end_task(:status)
end

# Check for new Twitch streams, and send notices.
def update_twitch
  # Ensure we have a valid Twitch token
  if $twitch_token.nil?
    sleep(WAIT)
    acquire_connection
    $twitch_token = Twitch::get_twitch_token
    Twitch::update_twitch_streams
    release_connection
  end

  while(true)
    sleep(WAIT)
    start_task(:twitch)
    Twitch::update_twitch_streams
    Twitch::new_streams.each{ |game, list|
      list.each{ |stream|
        Twitch::post_stream(stream)
      }
    }
    end_task(:twitch)
    sleep(TWITCH_UPDATE_FREQUENCY)
  end
rescue => e
  lex(e, "Updating twitch")
  end_task(:twitch)
  retry
ensure
  end_task(:twitch)
end

# Update missing demos (e.g., if they failed to download originally)
def download_demos
  start_task(:demos, "Downloading missing demos")
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
  return true
rescue => e
  lex(e, "Downloading missing demos")
  return false
ensure
  end_task(:demos, "Downloaded missing demos")
end

# Driver for the function above
def start_demos
  while true
    sleep(WAIT) # prevent crazy loops
    next_demo_update = correct_time(GlobalProperty.get_next_update('demo'), DEMO_UPDATE_FREQUENCY)
    GlobalProperty.set_next_update('demo', next_demo_update)
    delay = next_demo_update - Time.now
    sleep(delay) unless delay < 0
    next if !download_demos
  end
rescue => e
  lex(e, "Updating missing demos")
  retry
end

# Compute and send the weekly highscoring report and the daily summary
def send_report
  start_task(:report, "Sending highscoring report")
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

  return true
ensure
  end_task(:report, "Highscoring report sent")
end

# Driver for the function above
def start_report
  begin
    if TEST && TEST_REPORT
      raise if !send_report
    else
      while true
        sleep(WAIT)
        next_report_update = correct_time(GlobalProperty.get_next_update('report'), REPORT_UPDATE_FREQUENCY)
        GlobalProperty.set_next_update('report', next_report_update)
        delay = next_report_update - Time.now
        sleep(delay) unless delay < 0
        next if !send_report
      end
    end
  rescue => e
    lex(e, "Sending highscoring report")
    sleep(WAIT)
    retry
  end
end

# Compute and send the daily userlevel highscoring report for the newest
# 500 userlevels.
def send_userlevel_report
  start_task(:userlevel_report, "Sending userlevel highscoring report")
  if $channel.nil?
    err("Not connected to a channel, not sending highscoring report")
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

  return true
ensure
  end_task(:userlevel_report, "Userlevel highscoring report sent")
end

# Driver for the function above
def start_userlevel_report
  begin
    while true
      sleep(WAIT)
      next_userlevel_report_update = correct_time(GlobalProperty.get_next_update('userlevel_report'), USERLEVEL_REPORT_FREQUENCY)
      GlobalProperty.set_next_update('userlevel_report', next_userlevel_report_update)
      delay = next_userlevel_report_update - Time.now
      sleep(delay) unless delay < 0
      next if !send_userlevel_report
    end
  rescue => e
    lex(e, "Sending userlevel highscoring report")
    retry
  end
end

# Update database scores for Metanet Solo levels, episodes and stories
def download_high_scores
  start_task(:scores, "Downloading highscores")
  [Level, Episode, Story].each do |type|
    type.all.each do |o|
      attempts ||= 0
      o.update_scores
    rescue => e
      lex(e, "Downloading high scores for #{o.class.to_s.downcase} #{o.id.to_s}")
      ((attempts += 1) <= ATTEMPT_LIMIT) ? retry : next
    end
  end
  return true
rescue => e
  lex(e, "Downloading highscores")
  return false
ensure
  end_task(:scores, "Downloaded highscores")
end

# Driver for the function above
def start_high_scores
  begin
    while true
      sleep(WAIT)
      next_score_update = correct_time(GlobalProperty.get_next_update('score'), HIGHSCORE_UPDATE_FREQUENCY)
      GlobalProperty.set_next_update('score', next_score_update)
      delay = next_score_update - Time.now
      sleep(delay) unless delay < 0
      next if !download_high_scores
    end
  rescue => e
    lex(e, "Updating highscores")
    retry
  end
end

# Compute and store a bunch of different rankings daily, so that we can build
# histories later.
#
# NOTE: Histories this way, stored in bulk in the database, are deprecated.
# We now using a differential table with all new scores, called 'archives'.
# So we can rebuild the boards at any given point in time with precision.
# Therefore, this function is not being used anymore.
def update_histories
  start_task(:histories, "Updating histories")

  now = Time.now
  [:SI, :S, :SL, :SS, :SU, :SS2].each do |tab|
    [Level, Episode, Story].each do |type|
      next if (type == Episode || type == Story) && [:SS, :SS2].include?(tab)

      [1, 5, 10, 20].each do |rank|
        [true, false].each do |ties|
          rankings = Score.rank(:rank, type, tab, ties, rank - 1, true)
          attrs    = RankHistory.compose(rankings, type, tab, rank, ties, now)
          ActiveRecord::Base.transaction do
            RankHistory.create(attrs)
          end
        end
      end

      rankings = Score.rank(:points, type, tab, false, nil, true)
      attrs    = PointsHistory.compose(rankings, type, tab, now)
      ActiveRecord::Base.transaction do
        PointsHistory.create(attrs)
      end

      rankings = Score.rank(:score, type, tab, false, nil, true)
      attrs    = TotalScoreHistory.compose(rankings, type, tab, now)
      ActiveRecord::Base.transaction do
        TotalScoreHistory.create(attrs)
      end
    end
  end
  return true
rescue => e
  lex(e, "Updating histories")
  return false
ensure
  end_task(:histories, "Updated highscore histories")
end

# Driver for the function above, which is not used anymore (see comment there)
def start_histories
  while true
    sleep(WAIT)
    next_history_update = correct_time(GlobalProperty.get_next_update('history'), HISTORY_UPDATE_FREQUENCY)
    GlobalProperty.set_next_update('history', next_history_update)
    delay = next_history_update - Time.now
    sleep(delay) unless delay < 0
    next if !update_histories
  end
rescue => e
  lex(e, "Updating histories")
  retry
end

# Precompute and store several useful userlevel rankings daily, so that we
# can check the history later. Since we don't have a differential table here,
# like for Metanet levels, this function is NOT deprecated.
def update_userlevel_histories
  start_task(:userlevel_histories, "Updating userlevel histories")
  now = Time.now
  [-1, 1, 5, 10, 20].each{ |rank|
    rankings = Userlevel.rank(rank == -1 ? :points : :rank, rank == 1 ? true : false, rank - 1, true)
    attrs    = UserlevelHistory.compose(rankings, rank, now)
    ActiveRecord::Base.transaction do
      UserlevelHistory.create(attrs)
    end
  }
  return true
rescue => e
  lex(e, "Updating userlevel histories")
  return false
ensure
  end_task(:userlevel_histories, "Updated userlevel histories")
end

# Driver for the function above
def start_userlevel_histories
  while true
    sleep(WAIT)
    next_userlevel_history_update = correct_time(GlobalProperty.get_next_update('userlevel_history'), USERLEVEL_HISTORY_FREQUENCY)
    GlobalProperty.set_next_update('userlevel_history', next_userlevel_history_update)
    delay = next_userlevel_history_update - Time.now
    sleep(delay) unless delay < 0
    next if !update_userlevel_histories
  end
rescue => e
  lex(e, "Updating userlevel histories")
  retry
end

# Download the scores for the scores for the latest 500 userlevels, for use in
# the daily userlevel highscoring rankings.
def download_userlevel_scores
  start_task(:userlevel_scores, "Downloading newest userlevel scores")
  Userlevel.where(mode: :solo).order(id: :desc).take(USERLEVEL_REPORT_SIZE).each do |u|
    attempts ||= 0
    u.update_scores
  rescue => e
    lex(e, "Downloading scores for userlevel #{u.id}")
    ((attempts += 1) <= ATTEMPT_LIMIT) ? retry : next
  end
  return true
rescue => e
  lex(e, "Downloading newest userlevel scores")
  return false
ensure
  end_task(:userlevel_scores, "Downloaded newest userlevel scores")
end

# Driver for the function above
def start_userlevel_scores
  while true
    sleep(WAIT)
    next_userlevel_score_update = correct_time(GlobalProperty.get_next_update('userlevel_score'), USERLEVEL_SCORE_FREQUENCY)
    GlobalProperty.set_next_update('userlevel_score', next_userlevel_score_update)
    delay = next_userlevel_score_update - Time.now
    sleep(delay) unless delay < 0
    next if !download_userlevel_scores
  end
rescue => e
  lex(e, "Updating newest userlevel scores")
  retry
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
  return true
rescue => e
  lex(e, "Downloading userlevel chunk scores")
  return false
end

# Driver for the function above
def update_all_userlevels
  log("Updating all userlevel scores...")
  while true
    sleep(WAIT)
    update_all_userlevels_chunk
  end
rescue => e
  lex(e, "Updating all userlevel scores")
  retry
end

# Download some userlevel tabs (best, top weekly, featured, hardest), for all
# 3 modes, to keep those lists up to date in the database
def update_userlevel_tabs
  start_task(:tabs, "Downloading userlevel tabs")
  [MODE_SOLO, MODE_COOP, MODE_RACE].each{ |m|
    USERLEVEL_TABS.select{ |k, v| v[:update] }.keys.each { |qt|
      page = 0
      page += 1 while Userlevel::update_relationships(qt, page, m)
      UserlevelTab.where(mode: m, qt: qt)
                  .where("`index` >= #{USERLEVEL_TABS[qt][:size]}")
                  .delete_all unless USERLEVEL_TABS[qt][:size] == -1
    }
  }
  return true
rescue => e
  lex(e, "Downloading userlevel tabs")
  return false
ensure
  end_task(:tabs, "Downloaded userlevel tabs")
end

# Driver for the function above
def start_userlevel_tabs
  while true
    sleep(WAIT)
    next_userlevel_tab_update = correct_time(GlobalProperty.get_next_update('userlevel_tab'), USERLEVEL_TAB_FREQUENCY)
    GlobalProperty.set_next_update('userlevel_tab', next_userlevel_tab_update)
    delay = next_userlevel_tab_update - Time.now
    sleep(delay) unless delay < 0
    next if !update_userlevel_tabs
  end
rescue => e
  lex(e, "Updating userlevel tabs")
  retry
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
  loop do
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

    sleep(MEMORY_DELAY)
  end
rescue => e
  lex(e, 'Failed to monitor memory')
  sleep(1)
  retry
end

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
  $threads << Thread.new { sleep                         } # KEEP FIRST
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

def block_threads
  log("Loaded outte")
  $threads.first.join
end

def unblock_threads
  $threads.first.run if $threads.first.alive?
  log("Shut down")
rescue
  nil
end
