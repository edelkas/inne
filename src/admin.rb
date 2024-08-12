# This file contains all of the bot's special commands. These are managerial
# commands that can only be executed by the botmaster in DM's, and perform
# sensitive tasks such as giving system info, sanitizing the database, etc.
# See the method "respond_special" at the end to understand the flow.

# Clean database (remove cheated archives, duplicates, orphaned demos, etc)
# See Archive::sanitize for more details
def sanitize_archives(event)
  assert_permissions(event)
  counts = Archive::sanitize
  if counts.empty?
    event << "Nothing to sanitize."
    return
  end
  event << "Sanitized database:"
  counts.each{ |name, msg| event << "* #{msg}" }
rescue => e
  lex(e, "Error sanitizing archives.", event: event)
end

def send_test(event)
end

def send_color_test(event)
  fg_colors = [
    nil,
    ANSI::BLACK, ANSI::RED,     ANSI::GREEN, ANSI::YELLOW,
    ANSI::BLUE,  ANSI::MAGENTA, ANSI::CYAN,  ANSI::WHITE
  ]
  bg_colors = [
    nil,
    ANSI::BLACK_BG, ANSI::RED_BG,     ANSI::GREEN_BG, ANSI::YELLOW_BG,
    ANSI::BLUE_BG,  ANSI::MAGENTA_BG, ANSI::CYAN_BG,  ANSI::WHITE_BG
  ]
  res = fg_colors.map{ |fg|
    bg_colors.map{ |bg|
      ANSI.format("TEST", bold: true, fg: fg, bg: bg)
    }.join(' ')
  }.join("\n")
  event << format_block(res)
end

def send_reaction(event)
  flags = parse_flags(event)
  react(flags[:c], flags[:m], flags[:r])
rescue => e
  lex(e, "Error sending reaction.", event: event)
end

def send_unreaction(event)
  flags = parse_flags(event)
  unreact(flags[:c], flags[:m], flags[:r])
rescue => e
  lex(e, "Error removing reaction.", event: event)
end

def send_mappack_seed(event)
  flags = parse_flags(event)
  update = flags.key?(:update)
  hard = flags.key?(:hard)
  all = flags.key?(:all)
  Mappack.seed(update: update, hard: hard, all: all)
  event << "Seeded new mappacks, there're now #{Mappack.count}."
rescue => e
  lex(e, "Error seeding new mappacks.", event: event)
end

def send_mappack_update(event)
  flags = parse_flags(event)
  mappack = parse_mappack(flags[:mappack], explicit: true, vanilla: false)
  perror("Mappack not found.") if mappack.nil?
  version = flags.key?(:version) ? flags[:version].to_i : mappack.version
  hard = flags.key?(:hard)
  name = "#{hard ? 'hard' : 'soft'} update for mappack #{mappack.code.upcase} v#{version}"
  send_message(event, content: "Performing #{name}.")
  mappack.read(v: version, hard: hard)
  event << "Finished #{name}."
rescue => e
  lex(e, "Error updating mappack.", event: event)
end

def send_mappack_patch(event)
  flags = parse_flags(event)
  if flags.key?(:all)
    wrong = MappackScore.gold_check(mappack: flags.key?(:m))
    count = wrong.count
    changed = wrong.count{ |s|
      !!MappackScore.patch_score(s[2], nil, nil, nil, silent: true)
    }
    Log.clear
    event << "Patched #{changed} / #{count} mappack scores successfully with ntrace."
  else
    id = flags[:id]
    highscoreable = parse_highscoreable(event, mappack: true) if !id
    player = parse_player(event, false, true, true, flag: :p) if !id
    score = parse_score(flags[:s]) if flags.key?(:s)
    event << MappackScore.patch_score(id, highscoreable, player, score)
  end
rescue => e
  lex(e, "Error patching mappack score.", event: event)
end

def send_mappack_ranks(event)
  flags = parse_flags(event)
  h = parse_highscoreable(event, mappack: true)
  board = parse_board(flags[:b])
  perror("Only the hs/sr ranks can be updated") if !['hs', 'sr', nil].include?(board)
  h.update_ranks('hs') if board == 'hs' || board.nil?
  h.update_ranks('sr') if board == 'sr' || board.nil?
  board = "hs & sr" if board.nil?
  event << "Updated #{board} ranks for #{h.name}"
rescue => e
  lex(e, "Error updating ranks.", event: event)
end

def send_mappack_info(event)
  flags = parse_flags(event)
  mappack = parse_mappack(flags[:mappack], explicit: true, vanilla: false)
  perror("You need to provide a mappack.") if !mappack
  channels = flags[:channels].split.map(&:strip) if flags.key?(:channels)
  mappack.set_info(name: flags[:name], author: flags[:author], date: flags[:date], channel: channels, version: flags[:version])
  flags.delete(:mappack)
  flags = flags.map{ |k, v| "#{k} to #{verbatim(v)}" unless v.nil? }.compact.to_sentence
  event << "Set mappack #{verbatim(mappack.code)} #{flags}."
