# This file handles all the direct communication of outte with the server, i.e.,
# the responses to all commands sent via Discord pings or DMs. See the "respond"
# method at the end to start to understand the flow.

require 'ascii_charts'
require 'rmagick'
require 'svggraph'
require 'zip'

# Prints COUNT of scores with specific characteristics for a player.
#   Arg 'file':    Also return list of scores in a text file.
#   Arg 'missing': Return complementary list, i.e., those NOT verifying conditions
#   Arg 'third':   Allows to parse player name using 'is'
def send_list(event, file = true, missing = false, third = false)
  # Parse message parameters
  msg     = parse_message(event)
  player  = parse_player(event, false, false, false, false, third)
  msg     = msg.remove!(player.name)
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  board   = parse_board(msg, 'hs')
  type    = parse_type(msg)
  tabs    = parse_tabs(msg)
  cool    = mappack.nil? ? parse_cool(msg) : false
  star    = mappack.nil? ? parse_star(msg) : false
  range   = parse_range(msg, cool || star || missing)
  ties    = parse_ties(msg)
  tied    = parse_tied(msg)
  sing    = (missing ? -1 : 1) * parse_singular(msg)
  high    = missing && !(sing != 0 || cool || star) # list of highscoreables, not scores
  perror("Speedrun mode isn't available for Metanet levels yet.") if board == 'sr' && !mappack

  # The range must make sense
  if !range[2]
    event << "You specified an empty range! (#{format_range(range[0], range[1])})"
    return
  end

  # Retrieve score count with specified characteristics
  if sing != 0
    list = player.singular(type, tabs, sing == 1 ? false : true)
  else
    list = player.range_ns(range[0], range[1], type, tabs, ties, tied, cool, star, missing, mappack, board)
  end

  # Format list
  if !high
    c = mappack ? 'Mappack'  : ''
    t = mappack ? 'mappack_' : ''
    join = <<~STR.gsub(/\s+/, ' ').strip
      LEFT JOIN `#{t}levels`   ON (`#{t}scores`.`highscoreable_type` = '#{c}Level'   AND `#{t}levels`.`id`   = `#{t}scores`.`highscoreable_id`)
      LEFT JOIN `#{t}episodes` ON (`#{t}scores`.`highscoreable_type` = '#{c}Episode' AND `#{t}episodes`.`id` = `#{t}scores`.`highscoreable_id`)
      LEFT JOIN `#{t}stories`  ON (`#{t}scores`.`highscoreable_type` = '#{c}Story'   AND `#{t}stories`.`id`  = `#{t}scores`.`highscoreable_id`)
    STR
    name = <<~STR.gsub(/\s+/, ' ').strip
      CASE
        WHEN `#{t}scores`.`highscoreable_type` = '#{c}Level'   THEN `#{t}levels`.`name`
        WHEN `#{t}scores`.`highscoreable_type` = '#{c}Episode' THEN `#{t}episodes`.`name`
        WHEN `#{t}scores`.`highscoreable_type` = '#{c}Story'   THEN `#{t}stories`.`name`
        ELSE ''
      END
    STR
    rank  = !mappack ? '`rank`' : "`rank_#{board}`"
    score = !mappack ? 'ROUND(`score` * 60)' : "`score_#{board}`"
    score = "REPLACE(FORMAT(#{score} / 60, 3), ',', '')" if !board || board == 'hs'
    pad_rank = 2
    pad_name = !mappack ? 10 : 14
    pad_score = !board || board == 'hs' ? 8 : 4
    fields = []
    fields << "LPAD(#{rank},  #{pad_rank},  '0')" unless board == 'gm'
    fields << "': '"                              unless board == 'gm'
    fields << "RPAD(#{name},  #{pad_name},  ' ')"
    fields << "' - '"                             unless board == 'gm'
    fields << "LPAD(#{score}, #{pad_score}, ' ')" unless board == 'gm'
    list = list.joins(join).pluck("CONCAT(#{fields.join(', ')})").uniq
  end

  # Format header
  max1     = find_max(:rank, type, tabs, false, mappack, board)
  max2     = player.range_ns(range[0], range[1], type, tabs, ties, tied).count
  full     = !missing || !(cool || star) # max is all scores, not all player's scores
  max      = full ? max1 : max2
  type     = format_type(type).downcase
  tabs     = format_tabs(tabs)
  range    = format_range(range[0], range[1], sing != 0 || board == 'gm')
  sing     = format_singular((missing ? -1 : 1) * sing)
  cool     = format_cool(cool)
  star     = format_star(star)
  ties     = format_ties(ties)
  tied     = format_tied(tied)
  boardB   = !mappack.nil? ? format_board(board) : ''
  mappackB = format_mappack(mappack)
  count    = list.count
  header = "#{player.print_name} #{missing ? 'is missing' : 'has'} "
  header << "#{count} out of #{max} #{cool} #{tied} #{boardB} #{tabs} #{type} "
  header << "#{range}#{star} #{sing} scores #{ties} #{mappackB}"
  event << format_header(header, close: '.', upcase: false)

  # Print count and possibly export list in file
  return unless file
  if count <= 20
    event << format_block(list.join("\n"))
  else
    send_file(event, list.join("\n"), "scores-#{player.sanitize_name}.txt", false)
  end
rescue => e
  lex(e, "Error performing #{file ? 'list' : 'count'}.", event: event)
end

# Return list of players sorted by a number of different ranking types
# Navigation controls are optional
# The named parameters are ALL for the navigation:
#   'page'  Controls the page of the rankings button navigation
#   'type'  Type buttons (i.e., Level, Episode, Story)
#   'tab'   Tab select menu option (All, SI, S, SU, SL, ?, !)
#   'rtype' Ranking type select menu option
#   'ties'  Ties button
# When a named parameter is not nil, then that button/select menu was pressed,
# so it takes preference, and is used instead of parsing it from the message
def send_rankings(event, page: nil, type: nil, tab: nil, rtype: nil, ties: nil)
  # PARSE ranking parameters (from function arguments and message)
  initial    = parse_initial(event)
  reset_page = !type.nil? || !tab.nil? || !rtype.nil? || !ties.nil?
  msg   = parse_message(event)
  tabs  = parse_tabs(msg, tab)
  tab   = tabs.empty? ? 'all' : (tabs.size == 1 ? tabs[0].to_s.downcase : 'tab')
  ties  = !ties.nil? ? ties : parse_ties(msg, rtype)
  play  = parse_many_players(msg)
  nav   = parse_nav(msg) || !initial
  full  = !!msg[/global/i] || parse_full(msg) || nav
  cool  = !rtype.nil? && parse_cool(rtype) || rtype.nil? && parse_cool(msg)
  star  = !rtype.nil? && parse_star(rtype, false, true) || rtype.nil? && parse_star(msg, true, true)
  maxed = !rtype.nil? && parse_maxed(rtype) || rtype.nil? && parse_maxed(msg)
  maxable = !maxed && (!rtype.nil? && parse_maxable(rtype) || rtype.nil? && parse_maxable(msg))
  rtype2 = rtype # save a copy before we change it
  rtype = rtype || parse_rtype(msg)
  whole = [
    'average_point',
    'average_rank',
    'point',
    'score',
    'cool',
    'star',
    'maxed',
    'maxable',
    'G++',
    'G--'
  ].include?(rtype) # default rank is top20, not top1 (0th)
  range = !parse_rank(rtype).nil? ? [0, parse_rank(rtype), true] : parse_range(rtype2.nil? ? msg : '', whole)
  rtype = fix_rtype(rtype, range[1])
  def_level = [
    'score',
    'G++',
    'G--'
  ].include?(rtype) # default type is Level
  type  = parse_type(msg, type: type, multiple: true, initial: initial, default: def_level ? Level : nil)
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  board = parse_board(msg, 'hs')
  board = 'hs' if !['hs', 'sr'].include?(board)

  perror("Speedrun mode isn't available for Metanet levels yet.") if board == 'sr' && !mappack
  perror("Gold rankings aren't available for Metanet levels yet.") if ['G++', 'G--'].include?(rtype) && !mappack

  # The range must make sense
  if !range[2]
    event << "You specified an empty range! (#{format_range(range[0], range[1])})"
    return
  end

  # Determine ranking type and max value of said ranking
  rtag = :rank
  case rtype
  when 'average_point'
    rtag  = :avg_points
    max   = find_max(:avg_points, type, tabs, !initial, mappack, board)
  when 'average_top1_lead'
    rtag  = :avg_lead
    max   = nil
  when 'average_rank'
    rtag  = :avg_rank
    max   = find_max(:avg_rank, type, tabs, !initial, mappack, board)
  when 'point'
    rtag  = :points
    max   = find_max(:points, type, tabs, !initial, mappack, board)
  when 'score'
    rtag  = :score
    max   = find_max(:score, type, tabs, !initial, mappack, board)
  when 'singular_top1'
    rtag  = :singular
    max   = find_max(:rank, type, tabs, !initial, mappack, board)
    range[1] = 1
  when 'plural_top1'
    rtag  = :singular
    max   = find_max(:rank, type, tabs, !initial, mappack, board)
    range[1] = 0
  when 'tied_top1'
    rtag  = :tied_rank
    max   = find_max(:rank, type, tabs, !initial, mappack, board)
  when 'maxed'
    rtag  = :maxed
    max   = find_max(:maxed, type, tabs, !initial, mappack, board)
  when 'maxable'
    rtag  = :maxable
    max   = find_max(:maxable, type, tabs, !initial, mappack, board)
  when 'G++'
    rtag  = :gp
    max   = find_max(:gp, type, tabs, !initial, mappack, board)
  when 'G--'
    rtag  = :gm
    max   = find_max(:gm, type, tabs, !initial, mappack, board)
  else
    rtag  = :rank
    max   = find_max(:rank, type, tabs, !initial, mappack, board)
  end

  # EXECUTE specific rankings
  rank = Score.rank(
    ranking: rtag,      # Ranking type.             Def: Regular scores.
    type:    type,      # Highscoreable type.       Def: Levels and episodes.
    tabs:    tabs,      # Highscoreable tabs.       Def: All tabs (SI, S, SU, SL, ?, !).
    players: play,      # Players to ignore.        Def: None.
    a:       range[0],  # Bottom rank of scores.    Def: 0th.
    b:       range[1],  # Top rank of scores.       Def: 19th.
    ties:    ties,      # Include ties or not.      Def: No.
    cool:    cool,      # Only include cool scores. Def: No.
    star:    star,      # Only include * scores.    Def: No.
    mappack: mappack,   # Mappack to do rankings.   Def: None.
    board:   board      # Highscore or speedrun.    Def: Highscore.
  )

  # PAGINATION
  pagesize = nav ? PAGE_SIZE : 20
  page = parse_page(msg, page, reset_page, event.message.components)
  pag  = compute_pages(rank.size, page, pagesize)

  # FORMAT message
  min = ''
  if ['average_rank', 'average_point'].include?(rtype)
    min_scores = min_scores(type, tabs, !initial, range[0], range[1], star, mappack)
    min = " __Min. scores__: **#{min_scores}**."
  end
  # --- Header
  no_range = [ # Don't print range for these rankings
    'tied_top1',
    'singular_top1',
    'plural_top1',
    'average_top1_lead',
    'score',
    'G++',
    'G--'
  ].include?(rtype)
  no_board = [ # Don't print board for these rankings
    'G++',
    'G--'
  ].include?(rtype)
  use_min = [ # Situations in which to display MIN rather than MAX
    rtype == 'average_rank',
    board == 'sr' && rtype == 'score',
    rtype == 'G--'
  ].any?
  fullB   = format_full(nav ? false : full)
  cool    = format_cool(cool)
  maxed   = format_maxed(maxed)
  maxable = format_maxable(maxable)
  tabs    = format_tabs(tabs)
  typeB   = format_type(type, true).downcase
  range   = no_range ? '' : format_range(range[0], range[1])
  star    = format_star(star, long: true)
  rtypeB  = format_rtype(rtype, range: false, basic: true)
  max     = max ? format_max(max, use_min, bd: false) + '. ' : ''
  board   = !mappack.nil? && !no_board ? format_board(board) : ''
  mappack = format_mappack(mappack)
  play    = !play.empty? ? ' without ' + play.map{ |p| "#{verbatim(p.print_name)}" }.to_sentence : ''
  header  = "#{fullB} #{cool} #{maxed} #{maxable} #{board} #{tabs} #{typeB} #{range} #{rtypeB} s"
  header.sub!(/\s+s$/, 's')
  header << " #{format_ties(ties)} #{mappack} #{play}"
  header  = mdtext("Rankings - #{format_header(header, close: '')}", header: 2)
  footer  = mdtext("__Date__: #{format_time(long: false, prep: false)}. #{max}#{min}", header: -1)
  #header += "\n" + footer
  # --- Rankings
  if rank.empty?
    rank  = 'These boards are empty!'
    count = 0
  else
    rank  = rank[pag[:offset]...pag[:offset] + pagesize] if !full || nav
    count = rank.size
    pad1  = rank.map{ |r| r[1].to_i.to_s.length }.max
    pad2  = rank.map{ |r| r[0].length }.max
    pad3  = rank.map{ |r| r[2].to_i.to_s.length }.max
    fmt   = rank[0][1].is_a?(Integer) ? "%#{pad1}d" : "%#{pad1 + 4}.3f"
    rank  = rank.each_with_index.map{ |r, i|
      rankf = Highscoreable.format_rank(pag[:offset] + i)
      rankf = ANSI.red + rankf + ANSI.reset if RICH_RANKINGS && count <= 20
      namef = format_string(r[0], pad2)
      namef = ANSI.blue + namef + ANSI.reset if RICH_RANKINGS && count <= 20
      scoref = fmt % r[1]
      scoref = ANSI.green + scoref + ANSI.reset if RICH_RANKINGS && count <= 20
      line = "#{rankf}: #{namef} - #{scoref}"
      line += " (%#{pad3}d)" % [r[2]] if !r[2].nil?
      line
    }.join("\n")
  end

  # SEND message
  if nav
    view = Discordrb::Webhooks::View.new
    interaction_add_button_navigation(view, pag[:page], pag[:pages])
    interaction_add_type_buttons(view, type, ties)
    interaction_add_select_menu_rtype(view, rtype)
    interaction_add_select_menu_metanet_tab(view, tab)
    send_message(event, content: header + "\n" + format_block(rank), components: view)
  else
    event << header
    event << footer
    count <= 20 ? event << format_block(rank) : send_file(event, rank, 'rankings.txt')

  end