rescue => e
  lex(e, "Error setting mappack's info.", event: event)
end

def send_mappack_digest(event)
  Mappack.digest
  event << "Updated the mappack digest, #{Mappack.all.count} mappacks found"
rescue => e
  lex(e, "Error updating the mappack digest.", event: event)
end

def send_ul_csv(event)
  send_file(event, Userlevel.dump_csv, 'userlevels.csv')
rescue => e
  lex(e, "Error preparing userlevel CSV.", event: event)
end

def send_mappack_completions(event)
  flags = parse_flags(event)
  mappack = parse_mappack(flags[:mappack], explicit: true, vanilla: false)
  MappackScore.update_completions(mappack: mappack)
  event << "Updated #{mappack ? mappack.code.upcase + ' ' : ''}mappack completions."
rescue => e
  lex(e, "Error updating mappack completions.", event: event)
end

def send_highscore_plot(event)
  flags = parse_flags(event)
  mappack = parse_mappack(flags[:mappack], explicit: true, vanilla: false)

  counts = MappackScore.where('id > ?', MIN_REPLAY_ID)
  counts = counts.where(mappack: mappack) if mappack
  total_counts = counts.group('date(date)').count
  dates = (total_counts.keys.first .. total_counts.keys.last).to_a
  total_counts = dates.map{ |date| total_counts[date].to_i }

  labels = dates.map{ |date|
    [1, 10, 20].include?(date.day) ? date.strftime("%b %d") : ''
  }

  create_svg(
    filename: "#{mappack ? mappack.code : 'mappack'}_highscores_by_day.svg",
    title:    "#{mappack ? mappack.code.upcase : 'Mappack'} highscores by day\n (Total: #{total_counts.sum} highscores in #{total_counts.size} days)",
    x_name:   'Date',
    y_name:   'Count',
    x_res:    1000,
    y_res:    500,
    data:     [total_counts],
    names:    ['Highscores'],
    labels:   labels,
    fmt:      '%d'
  )
  event << 'Generated highscore plot.'
rescue => e
  lex(e, "Error generating highscore plot.", event: event)
end

def send_ul_plot_day(event)
  counts = Userlevel.group('date(date)').count
  dates = (counts.keys.first .. counts.keys.last).to_a

  total_counts = dates.map{ |date| counts[date].to_i }
  dalton_counts = Userlevel.where(author_id: 234533).group('date(date)').count
  dalton_counts = dates.map{ |date| dalton_counts[date].to_i }

  labels = dates.map{ |date|
    [1, 7].include?(date.month) && date.day == 1 ? date.strftime("%b '%y") : ''
  }

  create_svg(
    filename: 'userlevels_by_day.svg',
    title:    "Userlevels by day\n (Total: #{total_counts.sum} userlevels in #{total_counts.size} days)",
    x_name:   'Date',
    y_name:   'Count',
    x_res:    3000,
    y_res:    500,
    data:     [dalton_counts, total_counts],
    names:    ['Dalton', 'Total'],
    labels:   labels,
    fmt:      '%d'
  )
end

def send_ul_plot_month(event)
  counts = Userlevel.group('year(date)', 'month(date)').count
  first_year  = counts.keys.first[0]
  last_year   = counts.keys.last[0]
  first_month = counts.keys.first[1]
  last_month  = counts.keys.last[1]

  total_counts = (first_year .. last_year).map{ |year|
    month1 = year == first_year ? first_month : 1
    month2 = year == last_year ? last_month : 12
    (month1 .. month2).map{ |month|
      counts[[year, month]].to_i
    }
  }.flatten

  dalton_counts = Userlevel.where(author_id: 234533).group('year(date)', 'month(date)').count
  dalton_counts = (first_year .. last_year).map{ |year|
    month1 = year == first_year ? first_month : 1
    month2 = year == last_year ? last_month : 12
    (month1 .. month2).map{ |month|
      dalton_counts[[year, month]].to_i
    }
  }.flatten

  labels = (first_year .. last_year).map{ |year|
    month1 = year == first_year ? first_month : 1
    month2 = year == last_year ? last_month : 12
    (month1 .. month2).map{ |month|
      case month
      when 1
        "Jan '#{year % 100}"
      when 7
        "Jul '#{year % 100}"
      else
        ''
      end
    }
  }.flatten

  create_svg(
    filename: 'userlevels_by_month.svg',
    title:    "Userlevels by month\n (Total: #{total_counts.sum} userlevels in #{total_counts.size} months)",
    x_name:   'Date',
    y_name:   'Count',
    x_res:    1920,
    y_res:    500,
    data:     [dalton_counts, total_counts],
    names:    ['Dalton', 'Total'],
    labels:   labels,
    fmt:      '%d'
  )

  #Magick::ImageList.new('userlevels_by_month.svg').write('userlevels_by_month.png')
end

def send_ul_plot(event)
  flags = parse_flags(event)
  case flags[:period]
  when 'month'
    send_ul_plot_month(event)
  else
    send_ul_plot_day(event)
  end