rescue => e
  lex(e, 'Failed to perform the rankings.', event: event)
  nil
end

# Sort highscoreables by amount of scores (0-20) with certain characteristics
# (e.g. classify levels by amount of cool/* scores)
def send_tally(event)
  # Parse message parameters
  msg   = parse_message(event)
  type  = parse_type(msg)
  tabs  = parse_tabs(msg)
  cool  = parse_cool(msg)
  star  = parse_star(msg)
  ties  = parse_ties(msg)
  range = parse_range(msg, true)
  list  = !!msg[/\blist\b/i]

  # Retrieve tally
  res   = Score.tally(list, type, tabs, ties, cool, star, range[0], range[1])
  count = list ? res.map(&:size).sum : res.sum

  # Format response
  type  = format_type(type)
  tabs  = format_tabs(tabs)
  cool  = format_cool(cool)
  star  = format_star(star)
  ties  = ties ? 'tied for 0th' : ''
  pad1  = (0..20).select{ |r| list ? !res[r].empty? : res[r] > 0 }.max.to_s.length
  pad2  = res.max.to_s.length if !list
  block = (0..20).to_a.reverse.map{ |r|
    if list
      "#{r} #{cplural('score', r)}:\n\n" + res[r].join("\n") + "\n" if !res[r].empty?
    else
      "#{"%#{pad1}d #{cplural('score', r, true)}: %#{pad2}d" % [r, res[r]]}" if res[r] != 0
    end
  }.compact.join("\n")
  range = format_range(range[0], range[1])

  # Send response
  event << format_header("#{tabs} #{type} #{cool} #{range}#{star} scores #{ties} tally #{format_time}")
  !list || count <= 20 ? event << format_block(block) : send_file(event, block, 'tally.txt')
rescue => e
  lex(e, 'Error performing tally.', event: event)
end

# Return a player's total score (sum of scores) in specified tabs and type
def send_total_score(event)
  # Parse message parameters
  msg    = parse_message(event)
  player = parse_player(event)
  type   = parse_type(msg, default: Level)
  tabs   = parse_tabs(msg)

  # Retrieve total score
  score = player.total_score(type, tabs)

  # Format response
  max  = round_score(find_max(:score, type, tabs))
  type = format_type(type).downcase
  tabs = format_tabs(tabs)
  event << "#{player.print_name}'s total #{tabs} #{type} score is #{"%.3f" % [round_score(score)]} out of #{"%.3f" % max}.".squish
rescue => e
  lex(e, "Error calculating total score.", event: event)
end

# Return list of levels/episodes with largest/smallest score difference between
# 0th and Nth rank
def send_spreads(event)
  # Parse message parameters
  msg     = parse_message(event)
  n       = (parse_rank(msg) || 2) - 1
  type    = parse_type(msg, default: Level)
  tabs    = parse_tabs(msg)
  player  = parse_player(event, false, true, false)
  full    = parse_full(msg)
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  board   = parse_board(msg, 'hs')
  small   = !!(msg =~ /smallest/)
  perror("Metanet maps only have highscore mode for now.") if !mappack && board != 'hs'
  perror("This function is only available for highscore and speedrun modes for now.") if !['hs', 'sr'].include?(board)
  perror("I can't show you the spread between 0th and 0th...") if n == 0

  # Retrieve and format spreads
  sr       = board == 'sr'
  spreads  = Highscoreable.spreads(n, type, tabs, small, player.nil? ? nil : player.id, full, mappack, board)
  namepad  = spreads.map{ |s| s[0].length }.max
  scorepad = spreads.map{ |s| s[1] }.max.to_i.to_s.length + (sr ? 0 : 4)
  fmt      = sr ? 'd' : '.3f'
  spreads  = spreads.each_with_index
                    .map { |s, i| "#{"%-#{namepad}s" % s[0]} - #{"%#{scorepad}#{fmt}" % s[1]} - #{s[2]}"}
                    .join("\n")

  # Format response
  spread  = small ? 'smallest' : 'largest'
  rank    = n.ordinalize
  type    = format_type(type).downcase.pluralize
  tabs    = tabs.empty? ? 'All ' : format_tabs(tabs)
  player  = !player.nil? ? "owned by #{player.print_name} " : ''
  mappack = format_mappack(mappack)
  board   = format_board(board)
  event << "#{tabs} #{type} #{player} with the #{spread} #{board} spread between 0th and #{rank} #{mappack}:".squish
  full ? send_file(event, spreads, 'spreads.txt') : event << format_block(spreads)
rescue => e
  lex(e, "Error performing spreads.", event: event)
end

# Send highscore leaderboard for a highscoreable.
#   'map'  means the highscoreable will be sent as a parameter, rather than
#          being parsed from the message (used, e.g., for lotd)
#   'ret'  means the leaderboards will be returned to be used in another
#          function (e.g., screenscores), rather than sent
def send_scores(event, map = nil, ret = false)
  # Parse message parameters
  msg     = parse_message(event)
  h       = map.nil? ? parse_highscoreable(event, mappack: true) : map
  offline = parse_offline(msg)
  nav     = parse_nav(msg)
  mappack = h.is_a?(MappackHighscoreable)
  board   = parse_board(msg, 'hs', dual: true)
  board   = 'hs' if !mappack && board == 'dual'
  full    = parse_full(msg)
  perror("Sorry, Metanet levels only support highscore mode for now.") if !mappack && board != 'hs'
  res     = ""

  # Navigating scores goes into a different method (see below this one)
  if nav && !h.is_a?(MappackHighscoreable)
    send_nav_scores(event)
    return
  end

  # Update scores, unless we're in offline mode or the connection fails
  if OFFLINE_STRICT
    res << "Strict offline mode is ON, sending local cached scores.\n"
  elsif !offline && h.is_a?(Downloadable) && h.update_scores(fast: true) == -1
    res << "Connection to the server failed, sending local cached scores.\n"
  end

  # Format scores
  header = format_header("#{format_full(full)} #{format_board(board).pluralize} for #{h.format_name}")
  res << header
  scores = h.format_scores(mode: board, full: full, join: false)
  if full && scores.count > 20
    send_file(event, scores.join("\n"), "#{h.name}-scores.txt")
  else
    res << format_block(scores.join("\n"))
  end

  # Add cleanliness if it's an episode or a story
  res << "\n" if full
  res << "Scores: **#{h.completions}**. " if h.completions && h.completions > 0
  res << send_clean_one(event, true) if (h.is_a?(Episodish) || h.is_a?(Storyish)) && board != 'gm'

  # If it's an episode, update all 5 level scores in the background
  if h.is_a?(Episode) && !offline && !OFFLINE_STRICT
    _thread(release: true) do
      h.levels.each(&:update_scores)
    end
  end

  # Send response or return it
  if ret
    return res
  else
    event << res
  end
rescue => e
  lex(e, "Error sending scores.", event: event)
end

# Navigating scores: Main differences:
# - Does not update the scores.
# - Adds navigating between levels.
# - Adds navigating between dates.
def send_nav_scores(event, offset: nil, date: nil)
  # Parse message parameters
  initial = parse_initial(event)
  scores  = parse_highscoreable(event)

  # Retrieve scores for specified date and highscoreable
  scores = scores.nav(offset.to_i)
  dates  = Archive.changes(scores).sort.reverse
  if initial || date.nil?
    new_index = 0
  else
    old_date  = event.message.components[1].to_a[2].custom_id.to_s.split(':').last.to_i
    new_index = (dates.find_index{ |d| d == old_date } + date.to_i).clamp(0, dates.size - 1)
  end
  date = dates[new_index] || 0

  # Format response
  str = "Navigating highscores for #{scores.format_name}:\n"
  str += format_block(Archive.format_scores(Archive.scores(scores, date), Archive.zeroths(scores, date))) rescue ""
  str += "*Warning: Navigating scores does not update them.*"

  # Send response
  view = Discordrb::Webhooks::View.new
  interaction_add_level_navigation(view, scores.name.center(11, ' '))
  interaction_add_date_navigation(view, new_index + 1, dates.size, date, date == 0 ? 'Date' : Time.at(date).strftime("%Y-%b-%d"))
  send_message(event, content: str, components: view)
rescue => e
  lex(e, "Error navigating scores.", event: event)
end

# Send a screenshot of a level/episode/story
def send_screenshot(event, map = nil, ret = false)
  # Parse message parameters
  msg     = parse_message(event)
  hash    = parse_palette(event)
  msg     = hash[:msg]
  h       = map.nil? ? parse_highscoreable(event, mappack: true) : map
  version = msg[/v(\d+)/i, 1]

  # Retrieve screenshot
  h = h.map
  max_v = h.version
  spoiler = event.channel.type != 1 && (h.mappack.code == 'asc' || h.mappack.code == 'ctp' && event.channel.id != CHANNEL_CTP_SECRETS)
  version = version ? [max_v, [1, version.to_i].max].min : max_v
  screenshot = Map.screenshot(hash[:palette], file: true, h: h, spoiler: spoiler, v: version)
  perror("Failed to generate screenshot!") if screenshot.nil?

  # Send response
  v_str = h.is_mappack? ? " v#{version}" : ''
  str = "#{hash[:error]}Screenshot for #{h.format_name}#{v_str} in palette #{verbatim(hash[:palette])}:"
  return [screenshot, str, spoiler] if ret
  event << str
  event.attach_file(screenshot, spoiler: spoiler)
rescue => e
  lex(e, "Error sending screenshot.", event: event)
end

# One command to return a screenshot and then the scores,
# since it's a very common combination
def send_screenscores(event)
  # Parse message parameters
  map = parse_highscoreable(event, mappack: true)
  ss  = send_screenshot(event, map, true)
  s   = send_scores(event, map, true)
  send_message(event, content: ss[1], files: [ss[0]], spoiler: ss[2])
  sleep(0.25)
  send_message(event, content: s)
rescue => e
  lex(e, "Error sending screenshot or scores.", event: event)
end

# Same, but sending the scores first and the screenshot second
def send_scoreshot(event)
  map = parse_highscoreable(event, mappack: true)
  s   = send_scores(event, map, true)
  ss  = send_screenshot(event, map, true)
  send_message(event, content: s)
  sleep(0.25)
  send_message(event, content: ss[1], files: [ss[0]], spoiler: ss[2])
rescue => e
  lex(e, "Error sending screenshot or scores.", event: event)
end

# Returns rank distribution of a player's scores, in both table and histogram form
def send_stats(event)
  # Parse message parameters
  msg    = parse_message(event)
  player = parse_player(event)
  tabs   = parse_tabs(msg)
  ties   = parse_ties(msg)

  # Retrieve counts and generate table and histogram
  counts = player.score_counts(tabs, ties)

  full_counts = (0..19).map{ |r|
    l = counts[:levels][r].to_i
    e = counts[:episodes][r].to_i
    s = counts[:stories][r].to_i
    [l + e, l, e, s]
  }

  histogram = AsciiCharts::Cartesian.new(
    (0..19).map{ |r| [r, counts[:levels][r].to_i + counts[:episodes][r].to_i] },
    bar: true,
    hide_zero: true,
    max_y_vals: 15,
    title: 'Score histogram'
  ).draw

  # Format response
  totals  = full_counts.each_with_index.map{ |c, r| "#{Highscoreable.format_rank(r)}: #{"   %4d  %4d    %4d   %4d" % c}" }.join("\n\t")
  overall = "Totals:    %4d  %4d    %4d   %4d" % full_counts.reduce([0, 0, 0, 0]) { |sums, curr| sums.zip(curr).map { |a| a[0] + a[1] } }
  maxes   = [Level, Episode, Story].map{ |t| find_max(:rank, t, tabs) }
  maxes   = "Max:       %4d  %4d    %4d   %4d" % maxes.unshift(maxes[0] + maxes[1])
  tabs    = tabs.empty? ? "" : " in the #{format_tabs(tabs)} #{tabs.length == 1 ? 'tab' : 'tabs'}"
  msg1    = "Player highscore counts for #{player.print_name}#{tabs}:\n```        Overall Level Episode Column\n\t#{totals}\n#{overall}\n#{maxes}"
  msg2    = "#{histogram}```"

  # Send response (careful, it can go over the char limit)
  if msg1.length + msg2.length <= DISCORD_CHAR_LIMIT
    event << msg1
    event << msg2
  else
    send_message(event, content: msg1 + "```")
    send_message(event, content: "```" + msg2)
  end
rescue => e
  lex(e, "Error computing stats.", event: event)
end

# Returns community's overal total and average scores
#   * The total score is the sum of all 0th scores
#   * The average score is the total score over the number of scores
#   * The difference between level and episode scores is computed by adding
#     the 5 corresponding level 0ths, subtracting the 4 * 90 additional
#     seconds one gets at the start of each individual level (bar level 0),
#     and then subtracting the episode 0th score.
def send_community(event)
  # Parse message parameters
  msg  = parse_message(event)
  tabs = parse_tabs(msg)
  rank = parse_range(msg)[0..1].max - 1
  has_secrets = !(tabs & [:SS, :SS2]).empty? || tabs.empty?
  has_episodes = !(tabs - [:SS, :SS2]).empty? || tabs.empty?

  # Retrieve community's total and average scores
  levels = Score.total_scores(Level, tabs, rank, true)
  episodes = Score.total_scores(Episode, tabs, rank, false) if has_episodes
  levels_no_secrets = (has_secrets ? Score.total_scores(Level, tabs, rank, false) : levels) if has_episodes
  difference = levels_no_secrets[0] - 4 * 90 * episodes[1] - episodes[0] if has_episodes

  # Format response
  pad = ("%.3f" % levels[0]).length
  str = ''
  str << "Total level score:     #{"%#{pad}.3f" % [levels[0]]}\n"
  str << "Total episode score:   #{"%#{pad}.3f" % [episodes[0]]}\n"               if has_episodes
  str << "Difference:            #{"%#{pad}.3f" % [difference]}\n\n"              if has_episodes
  str << "Average level score:   #{"%#{pad}.3f" % [levels[0] / levels[1]]}\n"
  str << "Average episode score: #{"%#{pad}.3f" % [episodes[0] / episodes[1]]}\n" if has_episodes
  str << "Average difference:    #{"%#{pad}.3f" % [difference / episodes[1]]}\n"  if has_episodes
  event << "Community's total #{rank.ordinalize} #{format_tabs(tabs)} scores #{format_time}:\n".squish
  event << format_block(str)
rescue => e
  lex(e, "Error computing community total scores.", event: event)
end

# Return list of levels/episodes sorted by number of ties for 0th (desc)
def send_maxable(event, maxed = false)
  # Parse message parameters
  msg     = parse_message(event)
  player  = parse_player(event, false, !msg[/missing/i], false)
  type    = parse_type(msg, default: Level)
  tabs    = parse_tabs(msg)
  full    = parse_full(msg)
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  board   = parse_board(msg, 'hs')
  perror("Metanet maps only have highscore mode for now.") if !mappack && board != 'hs'
  perror("This function is only available for highscore and speedrun modes for now.") if !['hs', 'sr'].include?(board)

  # Retrieve maxed/maxable scores
  ties   = Highscoreable.ties(type, tabs, player.nil? ? nil : player.id, maxed, false, mappack, board)
  ties   = ties.take(NUM_ENTRIES) if (!maxed || mappack) && !full
  pad1   = ties.map{ |s| s[0].length }.max
  pad2   = ties.map{ |s| s[1].to_s.length }.max
  count  = ties.size
  ties   = ties.map { |s|
    if maxed && !mappack
      "#{"%-#{pad1}s" % s[0]} - #{format_string(s[2])}"
    else
      "#{"%-#{pad1}s" % s[0]} - #{"%#{pad2}d" % s[1]} - #{format_string(s[2])}"
    end
  }.join("\n")

  # Format response
  type    = format_type(type).downcase
  tabs    = format_tabs(tabs)
  mappack = format_mappack(mappack)
  board   = format_board(board).pluralize
  player  = player.nil? ? '' : 'without ' + player.print_name
  if maxed
    event << format_header("There are #{count} #{tabs} potentially maxed #{type} #{board} #{mappack} #{format_time} #{player}")
  else
    event << format_header("#{tabs} #{type} #{board} with the most ties for 0th #{mappack} #{format_time} #{player}")
  end
  count <= NUM_ENTRIES ? event << format_block(ties) : send_file(event, ties, "maxed-#{tabs}-#{type}.txt")
rescue => e
  lex(e, "Error computing maxables / maxes.", event: event)
end

# Returns a list of maxed levels/episodes, i.e., with 20 ties for 0th
def send_maxed(event)
  send_maxable(event, true)
end

# Returns a list of episodes sorted by difference between
# episode 0th and the sum of the level 0ths
def send_cleanliness(event)
  # Parse message parameters
  msg     = parse_message(event)
  type    = parse_type(msg, default: Episode)
  tabs    = parse_tabs(msg)
  rank    = parse_range(msg)[0]
  board   = parse_board(msg, 'hs')
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  full    = parse_full(msg)
  clean   = !!msg[/cleanest/i]
  perror("Cleanliness is only available for episodes or stories.") if type == Level
  perror("Cleanliness is only supported for highscore or speedrun mode.") if !['hs', 'sr'].include?(board)
  perror("Metanet only supports highscore mode for now.") if mappack.nil? && board != 'hs'

  # Retrieve episodes and cleanliness
  list = Highscoreable.cleanliness(type, tabs, rank, mappack, board)
                      .sort_by{ |e| (clean ? e[1] : -e[1]) }
  list = list.take(NUM_ENTRIES) if !full
  size = list.size
  fmt  = list[0][1].is_a?(Integer) ? 'd' : '.3f'
  pad1 = list.map{ |e| e[0].length }.max
  pad2 = list.map{ |e| e[1].to_i.to_s.length + (fmt == 'd' ? 0 : 4) }.max
  list = list.map{ |e| "#{"%#{pad1}s" % e[0]} - #{"%#{pad2}#{fmt}" % e[1]} - #{e[2]}" }.join("\n")

  # Format response
  code    = mappack ? "_#{mappack.code}" : ''
  file    = "#{clean}_#{board}#{code}_#{format_type(type)}.txt"
  tabs    = tabs.empty? ? 'All ' : format_tabs(tabs)
  clean   = clean ? 'cleanest' : 'dirtiest'
  board   = format_board(board)
  mappack = format_mappack(mappack)
  header  = "#{tabs} #{clean} #{board} episodes #{mappack} #{format_time}:".squish

  # Send response
  event << header
  size > NUM_ENTRIES ? send_file(event, list, file) : event << format_block(list)
rescue => e
  lex(e, "Error computing cleanlinesses.", event: event)
end

# Returns the cleanliness of a single episode or story 0th
def send_clean_one(event, ret = false)
  # Parse params
  msg = parse_message(event)
  h = parse_highscoreable(event, mappack: true)
  perror("Cleanliness is an episode/story-specific function!") if h.is_a?(Levelish)
  board = parse_board(msg, 'hs')
  perror("Sorry, G-- cleanlinesses aren't available yet.") if board == 'gm'
  perror("Only highscore mode is available for Metanet levels for now.") if !h.is_mappack? && board != 'hs'
  rank = !ret ? parse_range(msg)[0] : 0

  # Compute cleanliness
  clean = h.cleanliness(rank, board)
  (ret ? (return '') : perror("No #{rank.ordinalize} #{format_board(board)} score found in this leaderboard.")) if !clean
  clean_round = round_score(clean)
  fmt = clean.is_a?(Integer) ? '%df' : '%.3f (%df)'
  args = clean.is_a?(Integer) ? [clean_round] : [clean_round, (60 * clean_round).round]
  return "Cleanliness: **#{fmt % args}**." if ret

  # Compute extra info for the dedicated function
  event << "The cleanliness of #{h.name}'s #{format_board(board)} #{rank.ordinalize} is #{fmt % args}."

  clean_round = clean_round.to_f / 5
  fmt = clean.is_a?(Integer) ? '%.1ff' : '%.3f (%.1ff)'
  args = clean.is_a?(Integer) ? [clean_round] : [clean_round, 60 * clean_round]
  event << "Average per-#{h.is_episode? ? 'level' : 'episode'} cleanliness of #{fmt % args}."

  if h.is_story?
    clean_round = clean_round.to_f / 5
    fmt = clean.is_a?(Integer) ? '%.1ff' : '%.3f (%.1ff)'
    args = clean.is_a?(Integer) ? [clean_round] : [clean_round, 60 * clean_round]
    event << "Average per-level cleanliness of #{fmt % args}."
  end
rescue => e
  lex(e, "Error computing cleanliness.", event: event)
end

# Returns a list of episode ownages, i.e., episodes where the same player
# has 0th in all 5 levels and the episode
def send_ownages(event)
  # Parse message parameters
  msg  = parse_message(event)
  tabs = parse_tabs(msg)

  # Retrieve ownages
  ownages = Episode.ownages(tabs)
  pad     = ownages.map{ |e, p| e.length }.max
  list    = ownages.map{ |e, p| "#{"%#{pad}s" % e} - #{p}" }.join("\n")
  count   = ownages.count
  if count <= 20
    block = list
  else
    block = ownages.group_by{ |e, p| p }.map{ |p, o| "#{format_string(p)} - #{o.count}" }.join("\n")
  end

  # Format response
  tabs_h = tabs.empty? ? 'All ' : format_tabs(tabs)
  tabs_f = tabs.empty? ? '' : format_tabs(tabs)
  event << "#{tabs_h} episode ownages #{format_max(find_max(:rank, Episode, tabs))} #{format_time}:".squish
  event << format_block(block) + "There're a total of #{count} #{tabs_f} episode ownages."
  send_file(event, list, 'ownages.txt') if count > 20
rescue => e
  lex(e, "Error computing ownages.", event: event)
end

# Return list of a player's most improvable scores, filtered by type and tab
def send_worst(event, worst = true)
  # Parse message parameters
  msg     = parse_message(event)
  player  = parse_player(event)
  type    = parse_type(msg, default: Level)
  tabs    = parse_tabs(msg)
  full    = parse_full(msg)
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  board   = parse_board(msg, 'hs')
  perror("This function is only available for highscore and speedrun mode.") if !['hs', 'sr'].include?(board)
  perror("Speedrun mode is not yet available for Metanet levels.") if board == 'sr' && !mappack

  # Retrieve and format most improvable scores
  list = player.score_gaps(type, tabs, worst, full, mappack, board)
  fmt  = board == 'sr' ? 'd' : '.3f'
  pad1 = list.map{ |level, gap| level.length }.max
  pad2 = list.map{ |level, gap| gap }.max.to_i.to_s.length + (board == 'sr' ? 0 : 4)
  list = list.map{ |level, gap| "#{"%-#{pad1}s" % [level]} - #{"%#{pad2}#{fmt}" % [round_score(gap)]}" }.join("\n")

  # Send response
  adverb  = worst ? 'most' : 'least'
  worst   = worst ? 'worst' : 'best'
  tabs    = format_tabs(tabs)
  type    = format_type(type).downcase
  mappack = format_mappack(mappack)
  board   = format_board(board).pluralize
  event << format_header("#{adverb} improvable #{tabs} #{type} #{board} #{mappack} for #{player.print_name}")
  full ? send_file(event, list, "#{worst}.txt") : event << format_block(list)
rescue => e
  lex(e, "Error getting worst scores.", event: event)
end

# Return level ID for a specified level name
def send_level_id(event)
  level = parse_highscoreable(event, mappack: true)
  perror("Episodes and stories don't have a name!") if level.is_episode? || level.is_story?
  event << "#{level.longname} is level #{level.name}."
rescue => e
  lex(e, "Error getting ID.", event: event)
end

# Return level name for a specified level ID
def send_level_name(event)
  level = parse_highscoreable(event, mappack: true)
  perror("Episodes and stories don't have a name!") if level.is_episode? || level.is_story?
  event << "#{level.name} is called #{level.longname}."
rescue => e
  lex(e, "Error getting name.", event: event)
end

# Return a player's point count
#   (a 0th is worth 20 points, a 1st is 19 points, all the way down to
#    1 point for a 19th score)
# Arguments:
#   'avg'  we compute the average points, see method below
#   'rank' we compute the average rank, which is just 20 - avg points
def send_points(event, avg = false, rank = false)
  # Parse message parameters
  msg    = parse_message(event)
  player = parse_player(event)
  type   = parse_type(msg)
  tabs   = parse_tabs(msg)

  # Retrieve player points, filtered by type and tabs
  points = avg ? player.average_points(type, tabs) : player.points(type, tabs)

  # Format and send response
  max  = find_max(avg ? :avg_points : :points, type, tabs)
  type = format_type(type).downcase
  tabs = format_tabs(tabs)
  if avg
    if rank
      event << "#{player.print_name} has an average #{tabs} #{type} rank of #{"%.3f" % [20 - points]}.".squish
    else
      event << "#{player.print_name} has #{"%.3f" % [points]} out of #{"%.3f" % max} average #{tabs} #{type} points.".squish
    end
  else
    event << "#{player.print_name} has #{points} out of #{max} #{tabs} #{type} points.".squish
  end
rescue => e
  lex(e, "Error computing points.", event: event)
end

# Return a player's average point count
# (i.e., total points divided by the number of scores, measures score quality)
def send_average_points(event)
  send_points(event, true)
rescue => e
  lex(e, "Error computing average points.", event: event)
end

# Return a player's average rank across all their scores, ideal quality measure
# It's actually just 20 - average points
def send_average_rank(event)
  send_points(event, true, true)
rescue => e
  lex(e, "Error computing average rank.", event: event)
end

# Return a player's average 0th lead across all their 0ths
def send_average_lead(event)
  # Parse message parameters
  msg    = parse_message(event)
  player = parse_player(event)
  type   = parse_type(msg, default: Level)
  tabs   = parse_tabs(msg)

  # Retrieve average 0th lead
  average = player.average_lead(type, tabs)

  # Format and send response
  type = format_type(type).downcase
  tabs = format_tabs(tabs)
  event << "#{player.print_name} has an average #{type} #{tabs} lead of #{"%.3f" % [average]}.".squish
rescue => e
  lex(e, "Error computing average lead.", event: event)
end

# Return a table containing a certain measure (e.g. top20 count, points, etc)
# and classifying it by type (columns) and tabs (rows)
def send_table(event)
  # Parse message parameters
  msg    = parse_message(event)
  player = parse_player(event)
  cool   = parse_cool(msg)
  star   = parse_star(msg)
  global = false # Table for a user, or the community
  ties   = parse_ties(msg)
  avg    = !!(msg =~ /\baverage\b/i) || !!(msg =~ /\bavg\b/i)
  rtype = :rank
  if avg
    if msg   =~ /\bpoint\b/i
      rtype  = :avg_points
      header = "average points"
    else
      rtype  = :avg_rank
      header = "average rank"
    end
  elsif msg  =~ /\bpoint/i
    rtype    = :points
    header   = "points"
  elsif msg  =~ /\bscore/i
    rtype    = :score
    header   = "total scores"
  elsif msg  =~ /\btied\b/i
    rtype    = :tied_rank
    header   = "tied scores"
  elsif msg  =~ /\bmaxed/i
    rtype    = :maxed
    header   = "maxed scores"
    global   = true
  elsif msg  =~ /\bmaxable/i
    rtype    = :maxable
    header   = "maxable scores"
    global   = true
  else
    rtype    = :rank
    header   = "scores"
  end
  range = parse_range(msg, cool || star || rtype != :rank)

  # The range must make sense
  if !range[2]
    event << "You specified an empty range! (#{format_range(range[0], range[1])})"
    return
  end

  # Retrieve table (a matrix, first index is type, second index is tab)
  table = player.table(rtype, ties, range[0], range[1], cool, star)

  # Construct table. If it's an average measure, we need to retrieve the
  # table of totals first to do the weighed averages.
  if avg
    scores = player.table(:rank, ties, 0, 20)
    totals = Level::tabs.select{ |tab, id| id < 7 }.map{ |tab, id|
      lvl = scores[0][tab] || 0
      ep  = scores[1][tab] || 0
      [format_tab(tab.to_sym), lvl, ep, lvl + ep]
    }
  end
  table = Level::tabs.select{ |tab, id| id < 7 }.each_with_index.map{ |tab, i|
    lvl = table[0][tab[0]] || 0
    ep  = table[1][tab[0]] || 0
    [
      format_tab(tab[0].to_sym),
      avg ? lvl : round_score(lvl),
      avg ? ep : round_score(ep),
      avg ? wavg([lvl, ep], totals[i][1..2]) : round_score(lvl + ep)
    ]
  }

  # Format table rows
  rows = []
  rows << ["", "Level", "Episode", "Total"]
  rows << :sep
  rows += table
  rows << :sep
  if !avg
    rows << [
      "Total",
      table.map(&:second).sum,
      table.map(&:third).sum,
      table.map(&:fourth).sum
    ]
  else
    rows << [
      "Total",
      wavg(table.map(&:second), totals.map(&:second)),
      wavg(table.map(&:third),  totals.map(&:third)),
      wavg(table.map(&:fourth), totals.map(&:fourth))
    ]
  end

  # Send response
  cool  = format_cool(cool)
  star  = format_star(star)
  ties  = format_ties(ties)
  range = format_range(range[0], range[1], [:maxed, :maxable].include?(rtype))
  header = "#{cool} #{range}#{star} #{header} #{ties} table".squish
  player = global ? "" : "#{player.format_name.strip}'s "
  event << "#{player} #{global ? header.capitalize : header} #{format_time}:".squish
  event << format_block(make_table(rows))
rescue => e
  lex(e, "Error crafting table.", event: event)
end

# Return score comparison between 2 players. Lists 5 categories:
#   Scores which only P1 has
#   Scores where P1 > P2
#   Scores where P1 = P2
#   Scores where P1 < P2
#   Scores which only P2 has
# Returns both the counts, as well as the list of scores in a file
def send_comparison(event)
  # Parse message parameters
  msg    = parse_message(event)
  type   = parse_type(msg)
  tabs   = parse_tabs(msg)
  p1, p2 = parse_players(event)

  # Retrieve comparison info
  comp   = Player.comparison(type, tabs, p1, p2)
  counts = comp.map{ |t| t.map{ |r, s| s.size }.sum }

  # Format message
  header = "#{format_type(type)} #{format_tabs(tabs)} comparison between #{p1.truncate_name} and #{p2.truncate_name} #{format_time}:".squish
  rows = ["Scores with only #{p1.truncate_name}"]
  rows << "Scores where #{p1.truncate_name} > #{p2.truncate_name}"
  rows << "Scores where #{p1.truncate_name} = #{p2.truncate_name}"
  rows << "Scores where #{p1.truncate_name} < #{p2.truncate_name}"
  rows << "Scores with only #{p2.truncate_name}"
  table = rows.zip(counts)
  pad1  = table.map{ |row, count| row.length }.max
  pad2  = table.map{ |row, count| numlen(count, false) }.max
  table = table.map{ |r, c| "#{"%-#{pad1}s" % r} - #{"%#{pad2}d" % c}" }.join("\n")

  # Format file
  list = (0..4).map{ |i|
    pad1 = comp[i].map{ |r, s| s.map{ |e| e.size == 2 ?  e[0][2].length :  e[2].length }.max }.max
    pad2 = comp[i].map{ |r, s| s.map{ |e| e.size == 2 ? numlen(e[0][3]) : numlen(e[3]) }.max }.max
    pad3 = comp[i].map{ |r, s| s.map{ |e| e.size == 2 ? numlen(e[1][3]) : numlen(e[3]) }.max }.max
    rows[i] + ":\n\n" + comp[i].map{ |r, s|
      s.map{ |e|
        if e.size == 2
          str = "#{"%-#{pad1}s" % e[0][2]} - "
          str += "[#{"%02d" % e[0][0]}: #{"%#{pad2}.3f" % e[0][3]}] vs. "
          str += "[#{"%02d" % e[1][0]}: #{"%#{pad3}.3f" % e[1][3]}]"
          str
        else
          "#{"%02d" % e[0]}: #{"%-#{pad1}s" % e[2]} - #{"%#{pad2}.3f" % e[3]}"
        end
      }.join("\n")
    }.join("\n") + "\n"
  }.join("\n")

  # Send response
  event << header + format_block(table)
  send_file(event, list, "comparison-#{p1.sanitize_name}-#{p2.sanitize_name}.txt")
rescue => e
  lex(e, "Error performing comparison.", event: event)
end

# Return a list of random highscoreables
def send_random(event)
  # Parse message parameters
  msg    = parse_message(event)
  type   = parse_type(msg, default: Level)
  tabs   = parse_tabs(msg)
  amount = [msg[/\d+/].to_i || 1, NUM_ENTRIES].min

  # Retrieve list of maps
  maps = tabs.empty? ? type.all : type.where(tab: tabs)

  # Format and send response
  if amount > 1
    tabs = format_tabs(tabs)
    type = format_type(type).downcase.pluralize
    event << "Random selection of #{amount} #{tabs} #{type}:".squish
    event << format_block(maps.sample(amount).map(&:name).join("\n"))
  else
    map = maps.sample
    send_screenshot(event, map)
  end
rescue => e
  lex(e, "Error getting random sample.", event: event)
end

# Return list of challenges for specified level, ordered and formatted as in the game
def send_challenges(event)
  allowable_channels = [CHANNEL_SECRETS, CHANNEL_CTP_SECRETS]
  if !(event.channel.type == 1 || allowable_channels.include?(event.channel.id))
    mentions = allowable_channels.map{ |c| mention_channel(id: c) }.join(', ')
    perror("No asking for challenges outside of #{mentions} or DMs!")
  end

  lvl = parse_highscoreable(event, mappack: true)
  perror("Mappacks don't have challenges (yet ¬‿¬)") if lvl.is_mappack?
  perror("#{lvl.class.to_s.pluralize.capitalize} don't have challenges!") if lvl.class != Level
  perror("#{lvl.tab.to_s} levels don't have challenges!") if ["SI", "SL"].include?(lvl.tab.to_s)
  event << "Challenges for #{lvl.longname} (#{lvl.name}):\n#{format_block(lvl.format_challenges)}"
rescue => e
  lex(e, "Error getting challenges.", event: event)
end

# Return list of matches for specific level name query
# Also the fallback for other functions when there are multiple matches
# (e.g. scores, screenshot, challenges, level id, ...)
# 'page' parameters controls button page navigation when there are many results
def send_query(event, page: nil)
  parse_highscoreable(event, list: true, mappack: true, page: page)
rescue => e
  lex(e, "Error performing query.", event: event)
end

# Sends the Top20 changes for the current lotd/eotw/cotm
def send_diff(event)
  # Parse params
  msg      = parse_message(event)
  mappack  = parse_mappack(msg, parse_user(event.user), event.channel)
  type     = parse_type(msg, default: Level)
  period   = type == Level ? 'day'   : type == Episode ? 'week'    : 'month'
  type_str = type == Level ? 'level' : type == Episode ? 'episode' : 'column'
  code     = mappack.nil? || mappack.id == 0 ? '' : mappack.code.upcase + ' '
  name     = "#{code}#{type_str} of the #{period}"
  perror("There is no #{name}.") if mappack && !['met', 'ctp'].include?(mappack.code)

  # Fetch and format differences
  ctp = mappack && mappack.code == 'ctp'
  current = GlobalProperty.get_current(type, ctp)
  old_scores = GlobalProperty.get_saved_scores(type, ctp)
  perror("There is no current #{name}.") if current.nil?
  perror("The old scores for the current #{name} we not saved :S") if old_scores.nil?
  diff = current.format_difference(old_scores, 'dual')
  event << current.format_difference_header(diff)
rescue => e
  lex(e, "Error finding differences.", event: event)
end

def send_mappacks(event)
  msg = parse_message(event)
  short = !!msg[/short/i]
  counts = MappackLevel.group(:mappack_id).count
  list = Mappack.all.order(:date).map{ |m|
    fields = []
    fields << m.code.upcase
    fields << m.name.to_s unless short
    fields << m.authors.to_s unless short
    fields << m.date.strftime('%Y/%b/%d') rescue ''
    fields << counts[m.id].to_i
    fields
  }
  header = []
  header << 'Code'
  header << 'Name' unless short
  header << 'Authors' unless short
  header << 'Date'
  header << 'Levels'
  rows = [header, :sep, *list]
  list.size < 20 ? event << format_block(make_table(rows)) : send_file(event, make_table(rows), 'mappacks.txt')
rescue => e
  lex(e, 'Error sending mappack list.')
end

# Return the demo analysis of a level's replay
def send_analysis(event)
  # Parse message parameters
  msg   = parse_message(event)
  ranks = parse_ranks(msg, -1)
  board = parse_board(msg, 'hs')
  h     = parse_highscoreable(event, mappack: true)

  # Integrity checks
  perror("Episodes and columns can't be analyzed yet.") if h.is_episode? || h.is_story?
  perror("Metanet levels only support highscore mode for now.") if !h.is_mappack? && board != 'hs'
  perror("G-- mode is not supported yet.") if board == 'gm'
  code = h.mappack.code if h.is_mappack?
  perror("This analysis is disabled, figure it out yourself!") if PROTECTED_BOARDS.key?(code) && PROTECTED_BOARDS[code].include?(h.name[4..-1])

  # Fetch runs
  boards = h.leaderboard(board, truncate: 0, pluck: false).all
  analysis = ranks.map{ |rank| [rank, (boards[rank].archive rescue nil)] }.to_h
  missing = analysis.select{ |r, a| a.nil? }.keys
  event << "Warning: #{'Run'.pluralize(missing.size)} with rank #{missing.to_sentence} not found." if !missing.empty?
  analysis.reject!{ |r, a| a.nil? }
  return if analysis.size == 0

  # Get run elements
  sfield = h.is_mappack? ? "score_#{board}" : 'score'
  scale = board == 'hs' ? 60.0 : 1
  analysis = analysis.map{ |rank, run|
    {
      'player' => run.player.name,
      'rank'   => rank,
      'score'  => run[sfield] / scale,
      'inputs' => run.demo.decode,
      'gold'   => run.gold
    }
  }
  length = analysis.map{ |a| a['inputs'].size }.max
  perror("The selected runs are empty.") if length == 0

  # We format the result in 3 different ways, only 2 are being used though.
  # Format 1 example:
  #   R.R.R.JR.JR...
  raw_result = analysis.map{ |a|
    a['inputs'].map{ |b|
      [b % 2 == 1, b / 2 % 2 == 1, b / 4 % 2 == 1]
    }.map{ |f|
      (f[2] ? 'L' : '') + (f[1] ? 'R' : '') + (f[0] ? 'J' : '')
    }.join(".")
  }.join("\n\n")

  # Format 2 example:
  #       |JRL|
  #   ---------
  #   0001| > |
  #   0002| > |
  #   0003| > |
  #   0004|^> |
  #   0005|^> |
  #   ...
  padding = Math.log(length, 10).to_i + 1
  head = " " * padding + "|" + "LJR|" * analysis.size
  sep = "-" * head.size
  table_result = analysis.map{ |a|
    table = a['inputs'].map{ |b|
      [
        b / 4 % 2 == 1 ? "<" : " ",
        b     % 2 == 1 ? "^" : " ",
        b / 2 % 2 == 1 ? ">" : " "
      ].push("|")
    }
    while table.size < length do table.push([" ", " ", " ", "|"]) end
    table.transpose
  }.flatten(1)
   .transpose
   .each_with_index
   .map{ |l, i| "%0#{padding}d|#{l.join}" % [i + 1] }
   .insert(0, head)
   .insert(1, sep)
   .join("\n")

  # Format 3 example:
  #   >>>//...
  codes = [
    ['-',  'Nothing'        ],
    ['^',  'Jump'           ],
    ['>',  'Right'          ],
    ['/',  'Right Jump'     ],
    ['<',  'Left'           ],
    ['\\', 'Left Jump'      ],
    ['≤',  'Left Right'     ],
    ['|',  'Left Right Jump']
  ]
  key_result = analysis.map{ |a|
    a['inputs'].map{ |f|
      codes[f][0] || '?' rescue '?'
    }.join
     .scan(/.{,60}/)
     .reject{ |f| f.empty? }
     .each_with_index
     .map{ |f, i| "%0#{padding}d #{f}" % [60 * i] }
     .join("\n")
  }.join("\n\n")

  # Format response
  #   - Digest of runs' properties (length, score, gold collected, etc)
  sr = h.is_mappack? && board == 'sr'
  gm = h.is_mappack? && board == 'gm'
  fmt = analysis[0]['score'].is_a?(Integer) ? "%d" : "%.3f"
  ppad = analysis.map{ |a| a['player'].length }.max
  rpad = [analysis.map{ |a| a['rank'].to_s.length }.max, 2].max
  spad = analysis.map{ |a| (fmt % a['score']).length }.max
  fpad = analysis.map{ |a| a['inputs'].size }.max.to_s.length
  gpad = analysis.map{ |a| a['gold'] }.max.to_s.length
  properties = format_block(
    analysis.map{ |a|
      rank_text = a['rank'].to_s.rjust(rpad, '0')
      name_text = format_string(a['player'], ppad)
      score_text = (fmt % a['score']).rjust(spad)
      frame_text = a['inputs'].size.to_s.rjust(fpad) + 'f, ' unless sr
      gold_text = a['gold'].to_s.rjust(gpad) + 'g' unless gm
      "#{rank_text}: #{name_text} - #{score_text} [#{frame_text}#{gold_text}]"
    }.join("\n")
  )
  #  - Summary of symbols' meaning
  explanation = "[#{codes.map{ |code, meaning| "**#{Regexp.escape(code)}** #{meaning}" }.join(', ')}]"
  #  - Header of message, and final result (format 2 only used if short enough)
  header = "Replay analysis for #{h.format_name} #{format_time}.".squish
  result = "#{header}\n#{properties}"
  result += "#{explanation}#{format_block(key_result)}" unless analysis.sum{ |a| a['inputs'].size } > 1080

  # Send response
  event << result
  send_file(event, table_result, "analysis-#{h.name}.txt")
rescue => e
  lex(e, "Error performing demo analysis.", event: event)
end

def send_demo_download(event)
  msg   = parse_message(event)
  h     = parse_highscoreable(event)
  code  = h.mappack.code if h.is_mappack?
  perror("Downloading this replay is disabled, figure it out yourself!") if PROTECTED_BOARDS.key?(code) && PROTECTED_BOARDS[code].include?(h.name[4..-1])
  rank  = [parse_range(msg).first, h.scores.size - 1].min
  score = h.scores[rank]
  event << "Downloading #{score.player.name}'s #{rank.ordinalize} score in #{h.name} (#{"%.3f" % [score.score]}):"
  send_file(event, score.demo.demo, "#{h.name}_#{rank.ordinalize}_replay", true)
rescue => e
  lex(e, "Error downloading demo.", event: event)
end

def send_download(event)
  h   = parse_highscoreable(event, mappack: true, map: true)
  perror("Only levels can be downloaded") if !h.is_a?(Levelish)
  event << "Downloading #{h.format_name}:"
  send_file(event, h.dump_level, h.name, true)
rescue => e
  lex(e, "Error preparing downloading.", event: event)
end

# Use SimVYo's tool to trace the replay of a run based on the map data and
# the demo data: still image.
def send_trace(event)
  perror("Sorry, tracing is disabled.") if !FEATURE_NTRACE
  wait_msg = send_message(event, content: "Queued...", db: false) if $mutex[:ntrace].locked?
  $mutex[:ntrace].synchronize do
    wait_msg.delete if !wait_msg.nil? rescue nil
    Map.trace(event, anim: !!parse_message(event)[/anim/i])
  end
rescue => e
  lex(e, "Error performing trace.", event: event)
end

# Return an episode's partial level scores and splits using 2 methods:
#   1) The actual episode splits, using SimVYo's tool
#   2) The IL splits
# Also return the differences between both
def send_splits(event)
  # Parse message parameters
  msg = parse_message(event)
  ep = parse_highscoreable(event, mappack: true)
  ep = ep.episode if ep.is_a?(Levelish)
  perror("Sorry, columns can't be analyzed yet.") if ep.is_a?(Storyish)
  mappack = ep.is_a?(MappackHighscoreable)
  board = parse_board(msg, 'hs')
  perror("Sorry, speedrun mode isn't available for Metanet levels yet.") if !mappack && board == 'sr'
  perror("Sorry, episode splits are only available for either highscore or speedrun mode.") if !['hs', 'sr'].include?(board)
  scores = ep.leaderboard(board, pluck: false)
  rank = parse_range(msg)[0].clamp(0, scores.size - 1)
  ntrace = board == 'hs' # Requires ntrace

  # Calculate episode splits
  if board == 'sr'
    valid = [true] * 5
    ep_scores = Demo.decode(scores[rank].demo.demo, true).map(&:size)
    ep_splits = splits_from_scores(ep_scores, start: 0, factor: 1, offset: 0)
  elsif FEATURE_NTRACE
    file = nil
    valid = valid = [false] * 5
    ep_splits = []
    ep_scores = []

    # Execute ntrace in mutex
    wait_msg = send_message(event, content: "Queued...", db: false) if $mutex[:ntrace].locked?
    $mutex[:ntrace].synchronize do
      wait_msg.delete if !wait_msg.nil? rescue nil

      # Export input files
      File.binwrite(NTRACE_INPUTS_E, scores[rank].demo.demo)
      ep.levels.each_with_index{ |l, i|
        map = !l.is_a?(Map) ? MappackLevel.find(l.id) : l
        File.binwrite(NTRACE_MAP_DATA_E % i, map.dump_level)
      }
      python(PATH_NTRACE)

      # Read output files
      file = File.binread(NTRACE_OUTPUT_E) rescue nil
      if !file.nil?
        valid = file.scan(/True|False/).map{ |b| b == 'True' }
        ep_splits = file.split(/True|False/)[1..-1].map{ |d|
          round_score(d.strip.to_i.to_f / 60.0)
        }
        ep_scores = scores_from_splits(ep_splits, offset: 90.0)
        FileUtils.rm([NTRACE_OUTPUT_E])
      end

      # Cleanup
      FileUtils.rm([NTRACE_INPUTS_E, *Dir.glob(NTRACE_MAP_DATA_E % '*')])
    end
  end

  # Calculate IL splits
  lvl_splits = ep.splits(rank, board: board)
  if lvl_splits.nil?
    event << "Sorry, that rank doesn't seem to exist for at least some of the levels."
    return
  end
  scoref = !mappack ? 'score' : "score_#{board}"
  factor = mappack && board == 'hs' ? 60.0 : 1
  lvl_scores = ep.levels.map{ |l| l.leaderboard(board)[rank][scoref] / factor }

  # Calculate differences
  full = !ntrace || (FEATURE_NTRACE && !file.nil?)
  event << "ntrace failed." if ntrace && file.nil?

  if full
    errors = valid.count(false)
    if errors > 0
      wrong = valid.each_with_index.map{ |v, i| !v ? i.to_s : nil }.compact.to_sentence
      event << "Warning: Couldn't calculate episode splits (error in #{'level'.pluralize(errors)} #{wrong})."
      full = false
    end

    cum_diffs = lvl_splits.each_with_index.map{ |ls, i|
      mappack && board == 'sr' ? ep_splits[i] - ls : ls - ep_splits[i]
    }
    diffs = cum_diffs.each_with_index.map{ |d, i|
      round_score(i == 0 ? d : d - cum_diffs[i - 1])
    }
  end

  # Format response
  rows = []
  rows << ['', '00', '01', '02', '03', '04']
  rows << :sep
  rows << ['Ep splits',  *ep_splits]  if full
  rows << ['Lvl splits', *lvl_splits]
  rows << ['Total diff', *cum_diffs]  if full
  rows << :sep                        if full
  rows << ['Ep scores',  *ep_scores]  if full
  rows << ['Lvl scores', *lvl_scores]
  rows << ['Ind diffs',  *diffs]      if full

  event << "#{rank.ordinalize} #{format_board(board)} splits for episode #{ep.name}:"
  event << "(Episode splits aren't available because ntrace is disabled)." if ntrace && !FEATURE_NTRACE
  event << format_block(make_table(rows))
rescue => e
  lex(e, "Error calculating splits.", event: event)
end

# Command to allow SimVYo to dynamically update his ntrace tool by sending the
# files via Discord
def update_ntrace(event)
  # Ensure only those allowed can do this
  assert_permissions(event, ['ntracer'])
  msg = ""
  yes = []
  no = []

  ['ntrace', 'nsim', 'nplay'].each{ |filename|
    # Fetch attached file and perform integrity checks
    files = event.message.attachments.select{ |a| a.filename == "#{filename}.py" }
    if files.size == 0
      no << filename
      next
    end
    if files.size > 1
      msg << "Didn't update #{verbatim("#{filename}.py")}: Too many #{filename}.py files found.\n"
      no << filename
      next
    end
    file = files.first
    if file.size > 1024 ** 2
      msg << "Didn't update #{verbatim("#{filename}.py")}: File is too large.\n"
      no << filename
      next
    end
    res = Net::HTTP.get(URI(file.url))
    if res.size != file.size
      msg << "Didn't update #{verbatim("#{filename}.py")}: File is corrupt.\n"
      no << filename
      next
    end

    # Update file
    path = File.join(File.dirname(PATH_NTRACE), "#{filename}.py")
    old_date = File.mtime(path) rescue nil
    old_size = File.size(path) rescue nil
    File.binwrite(path, res)
    new_date = File.mtime(path) rescue nil
    new_size = File.size(path) rescue nil
    msg << (new_date.nil? ? "Failed to update #{verbatim("#{filename}.py")}." : "Updated #{verbatim("#{filename}.py")} successfully.")
    versions = ''
    versions << "Old version: #{old_date.strftime('%Y/%m/%d %H:%M:%S')} (#{old_size} bytes)\n" if !old_date.nil?
    versions << "New version: #{new_date.strftime('%Y/%m/%d %H:%M:%S')} (#{new_size} bytes)\n" if !new_date.nil?
    msg << format_block(versions)
    yes << filename
  }
  msg << "Updated files: #{yes.map{ |fn| verbatim(fn) }.join(', ')}.\n" unless yes.empty?
  msg << "Not updated files: #{no.map{ |fn| verbatim(fn) }.join(', ')}." unless no.empty?

  event << "**ntrace update**:"
  event << msg
  Thread.new { ld("#{event.user.name} updated ntrace:\n#{msg}") }
rescue => e
  lex(e, "Error updating ntrace.", event: event)
end

# Sends a PNG graph plotting the evolution of player's scores (e.g. top20 count,
# 0th count, points...) over time.
# Currently unavailable because the db structure changed between CCS and Eddy
def send_history(event)
  event << "Function not available yet, restructuring being done (since 2020 :joy:)."
end

def identify(event)
  msg = parse_message(event)
  user = event.user.name
  nick = msg[/my name is (.*)[\.]?$/i, 1]
  perror("You have to send a message in the form #{verbatim('my name is <username>')}.") if nick.nil?

  player = parse_player(event, false, true, true, false, true)
  user = parse_user(event.user)
  user.player = player

  event << "Awesome! From now on you can omit your username and I'll look up scores for #{player.name}."
rescue => e
  lex(e, "Error identifying.", event: event)
end

def add_display_name(event)
  msg  = parse_message(event)
  name = msg[/my display name is (.*)[\.]?$/i, 1]
  perror("You need to specify some display name.") if name.nil?
  user = parse_user(event.user)
  player = user.player
  perror("I don't know what player you are yet, specify it first using #{verbatim('my name is <player name>')}.") if !player
  player.update(display_name: name)
  event << "Great, from now on #{player.name} will show up as #{name}."
rescue => e
  lex(e, "Error changing display name.", event: event)
end

def set_default_palette(event)
  msg = parse_message(event)
  palette = msg[/my palette is (.*)[\.\s]*$/i, 1]
  perror("You need to specify a palette name.") if palette.nil?
  palette = parse_palette(event, pal: palette, fallback: false)[:palette]
  user = parse_user(event.user)
  user.update(palette: palette)
  event << "Great, from now on your default screenshot palette will be #{verbatim(palette)}."
rescue => e
  lex(e, "Error setting default palette.", event: event)
end

def set_default_mappack(event)
  msg = parse_message(event)
  pack = msg[/my (?:.*?)(?:map\s*)?pack (?:.*?)is (.*)[\.\s]*$/i, 1]
  always = !!msg[/always/i]
  perror("You need to specify a mappack.") if pack.nil?
  mappack = parse_mappack(pack, explicit: true, vanilla: false)
  perror("Mappack not recognized.") if mappack.nil?
  parse_user(event.user).update(
    mappack_id:             mappack.id,
    mappack_default_always: always,
    mappack_default_dms:    true
  )
  places = always ? 'Every channel' : "DMs"
  event << "Great, from now on your default mappack will be #{verbatim(mappack.name)}. It will be used in: #{places}."
rescue => e
  lex(e, 'Error setting default mappack.')
end

def set_default_mappacks(event)
  user = parse_user(event.user)
  val = user.mappack_defaults
  user.update(mappack_defaults: !val)
  event << "From now on, mappacks #{val ? "won't" : 'will'} be used by default in their respective channels (for you)."
end

def hello(event)
  update_bot_status
  event << "Hi!"
  set_channels(event) if $channel.nil?
rescue => e
  lex(e, "Error during hello sequence.")
end

def thanks(event)
  event << "You're welcome!"
end

def faceswap(event)
  old_avatar = GlobalProperty.get_avatar
  avatars = Dir.entries(PATH_AVATARS)
               .select{ |f| File.file?(File.join(PATH_AVATARS, f)) }
               .reject{ |f| f == old_avatar}
  perror("No new avatars available!") if avatars.empty?
  new_avatar = avatars.sample
  change_avatar(new_avatar)
rescue
  perror("Failed to change avatar.")
else
  GlobalProperty.set_avatar(new_avatar)
end

def send_help2(event)
  cols = 3

  msg = "Hi! I'm **outte++**, the N++ Highscoring Bot and inne++'s evil cousin."
  msg += "I can do many tasks, like fetching **scores** and **screenshots** of any level, "
  msg += "performing **rankings** and **stats**, retrieving **lists**, "
  msg += "browsing and downloading **userlevels**, etc."
  event << msg

  commands = [
    "lotd",
    "eotw",
    "cotm",
    "userlevel",
    "rank",
    "community",
    "cleanest",
    "dirtiest",
    "ownage",
    "help",
    "random",
    "what",
    "when",
    "points",
    "spread",
    "average points",
    "average rank",
    "average lead",
    "scores",
    "total",
    "how many",
    "stats",
    "screenshot",
    "worst",
    "list",
    "missing",
    "maxable",
    "maxed",
    "level name",
    "level id",
    "analysis",
    "splits",
    "my name is",
    "my steam id is",
    "video",
    "unique holders",
    "z"
  ]

  commands.sort!
  commands.push("") until commands.size % cols == 0
  col_s = commands.size / cols
  row = commands[0..col_s - 1]
  (1..cols - 1).each{ |i| row.zip(commands[i * col_s .. (i + 1) * col_s - 1]) }
  rows = row.flatten.compact.each_slice(cols).to_a
  event << format_block(make_table(rows, "COMMAND LIST"))

end

def send_help(event)
  if (event.channel.type != 1)
    event << "Hi! I'm **outte++**, the N++ Highscoring Bot and inne++'s evil cousin. I can do many tasks, like:\n"
    event << "- Fetching **scores** and **screenshots** for any level or episode."
    event << "- Performing highscore **rankings** of many sorts."
    event << "- Elaborating varied highscoring **stats**."
    event << "- Displaying a diverse assortment of interesting highscore **lists**."
    event << "- Searching and downloading **userlevels**."
    event << "- ... and many more things.\n"
    event << "For more details and a list of commands, please DM me this question, so as to avoid spamming this channel."
    return
  end

  msg = "Hi! I'm **outte++**, the N++ Highscoring Bot and inne++'s evil cousin. The commands I understand are:\n"

  File.open('README.md').read.each_line do |line|
    line = line.gsub("\n", "")
    if line == " "
      send_message(event, content: msg)
      msg = "Commands continued...\n"
    else
      msg += "\n**#{line.gsub(/^### /, "")}**\n" if line =~ /^### /
      msg += " *#{line.gsub(/^- /, "").gsub(/\*/, "")}*\n" if line =~ /^- \*/
    end
  end

  send_message(event, content: msg)

  event << "In any of these commands, if you see '<level>', replace that with either a level/episode ID (eg. SI-A-00-00) or a level name (eg. supercomplexity)"
  event << "If you see '<tab>', you can replace that with any combination of SI/intro, S/N++, SU/ultimate, SL/legacy, ?/secret, and !/ultimate secret, or you can leave it off for overall totals."
  event << "If the command is related to a specific player, you can specify it by ending your message with 'for <username>'. Otherwise, I'll use the one you specified earlier."
rescue => e
  lex(e, "Error sending help.", event: event)
end

# Send info about current and next lotd/eotw/cotm
def send_lotd(event, type = Level)
  # Parse params
  msg = parse_message(event)
  mappack = parse_mappack(msg, parse_user(event.user), event.channel)
  type = Level if ![Level, Episode, Story].include?(type)
  ctp = mappack && mappack.code.upcase == 'CTP'
  period = type == Level ? 'day' : (type == Episode ? 'week' : 'month')
  perror("There is no #{mappack.code.upcase} #{type.to_s.downcase} of the #{period}.") if mappack && mappack.id > 1

  # Fetch lotd and time
  curr_h = GlobalProperty.get_current(type, ctp)
  next_h = GlobalProperty.get_next_update(type, ctp) - Time.now

  # Compute times
  if type == Level
    time1 = "#{(next_h / (60 * 60)).to_i} hours"
    time2 = "#{(next_h / 60).to_i - (next_h / (60 * 60)).to_i * 60} minutes"
  else
    time1 = "#{(next_h / (24 * 60 * 60)).to_i} days"
    time2 = "#{(next_h / (60 * 60)).to_i - (next_h / (24 * 60 * 60)).to_i * 24} hours"
  end

  # Send messages
  if !curr_h.nil?
    event << "The current #{ctp ? 'CTP ' : ''}#{type.to_s.downcase} of the #{period} is #{curr_h.format_name}."
    event.attach_file(send_screenshot(event, curr_h, true)[0])
  else
    event << "There is no current #{ctp ? 'CTP ' : ''}#{type.to_s.downcase} of the #{period}."
  end
  event << "I'll post a new #{ctp ? 'CTP ' : ''}#{type.to_s.downcase} of the #{period} in #{time1} and #{time2}."
rescue => e
  lex(e, "Error sending lotd/eotw/cotm info.", event: event)
end

def send_videos(event)
  videos = parse_videos(event)

  # If we have more than one video, we probably shouldn't spam the channel too hard...
  # so we'll make people be more specific unless we can narrow it down.
  if videos.length == 1
    event << videos[0].url
    return
  end

  descriptions = videos.map(&:format_description).join("\n")
  default = videos.where(challenge: ["G++", "?!"])

  # If we don't have a specific challenge to look up, we default to sending
  # one without challenges
  if default.length == 1
    # Send immediately, so the video link shows above the additional videos
    send_message(event, content: default[0].url)
    event << "\nI have some challenge videos for this level as well! You can ask for them by being more specific about challenges and authors, by saying '<challenge> video for <level>' or 'video for <level> by <author>':\n#{format_block(descriptions)}"
    return
  end

  event << "You're going to have to be more specific! I know about the following videos for this level:\n#{format_block(descriptions)}"
rescue => e
  lex(e, "Error sending videos.", event: event)
end

def send_unique_holders(event)
  ranks = Score.holders
  ranks = ranks.map{ |r, c| "#{"%02d" % r} - #{"%3d" % c}" }.join("\n")
  event << "Number of unique highscore holders by rank at #{Time.now.to_s}\n#{format_block(ranks)}"
rescue => e
  lex(e, "Error computing unique holders.", event: event)
end

# TODO: Implement a way to query next pages if there are more than 20 streams.
#       ... who are we kidding we'll never need this bahahahah.
def send_twitch(event)
  Twitch::update_twitch_streams
  streams = Twitch::active_streams

  event << "Currently active N related Twitch streams #{format_time}:"
  if streams.map{ |k, v| v.size }.sum == 0
    event << "None :shrug:"
  else
    str = ""
    streams.each{ |game, list|
      if list.size > 0
        str += "**#{game}**: #{list.size}\n"
        ss = list.take(20).map{ |stream| Twitch::format_stream(stream) }.join("\n")
        str += format_block(Twitch::table_header + "\n" + ss)
      end
    }
    event << str if !str.empty?
  end
rescue => e
  lex(e, "Error getting current Twitch N++ streams.", event: event)
end

# Add role to player (internal, for permission system, not related to Discord roles)
# Example: Add role "dmmc" for Donfuy
def add_role(event)
  assert_permissions(event)

  msg  = parse_message(event)
  user = parse_discord_user(msg)

  role = parse_term(msg)
  perror("You need to provide a role in quotes.") if role.nil?

  Role.add(user, role)
  event << "Added role \"#{role}\" to #{user.name}."
rescue => e
  lex(e, "Error adding role.", event: event)
end

# Add custom player / level alias.
# Example: Add level alias "sss" for sigma structure symphony
def add_alias(event)
  assert_permissions(event) # Only the botmaster can execute this

  msg = parse_message(event)
  aka = parse_term(msg)
  perror("You need to provide an alias in quotes.") if aka.nil?

  msg.remove!(aka)
  type = !!msg[/\blevel\b/i] ? 'level' : (!!msg[/\bplayer\b/i] ? 'player' : nil)
  perror("You need to provide an alias type: level, player.") if type.nil?

  entry = type == 'level' ? parse_highscoreable(event) : parse_player(event)
  entry.add_alias(aka)
  event << "Added alias \"#{aka}\" to #{type} #{entry.name}."
rescue => e
  lex(e, "Error adding alias.", event: event)
end

# Send custom player / level aliases.
# ("type" has to be either 'level' or 'player' for now)
def send_aliases(event, page: nil, type: nil)
  # PARSE
  reset_page = !type.nil?
  msg        = parse_message(event)
  type       = parse_alias_type(msg, type)
  page       = parse_page(msg, page, reset_page, event.message.components)
  case type
  when 'level'
    klass  = LevelAlias
    klass2 = :level
    name   = "`#{klass2.to_s.pluralize}`.`longname`"
  when 'player'
    klass  = PlayerAlias
    klass2 = :player
    name   = "`#{klass2.to_s.pluralize}`.`name`"
  else
    perror("Incorrect alias type (should be #{verbatim('player')} or #{verbatim('level')})")
  end

  # COMPUTE
  count   = klass.count.to_i
  pag     = compute_pages(count, page)
  aliases = klass.joins(klass2).order(:alias).offset(pag[:offset]).limit(PAGE_SIZE).pluck(:alias, name)

  # FORMAT
  pad     = aliases.map(&:first).map(&:length).max
  block   = aliases.map{ |a|
    name1 = pad_truncate_ellipsis(a[0], pad, 15)
    name2 = truncate_ellipsis(a[1], 35)
    "#{name1} #{name2}"
  }.join("\n")
  output  = "Aliases for #{type} names (total #{count}):\n#{format_block(block)}"

  # SEND
  view = Discordrb::Webhooks::View.new
  interaction_add_button_navigation(view, pag[:page], pag[:pages])
  interaction_add_select_menu_alias_type(view, type)
  send_message(event, content: output, components: view)
rescue => e
  lex(e, "Error fetching aliases.", event: event)
end

# Function to autogenerate screenshots of the userlevels for the dMMc contest
# in random palettes, zip them, and upload them.
def send_dmmc(event)
  assert_permissions(event, ['dmmc'])
  msg        = parse_message(event).remove('dmmcize').strip
  limit      = 30
  levels     = Userlevel.where_like('title', msg).limit(limit).to_a
  count      = levels.count
  palettes   = Userlevel::THEMES.dup
  response   = nil
  zip_buffer = Zip::OutputStream.write_buffer{ |zip|
    levels.each_with_index{ |u, i|
      if i == 0
        response = send_message(event, content: "Creating screenshot 1 of #{count}...", db: false)
      elsif i % 3 == 0
        response.edit("Creating screenshot #{i + 1} of #{count}...")
      end
      palette = palettes.sample
      zip.put_next_entry(sanitize_filename(u.author.name) + ' - ' + sanitize_filename(u.title) + '.png')
      zip.write(u.screenshot(palette))
      palettes.delete(palette)
    }
  }
  zip = zip_buffer.string
  response.delete if response
  event << "Generated and zipped #{levels.size} screenshots."
  send_file(event, zip, 'dmmc.zip', true)
rescue => e
  lex(e, "Error fetching dMMc maps.", event: event)
end

def mishnub(event)
  youmean = ["More like ", "You mean ", "Mish... oh, ", "Better known as ", "A.K.A. ", "Also known as "]
  mishu   = ["MishNUB,", "MishWho?,"]
  amirite = [" amirite", " isn't that right", " huh", " am I right or what", " amirite or amirite"]
  fellas  = [" fellas", " boys", " guys", " lads", " fellow ninjas", " friends", " ninjafarians"]
  laugh   = [" :joy:", " lmao", " hahah", " lul", " rofl", "  <:moleSmirk:336271943546306561>", " <:Kappa:237591190357278721>", " :laughing:", " rolfmao"]
  if rand < 0.05 && (event.channel.type == 1 || $last_mishu.nil? || !$last_mishu.nil? && Time.now.to_i - $last_mishu >= MISHU_COOLDOWN)
    send_message(event, db: false, content: youmean.sample + mishu.sample + amirite.sample + fellas.sample + laugh.sample)
    $last_mishu = Time.now.to_i unless event.channel.type == 1
  end
end

def robot(event)
  start  = ["No! ", "Not at all. ", "Negative. ", "By no means. ", "Most certainly not. ", "Not true. ", "Nuh uh. "]
  middle = ["I can assure you he's not", "Eddy is not a robot", "Master is very much human", "Senpai is a ningen", "Mr. E is definitely human", "Owner is definitely a hooman", "Eddy is a living human being", "Eduardo es una persona"]
  ending = [".", "!", " >:(", " (ಠ益ಠ)", " (╯°□°)╯︵ ┻━┻"]
  send_message(event, db: false, content: start.sample + middle.sample + ending.sample)
end

# Handle responses to new reactions
def respond_reaction(event)
  # Only have tasks for reactions to outte messages
  msg = event.message
  return if msg.user.id != $config['discord_client']

  return delete_message(event) if EMOJIS_TO_DELETE.include?(event.emoji.to_s)
end

# Main function that coordinates responses to commands issued in Discord
# via DMs or pings
def respond(event)
  msg = parse_message(event)
  hm = !msg[/\bhow many\b/i]

  # Divert flow to userlevel specific functions
  return respond_userlevels(event) if !!msg[/userlevel/i]

  $status[:commands] += 1

  # Exclusively global methods
  if !msg[NAME_PATTERN, 2]
    return send_rankings(event)    if msg =~ /rank/i && msg !~ /history/i && msg !~ /table/i
    return send_history(event)     if msg =~ /history/i
    return send_diff(event)        if msg =~ /\bdiff\b/i
    return send_community(event)   if msg =~ /community/i
    return send_cleanliness(event) if msg =~ /cleanest/i || msg =~ /dirtiest/i
    return send_ownages(event)     if msg =~ /ownage/i
    return send_random(event)      if msg =~ /random/i
    return send_help(event)        if msg =~ /\bhelp\b/i || msg =~ /\bcommands\b/i
    return send_help2(event)       if msg =~ /help2/i
  end

  # A single message could trigger multiple commands. To prevent this, we return
  # when the first command is triggered. Therefore, the ordering of these matters,
  # so we sort them according to certain priorities.
  #   For example, we put the ones that take level names first, since those may
  # contain many other words that could accidentally trigger commands.
  return send_query(event)           if msg =~ /\bsearch\b/i || msg =~ /\bbrowse\b/i
  return send_screenshot(event)      if msg =~ /screenshot/i
  return send_screenscores(event)    if msg =~ /screenscores/i || msg =~ /shotscores/i
  return send_scoreshot(event)       if msg =~ /scoreshot/i || msg =~ /scorescreen/i
  return send_scores(event)          if msg =~ /scores/i && !!msg[NAME_PATTERN, 2]
  return send_analysis(event)        if msg =~ /analysis/i
  return send_level_name(event)      if msg =~ /\blevel name\b/i
  return send_level_id(event)        if msg =~ /\blevel id\b/i
  return send_videos(event)          if msg =~ /\bvideo\b/i
  return send_challenges(event)      if msg =~ /\bchallenges\b/i
  return add_alias(event)            if msg =~ /\badd\s*(level|player)?\s*alias\b/i
  return send_demo_download(event)   if (msg =~ /\breplay\b/i || msg =~ /\bdemo\b/i) && msg =~ /\bdownload\b/i
  return send_download(event)        if msg =~ /\bdownload\b/i
  return send_trace(event)           if msg =~ /\btrace\b/i || msg =~ /\banim/i
  return send_lotd(event, Level)     if msg =~ /lotd/i
  return send_lotd(event, Episode)   if msg =~ /eotw/i
  return send_lotd(event, Story)     if msg =~ /cotm/i
  return send_table(event)           if msg =~ /\btable\b/i
  return send_average_points(event)  if msg =~ /\bpoints/i && msg =~ /average/i
  return send_points(event)          if msg =~ /\bpoints/i
  return send_spreads(event)         if msg =~ /spread/i
  return send_average_rank(event)    if msg =~ /average/i && msg =~ /rank/i && msg !~ /history/i && !!msg[NAME_PATTERN, 2]
  return send_average_lead(event)    if msg =~ /average/i && msg =~ /lead/i && msg !~ /rank/i
  return send_total_score(event)     if msg =~ /total\b/i && msg !~ /history/i && msg !~ /rank/i
  return send_maxable(event)         if msg =~ /maxable/i
  return send_maxed(event)           if msg =~ /maxed/i
  return send_tally(event)           if msg =~ /\btally\b/i
  return send_list(event, hm, true)  if msg =~ /missing/i
  return send_list(event, false)     if msg =~ /how many/i
  return send_list(event)            if msg =~ /\blist\b/i
  return send_list(event, false, false, true) if msg =~ /how cool/i
  return send_comparison(event)      if msg =~ /\bcompare\b/i || msg =~ /\bcomparison\b/i
  return send_stats(event)           if msg =~ /\bstat/i
  return send_worst(event, true)     if msg =~ /\bworst\b/i
  return send_worst(event, false)    if msg =~ /\bbest\b/i
  return send_splits(event)          if msg =~ /\bsplits\b/i
  return send_clean_one(event)       if msg =~ /cleanliness/i
  return identify(event)             if msg =~ /my name is/i
  return add_display_name(event)     if msg =~ /my display name is/i
  return set_default_palette(event)  if msg =~ /my palette is/i
  return set_default_mappack(event)  if msg =~ /my (.*?)(map\s*)?pack (.*?)is/i
  return set_default_mappacks(event) if msg =~ /use\s*default\s*(map)?\s*packs/i || msg =~ /use\s*(map)?\s*pack\s*defaults/i
  return send_unique_holders(event)  if msg =~ /\bunique holders\b/i
  return send_twitch(event)          if msg =~ /\btwitch\b/i
  return add_role(event)             if msg =~ /\badd\s*role\b/i
  return send_aliases(event)         if msg =~ /\baliases\b/i
  return send_dmmc(event)            if msg =~ /\bdmmcize\b/i
  return update_ntrace(event)        if msg =~ /\bupdate\s*ntrace\b/i
  return faceswap(event)             if msg =~ /faceswap/i
  return send_mappacks(event)        if msg =~ /mappacks/i
  return hello(event)                if msg =~ /\bhello\b/i || msg =~ /\bhi\b/i
  return thanks(event)               if msg =~ /\bthank you\b/i || msg =~ /\bthanks\b/i

  # If we get to this point, no command was executed
  $status[:commands] -= 1
  event << "Sorry, I didn't understand your command."
end