rescue => e
  lex(e, "Error generating userlevel plot.", event: event)
end

def send_gold_check(event)
  flags = parse_flags(event)
  id = [flags[:id].to_i, MIN_REPLAY_ID].max
  mappack = parse_mappack(flags[:mappack], explicit: true, vanilla: false)
  strict = flags.key?(:strict)
  event << "List of potentially incorrect mappack scores:"
  rows = []
  rows << ['Level', 'Player', 'ID', 'Current', 'HS', 'SR', 'Gold']
  rows << :sep
  rows.push(*MappackScore.gold_check(id: id, mappack: mappack, strict: strict))
  rows.size > 24 ? send_file(event, make_table(rows), 'gold_check.txt') : event << format_block(make_table(rows))
rescue => e
  lex(e, "Error performing gold check.", event: event)
end

def fill_gold_counts(event)
  level_count   = MappackLevel.count
  episode_count = MappackEpisode.count
  story_count   = MappackStory.count
  MappackLevel.find_each.with_index{ |l, i|
    dbg("Setting gold count for level #{i + 1} / #{level_count}...", progress: true)
    l.update(gold: l.gold)
  }
  Log.clear
  MappackEpisode.find_each.with_index{ |e, i|
    dbg("Setting gold count for episode #{i + 1} / #{episode_count}...", progress: true)
    e.update(gold: MappackLevel.where(episode: e).sum(:gold))
  }
  Log.clear
  MappackStory.find_each.with_index{ |s, i|
    dbg("Setting gold count for story #{i + 1} / #{story_count}...", progress: true)
    s.update(gold: MappackEpisode.where(story: s).sum(:gold))
  }
  Log.clear
  succ("Filled gold fields.", event: event)
rescue => e
  lex(e, "Error performing gold check.", event: event)
end

def send_log_config(event)
  flags = parse_flags(event)
  event << "Enabled logging modes: #{Log.modes.join(', ')}." if flags.empty?
  flags.each{ |f, v|
    str = ''
    case f
    when :l
      str = Log.level(v.to_sym) if !v.nil?
    when :f
      str = Log.fancy
    when :m
      str = Log.change_modes(v.split.map(&:to_sym)) if !v.nil?
    when :M
      str = Log.set_modes(v.split.map(&:to_sym)) if !v.nil?
    end
    event << str if !str.empty?
  }
rescue => e
  lex(e, "Error changing the log config.", event: event)
end

# Print outte and overall memory usage
def send_meminfo(event)
  if !$linux
    event << "Sorry, this function requires a Linux system"
    return
  end

  mem = getmem
  total = meminfo['MemTotal']
  available = meminfo['MemAvailable']
  used = total - available

  str =  "system: #{"%5d MB" % available} of #{"%5d MB" % total} (#{"%5.2f%%" % [100 * available / total]}) available\n"
  str << "outte:  #{"%5d MB" % mem} of #{"%5d MB" % used} (#{"%5.2f%%" % [100 * mem / used]}) used"
  send_message(
    event,
    content: "Memory usage:\n#{format_block(str)}",
    components: refresh_button('send_meminfo')
  )
rescue => e
  lex(e, "Error getting memory info.", event: event)
end

# Restart outte's process
def send_restart(event)
  flags = parse_flags(remove_command(parse_message(event)))
  force = flags.key?(:force)
  restart("Manual#{force ? ' (forced)' : ''}", force: force)
rescue => e
  lex(e, "Error restarting outte.", event: event)
end

# Shut down outte's process
def send_shutdown(event, force = false)
  flags = parse_flags(remove_command(parse_message(event)))
  force ||= flags.key?(:force)
  warn("#{force ? 'Killing' : 'Shutting down'} outte.", discord: true)
  shutdown(trap: false, force: force)
  exit
rescue => e
  lex(e, "Error shutting down outte.", event: event)
end

# Compare Ruby and C SHA1 hashes for a specific level or score
def send_hash(event)
  flags = parse_flags(event)

  # Parse highscoreable
  h = parse_highscoreable(event, mappack: true)
  perror("Map no found.") if h.nil?
  map_data = h.map.dump_level(hash: true)
  perror("Map data for #{h.format_name} is null.") if map_data.nil?

  # Parse player, if provided
  if flags[:p]
    player = parse_player(event, false, true, flag: :p)
    perror("Player #{flags[:p]} not found.") if !player
    score = h.leaderboard.find{ |s| s['name'] == player.name }
    perror("No score by #{player.name} in #{h.name}.") if !score
    eq = MappackScore.find(score['id']).compare_hashes rescue nil
    event << "The hashes are #{eq ? 'equal' : 'different'}."
    return
  end

  # Parse score ID, if provided
  if flags[:id]
    score = MappackScore.find(flags[:id]) rescue nil
    perror("Mappack score with ID #{flags[:id]} not found.") if !score
    eq = score.compare_hashes
    event << "The hashes are #{eq ? 'equal' : 'different'}."
    return
  end

  # Compare hashes for all scores, or only for the map data
  if flags.key?(:all)
    eq = h.scores.map{ |s| s.compare_hashes }.count(false) == 0
  else
    eq = h.compare_hashes
  end

  event << "The hashes are #{eq ? 'equal' : 'different'}."
rescue => e
  lex(e, "Error comparing hashes.", event: event)
end

# Compare Ruby and C SHA1 hashes for all mappack levels and return list of differences
def send_hashes(event)
  levels = MappackLevel.where('mappack_id > 0')
  count = levels.count
  res = levels.each_with_index.select{ |l, i|
    dbg("Hashing level #{i} / #{count}...", newline: false, pad: true)
    !l.compare_hashes
  }.map{ |map, i| map.name }
  event << "There are #{res.size} levels with differing hashes:"
  res.size <= 20 ? event << format_block(res.join("\n")) : send_file(event, res.join("\n"))
rescue => e
  lex(e, "Error getting hash discrepancies.", event: event)
end

def send_nprofile_gen(event)
  flags = parse_flags(event)
  perror("You need to provide a player.") if !flags.key?(:p)
  perror("You need to provide a mappack.") if !flags.key?(:m)
  player = parse_player(event, false, true, flag: :p)
  perror("Player not found.") if player.nil?
  mappack = parse_mappack(flags[:m], explicit: true, vanilla: false)
  perror("You need to provide a mappack.") if !mappack
  perror("Can't generate an nprofile for Metanet.") if mappack.id == 0
  mid = mappack.id
  nprofile = unzip(File.binread(File.join(DIR_UTILS, 'nprofile.zip')))['nprofile']
  size = nprofile.size
  # TODO: Add gold to episodes
  MappackScore.where(player: player, mappack: mappack)
              .order(highscoreable_id: :asc, gold: :asc)
              .pluck(:highscoreable_id, :highscoreable_type, :score_hs, :gold)
              .each{ |id, type, score, gold|
                type = type.remove('Mappack')
                case type
                when 'Level'
                  offset = 0x80D320
                when 'Episode'
                  offset = 0x8F7920
                when 'Story'
                  offset = 0x926720
                end
                id = id - TYPES[type][:slots] * mid
                o = offset + 48 * id
                nprofile[o + 20] = "\x02".b
                nprofile[o + 48 + 20] = "\x01".b
                old_gold = nprofile[o + 24...o + 28].unpack('l<')[0]
                nprofile[o + 24...o + 28] = [gold].pack('l<') if gold > old_gold
                score = (1000.0 * score.to_i / 60.0).round
                old_score = nprofile[o + 36...o + 40].unpack('l<')[0]
                nprofile[o + 36...o + 40] = [score].pack('l<') if score > old_score
              }
  perror("Size mismatch after nprofile patch") if nprofile.size != size
  File.binwrite(
    "#{sanitize_filename(player.name)}_nprofile.zip",
    zip({ 'nprofile' => nprofile })
  )
  event << "#{mappack.code.upcase} nprofile for #{player.name} was generated"
rescue => e
  lex(e, "Error generating nprofile.", event: event)
end

# Remove duplicate and obsolete users, fill in Discord ID field
def sanitize_users(event)
  # Remove obsolete users, i.e., those whose name doesn't exist in the server
  # These users are now unreachable, as a consequence of outte using usernames
  # rather than Discord IDs for a long time (now changed)
  users = User.all.map{ |u| [u, find_users(name: u.name)] }
  users.select{ |u| u.last.empty? }.each{ |u| u.first.delete }
  users.reject!{ |u| u.last.empty? }

  # Fill in Discord ID field for all the remaining users, unless there are
  # multiple matches, in which case we will do it manually later
  users.each{ |u|
    u.first.update(discord_id: u.last.first.id, name: u.last.first.name) if u.last.size == 1
  }

  # Remove duplicate users, while keeping the relevant info
  names = User.group(:name).having('count(name) > 1').pluck(:name)
  names.each{ |n|
    player_id = User.where(name: n).where.not(player_id: nil).order(id: :desc).first.player_id rescue nil
    palette = User.where(name: n).where.not(palette: nil).order(id: :desc).first.palette rescue nil

    copies = User.where(name: n).order(id: :desc).to_a
    copies[0].update(player_id: player_id, palette: palette)
    copies[1..-1].each(&:delete)
  }

  event << "Sanitized users"
rescue => e
  lex(e, "Error sanitizing users.", event: event)
end

# Remove bad hashes missing their corresponding mappack score
def sanitize_hashes(event)
  count = BadHash.sanitize
  event << "Sanitized bad hashes, removed #{count} orphans."
rescue => e
  lex(e, "Error sanitizing bad hashes.", event: event)
end

# Remove mappack demos missing their corresponding score
def sanitize_demos(event)
  count = MappackDemo.sanitize
  event << "Sanitized mappack demos, removed #{count} orphans."
rescue => e
  lex(e, "Error sanitizing mappack demos.", event: event)
end

# Update all SHA1 hashes for every mappack highscoreable (all versions too)
def seed_hashes(event)
  flags = parse_flags(event)
  mappack = parse_mappack(flags[:mappack], explicit: true, vanilla: false)
  types = parse_type(flags[:type].to_s, multiple: true)
  types = [Level, Episode, Story] if types.empty?
  send_message(event, content: 'Seeding mappack SHA1 hashes.')
  count = MappackHash.seed(mappack: mappack, types: types)
  event << "Seeded mappack hashes, updated #{count} hashes."
rescue => e
  lex(e, "Error seeding mappack hashes.", event: event)
end

# Manually update the Discord ID of a user by name
def set_user_id(event)
  flags = parse_flags(event)
  perror("You must provide a username.") if !flags[:name]
  name = flags[:name].split('#').first
  user = User.where(name: name)
  perror("No user found by the name #{verbatim(name)}.") if user.empty?
  perror("Multiple users found by the name #{verbatim(name)}.") if user.size > 1
  user = user.first
  discord_user = parse_discord_user("for #{flags[:name]}")
  old_id = user.discord_id
  new_id = discord_user.id
  perror("#{user.name}'s Discord ID is already #{old_id}.") if old_id == new_id
  user.update(discord_id: new_id)
  if old_id
    event << "Changed #{user.name}'s Discord ID from #{old_id} to #{new_id}."
  else
    event << "Set #{user.name}'s Discord ID to #{new_id}."
  end
rescue => e
  lex(e, "Error setting user ID.", event: event)
end

# Manually set the ID of the replay that will be sent by CLE to the botmaster
# in the next get_replay queries
def set_replay_id(event)
  msg = remove_command(parse_message(event))
  if msg =~ /\d+/
    id = msg[/\d+/].to_i
    score = MappackScore.find_by(id: id)
    perror("Mappack score with ID #{id} not found.") if !score
    GlobalProperty.find_by(key: 'replay_id').update(value: id)
    event << "Set manual replay ID to #{msg[/\d+/]} (#{score.player.name} - #{score.highscoreable.name})."
  else
    GlobalProperty.find_by(key: 'replay_id').update(value: nil)
    event << "Unset manual replay ID."
  end
rescue => e
  lex(e, "Error changing manual replay ID.", event: event)
end

def submit_score(event)
  flags = parse_flags(event)

  if !flags.key?(:all)
    # Submit a score to an individual highscoreable
    # TODO: Extend with flags for score/player/...
    perror("You must provide a downloadable.") if !flags[:h]
    if is_num(flags[:h])
      h = Userlevel.find_by(id: flags[:h].to_i)
      perror("No userlevel with ID #{flags[:h]}.") if !h
    else
      h = parse_highscoreable(event)
    end
    res = h.submit_zero_score(log: true)
    if res
      perror("Failed to submit zero score to #{verbatim(h.name)} (incorrect hash?)") if res['rank'].to_i < 0
      if res['better'] == 0
        str = "Already had a better score in #{verbatim(h.name)}: "
      else
        str = "Submitted zero score to #{verbatim(h.name)}: "
      end
      score = '%.3f' % round_score(res['score'].to_i / 1000.0)
      str << "replay ID #{res['replay_id']}, rank: #{res['rank']}, score: #{score}."
      succ(str, event: event)
    end
  else
    msgs = [nil]
    if !flags.key?(:userlevels)
      [Level, Episode, Story].each{ |type|
        Downloadable.submit_zero_scores(type.where(completions: nil), event: event, msgs: msgs)
      }
    else
      Downloadable.submit_zero_scores(
        Userlevel.where('submitted = 0 AND completions >= 18'),
        event: event,
        msgs: msgs
      )
    end
    concurrent_edit(event, msgs, "Finished submitting all remaining zero scores.")
  end
rescue => e
  lex(e, 'Failed to submit score.', event: event)
end

# Update how many completions a Metanet highscoreable / userlevel (or all) has
def update_completions(event)
  flags = parse_flags(event)
  global = flags.key?(:global)
  mine = flags.key?(:mine)
  global = global ? true : mine ? false : nil

  if !flags.key?(:all)
    # Update completion count for individual highscoreable
    perror("You must provide a downloadable.") if !flags[:h]
    if is_num(flags[:h])
      h = Userlevel.find_by(id: flags[:h].to_i)
      perror("No userlevel with ID #{flags[:h]}.") if !h
    else
      h = parse_highscoreable(event)
      perror("This highscoreable is not downloadable.") if !h.is_a?(Downloadable)
    end
    count_old = h.completions.to_i
    count_new = h.update_completions(log: true, discord: true, retries: 0, stop: true, global: global)
    name = h.is_a?(Userlevel) ? "userlevel #{h.id}" : h.name
    if count_new
      count_new = count_new.to_i
      diff = count_new - count_old
      event << "Updated #{name} completions from #{count_old} to #{count_new} (+#{diff})."
    else
      event << "Failed to fetch completions for #{name}."
    end
  else
    # Update completion count for all highscoreables
    # TODO: Make Discord logging optional, for when we manage to automate Steam
    # authentification, leading to automating this function in the background
    delta = 0
    retries = flags[:retries].to_i
    msgs = [nil]
    if !flags.key?(:userlevels)
      type = parse_type(flags[:type].to_s)
      tabs = parse_tabs(flags[:tabs].to_s)
      (type ? [type] : [Level, Episode, Story]).each{ |t|
        delta += Downloadable.update_completions(
          !tabs.empty? ? t.where(tab: tabs) : t,
          event: event, msgs: msgs, retries: retries, global: global
        )
      }
    else
      delta += Downloadable.update_completions(
        Userlevel.where('submitted = 1 OR completions >= 20'),
        event: event, msgs: msgs, retries: retries, global: global
      )
    end
    concurrent_edit(event, msgs, "Finished updating completions, gained #{delta} ones.")
  end
rescue => e
  lex(e, 'Failed to update completions.', event: event)
end

def userlevel_completions(event)
  flags = parse_flags(event)
  UserlevelScore.seed_completions(flags.key?(:full))
  succ("Seeded userlevel completions.", event: event)
rescue => e
  lex(e, 'Failed to seed userlevel completions.', event: event)
end

# Manually delete a score from the database
def send_delete_score(event)
  msg = remove_command(parse_message(event))
  flags = parse_flags(msg)

  # Fetch a score, either by ID, or by (player, highscoreable, board)
  if flags.key?(:p) || flags.key?(:h) || flags.key?(:b)
    perror("You need to specify a player.") if !flags[:p]
    perror("You need to specify a highscoreable.") if !flags[:h]
    perror("You need to specify a board.") if !flags[:b]
    p = parse_player(event, false, true, true, flag: :p)
    h = parse_highscoreable(event, mappack: true, map: true)
    perror("Metanet scores cannot be deleted.") if h.mappack.code.downcase == 'met'
    board = parse_board(flags[:b])
    perror("The board needs to be hs/sr.") if !['hs', 'sr'].include?(board)
    score = MappackScore.where(player: p, highscoreable: h)
                        .where("rank_#{board} IS NOT NULL")
                        .first
    perror("#{p.name} doesn't have a score in #{h.name}.") if !score
    id = score.id
  else
    id = msg[/\d+/]
    perror("You need to specify a score ID") if !id
    score = MappackScore.find_by(id: id.to_i)
    perror("Score with ID #{id} not found.") if !score
    h = score.highscoreable
    p = score.player
  end

  # Send confirmation message with Yes/No buttons
  # Response will be handled in delete_score@interactions, and buttons will be removed
  send_message(
    event,
    content:    "Delete #{p.name}'s score (ID #{id}) in #{h.name}?",
    components: interaction_add_confirmation_buttons
  )
rescue => e
  lex(e, 'Failed to delete mappack score.', event: event)
end

# Deletes an outte message if it was sent by the reacting user recently
# The botmaster can delete any message any time
def delete_message(event)
  msg = event.message
  return msg.delete if event.user.id == BOTMASTER_ID
  return if Time.now - msg.timestamp > DELETE_TIMELIMIT
  return if !Message.find_by(id: msg.id, user_id: event.user.id)
  msg.delete
rescue => e
  lex(e, 'Failed to delete outte message.', event: event)
end

# Tests ntrace on many runs (e.g. all Metanet 0ths)
def test_ntrace(event)
  # Parse params
  flags = parse_flags(event)
  tabs  = parse_tabs(flags[:tabs].to_s)
  if flags.key?(:mappack)
    if flags[:mappack]
      klass = MappackLevel.where(mappack: parse_mappack(flags[:mappack]))
    else
      klass = MappackLevel.where('mappack_id > 0')
    end
  else
    klass = Level.all
  end
  klass = klass.where(mode: 0) if flags.key?(:solo)
  klass = klass.where(tab: tabs) if !tabs.empty?
  klass = klass.select{ |l| l.tiles.flatten.none?{ |t| t > 33 } } if flags.key?(:glitchless)
  klass = klass.select{ |l| l.tiles.flatten.any?{ |t| t > 33 } } if flags.key?(:glitchful)
  count = klass.count

  # Execute test
  results = klass.each_with_index.map{ |l, i|
    dbg("Testing ntrace on level #{i + 1} / #{count}...", progress: true)
    [l.name, l.map.test_ntrace]
  }.to_h
  Log.clear
  log("Finished testing ntrace")
  good  = results.select{ |k, v| v == :good  }.to_h
  bad   = results.select{ |k, v| v == :bad   }.to_h
  error = results.select{ |k, v| v == :error }.to_h
  other = results.select{ |k, v| v == :other }.to_h

  # Format results
  event << "Results from ntrace test:"
  block = ""
  block << "Mappack:  #{mappack.code.upcase rescue 'MET'}\n"
  block << "Tabs:     #{tabs.empty? ? 'All' : format_tabs(tabs)}\n"
  block << "-------------\n"
  block << "Good:    #{'%4d' % good.size}\n"
  block << "Bad:     #{'%4d' % bad.size}\n"
  block << "Error:   #{'%4d' % error.size}\n"
  block << "Other:   #{'%4d' % other.size}\n"
  block << "-------------\n"
  block << "Total:   #{'%4d' % results.size}"
  event << format_block(block)
  file = ""
  file << "GOOD: #{good.size}\n\n" if flags.key?(:good)
  file << good.keys.join("\n") + "\n\n" if flags.key?(:good)
  file << "BAD: #{bad.size}\n\n"
  file << bad.keys.join("\n") + "\n\n"
  file << "ERROR: #{error.size}\n\n"
  file << error.keys.join("\n") + "\n\n"
  file << "OTHER: #{other.size}\n\n"
  file << other.keys.join("\n")
  send_file(event, file, "ntrace-test.txt", false)
rescue => e
  lex(e, 'Failed to test ntrace')
end

# Update a userlevel author's name and add a new A.K.A.
def rename_author(event)
  flags = parse_flags(event)
  id = flags[:id]
  name = flags[:name]
  perror("Usage: !rename_author -id ID -name NAME") unless !!id && !!name
  author = UserlevelAuthor.find_by(id: id.to_i)
  perror("No userlevel author with ID #{id}.") unless author
  author.rename(name)
  event << "Renamed author #{id} to #{verbatim(name)}."
rescue => e
  lex(e, 'Failed to rename author.')
end

# Fetch and print current relevant MySQL variables and status
def send_sql_status(event)
  update_sql_status

  # Connections established to MySQL database
  str  = "Connections: "
  str << "#{$sql_status['Threads_connected']} open, "
  str << "#{$sql_status['Max_used_connections']} highest, "
  str << "#{$sql_vars['max_connections']} max, "
  str << "#{$sql_status['Connections']} total\n"

  # MySQL threads alive
  str << "Threads:     "
  str << ['connected', 'running', 'cached', 'created'].map{ |t|
    "#{$sql_status["Threads_#{t}"]} #{t}"
  }.join(", ") + "\n"

  # Rails connection pool info
  str << "Rails pool:  "
  str << ActiveRecord::Base.connection_pool.stat.map{ |p|
    next nil if p[1].is_a?(Float)
    p.map(&:to_s).join(' ')
  }.compact.join(', ')

  # Send
  send_message(
    event,
    content: "Database status #{format_time}:\n" + format_block(str),
    components: refresh_button('send_sql_status')
  )
rescue => e
  lex(e, 'Failed to send database status.', event: event)
end

# Print detailed list of all current open connections to the MySQL server
def send_sql_list(event)
  update_sql_status
  if !$sql_conns.size == 0
    event << "There are no open MySQL connections."
    return
  end
  flags = parse_flags(event)
  last = flags.key?(:full) ? -1 : -3
  rows = []
  rows << $sql_conns.first.keys[0..last]
  rows << :sep
  $sql_conns.each{ |row| rows << row.values[0..last] }
  send_message(
    event,
    content: format_block(make_table(rows)) + "Total: #{$sql_conns.size}",
    components: refresh_button('send_sql_list')
  )
rescue => e
  lex(e, 'Failed to send database thread list.', event: event)
end

# Print information about all the running background tasks
def send_tasks(event)
  rows = []
  rows << ["Name", "State", "Runs", "Last run", "Next run"]
  rows << :sep
  totals = {}
  Scheduler.list.sort_by{ |job|
    [
      Job.states[job.state][:order],
      job.eta ? 0 : 1,
      job.eta,
      job.time ? 0 : 1,
      job.time,
      -job.count,
      job.task.name
    ]
  }.each{ |job|
    rows << [
      job.task.name,
      Job.states[job.state][:desc].capitalize,
      job.count,
      (job.time.strftime('%b %d %R') rescue ''),
      format_timespan(job.eta)
    ]
    totals.key?(job.state) ? totals[job.state] += 1 : totals[job.state] = 1
  }
  send_message(
    event,
    content: "Tasks scheduled:\n" + format_block(make_table(rows)) + "Total: #{totals.map{ |k, v| "#{v} #{k}" }.join(', ')}",
    components: refresh_button('send_tasks')
  )
rescue => e
  lex(e, 'Failed to send background task list.', event: event)
end

def send_debug(event)
  flags = parse_flags(event)
  if flags.key?(:byebug) then byebug else binding.pry end
rescue => e
  lex(e, 'Failed to start debugger.', event: event)
end

def send_status(event)
  str  = "Uptime:   #{format_timespan(Time.now - $boot_time)} (boot #{$boot_time.strftime('%F %T')})\n"
  str << "Commands: #{$status[:commands]} normal, #{$status[:special_commands]} special, #{$status[:main_commands]} on main thread\n"
  str << "Received: #{$status[:pings]} mentions, #{$status[:dms]} DMs, #{$status[:interactions]} interactions\n"
  str << "Sent:     #{$status[:messages]} messages, #{$status[:edits]} edits\n"
  str << "Logged:   #{$status[:logs]} lines, #{$status[:errors]} errors, #{$status[:warnings]} warnings, #{$status[:exceptions]} exceptions\n"
  str << "Network:  #{$status[:http_requests]} requests, #{$status[:http_errors]} errors, #{$status[:http_forwards]} forwards\n"
  str << "CLE:      #{$status[:http_scores]} leaderboards, #{$status[:http_replay]} replays, #{$status[:http_submit]} submissions, #{$status[:http_login]} logins, #{$status[:http_levels]} userlevel queries"
  send_message(
    event,
    content: "Status #{format_time}:\n" + format_block(str),
    components: refresh_button('send_status')
  )
rescue => e
  lex(e, 'Failed to send outte status.', event: event)
end

# TODO: only add formatting to necessary lines. we can do this by extracting the
# part that filters the lines out of the pager to a different function, and using
# it here
def send_logs(event, page: nil)
  lines = File.readlines(PATH_LOG_FILE).reverse.map{ |l|
    next nil if l.length <= 34
    l.insert(33, ANSI.esc(ANSI::NONE))
     .insert(25, ANSI.esc(ANSI::MAGENTA))
     .prepend(ANSI.esc(ANSI::YELLOW))
     .chomp
  }.compact
  pager(event, page, header: "Logs", func: 'send_logs', list: lines)
end


# Special commands can only be executed by the botmaster, and are intended to
# manage the bot on the fly without having to restart it, or to print sensitive
# information.
#
# The syntax is always the same: !commandname
# It may optionally be followed by flags, which follow classic UNIX conventions
# The syntax is more strict since that allows for more precision, and flexibility
# is no longer required as it's not aimed at the general user base.
#
# Example:
#   !react -c A -m B -r C
#   Will react to the message with id B in channel with name A with emoji C
def respond_special(event)
  assert_permissions(event)
  msg = parse_message(event).strip
  cmd = msg[/^!(\w+)/i, 1]
  return if cmd.nil?
  cmd.downcase!
  $status[:special_commands] += 1

  return send_debug(event)               if cmd == 'debug'
  return send_delete_score(event)        if cmd == 'delete_score'
  return fill_gold_counts(event)         if cmd == 'fill_gold'
  return send_gold_check(event)          if cmd == 'gold_check'
  return send_hash(event)                if cmd == 'hash'
  return send_hashes(event)              if cmd == 'hashes'
  return send_highscore_plot(event)      if cmd == 'highscores_plot'
  return send_shutdown(event, true)      if cmd == 'kill'
  return send_logs(event)                if cmd == 'log'
  return send_log_config(event)          if cmd == 'logconf'
  return send_mappack_completions(event) if cmd == 'mappack_completions'
  return send_mappack_digest(event)      if cmd == 'mappack_digest'
  return send_mappack_info(event)        if cmd == 'mappack_info'
  return send_mappack_patch(event)       if cmd == 'mappack_patch'
  return send_mappack_ranks(event)       if cmd == 'mappack_ranks'
  return send_mappack_seed(event)        if cmd == 'mappack_seed'
  return send_mappack_update(event)      if cmd == 'mappack_update'
  return send_meminfo(event)             if cmd == 'meminfo'
  return send_nprofile_gen(event)        if cmd == 'nprofile_gen'
  return send_reaction(event)            if cmd == 'react'
  return rename_author(event)            if cmd == 'rename_author'
  return send_restart(event)             if cmd == 'restart'
  return sanitize_archives(event)        if cmd == 'sanitize_archives'
  return sanitize_demos(event)           if cmd == 'sanitize_demos'
  return sanitize_hashes(event)          if cmd == 'sanitize_hashes'
  return sanitize_users(event)           if cmd == 'sanitize_users'
  return seed_hashes(event)              if cmd == 'seed_hashes'
  return set_user_id(event)              if cmd == 'set_user_id'
  return set_replay_id(event)            if cmd == 'set_replay_id'
  return send_shutdown(event)            if cmd == 'shutdown'
  return send_sql_list(event)            if cmd == 'sql_list'
  return send_sql_status(event)          if cmd == 'sql_status'
  return send_status(event)              if cmd == 'status'
  return submit_score(event)             if cmd == 'submit'
  return send_tasks(event)               if cmd == 'tasks'
  return send_test(event)                if cmd == 'test'
  return send_color_test(event)          if cmd == 'test_color'
  return test_ntrace(event)              if cmd == 'test_ntrace'
  return send_unreaction(event)          if cmd == 'unreact'
  return update_completions(event)       if cmd == 'update_completions'
  return userlevel_completions(event)    if cmd == 'userlevel_completions'
  return send_ul_csv(event)              if cmd == 'userlevel_csv'
  return send_ul_plot(event)             if cmd == 'userlevel_plot'

  $status[:special_commands] -= 1
  event << "Unsupported special command."
end