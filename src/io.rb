# This file contains the functions that handle a lot of the specific I/O,
# like parsing (player names, level names...) and formatting (level names,
# sending files...)

require 'active_support/core_ext/integer/inflections' # ordinalize

require_relative 'constants.rb'
require_relative 'utils.rb'
require_relative 'models.rb'

# Fetch message from an event. Depending on the event that was triggered, this
# may accessed and handled in a different way.
def parse_message(event, clean: true)
  # Integrity checks
  is_message   = event.is_a?(Discordrb::Events::MessageEvent)
  is_component = event.is_a?(Discordrb::Events::ComponentEvent)
  is_reaction  = event.is_a?(Discordrb::Events::ReactionEvent)
  raise "Cannot parse message from a #{event.class.to_s}." if !is_message && !is_component && !is_reaction

  # Extract message
  msg = event.message.content
  msg = msg.gsub(/```.*```/m, '') if !is_message && clean # Exclude text blocks

  msg
end

# This is used mainly for page navigation. We determine the current page,
# and we also determine whether we need to add an offset to it (to navigate)
# or reset it (when a different component, e.g. a select menu, was activated).
def parse_page(msg, offset = 0, reset = false, components = nil)
  return 1 if reset
  page = nil
  components.to_a.each{ |row|
    row.each{ |component|
      page = component.label.to_s[/\d+/i].to_i if component.custom_id.to_s == 'button:nav:page'
    }
  }
  (page || msg[/page:?[\s\*]*(\d+)/i, 1] || 1).to_i + offset.to_i
rescue
  1
end

# Get an emoji from a button given the label
def get_emoji(event, label)
  emoji = nil
  event.message.components.each{ |row|
    row.each{ |c|
      emoji = c.emoji.name if c.custom_id == label
    }
  }
  event.message.components.first.to_a[2].emoji.name
rescue
  nil
end

# Given an amount and a page number, will make sure that it is a valid
# page number (given the page size), or clamp it otherwise, as well as
# find the offset index where the page begins.
def compute_pages(count = 1, page = 1, pagesize = PAGE_SIZE)
  pages  = [(count.to_f / pagesize).ceil, 1].max
  page   = page > pages ? pages : (page < 1 ? 1 : page)
  offset = (page - 1) * pagesize
  { page: page, pages: pages, offset: offset }
end

# Given a list, page through it by sending messages to Discord with only
# a page of it (of given offset and length), together with buttons to
# navigate the pages interactively.
def pager(event, page, header: "Results", list: [], size: PAGE_SIZE, rails: true, pluck: [])
  # Format header
  page = parse_page(parse_message(event), page, false, event.message.components)
  pag = compute_pages(list.count, page)
  header << " (#{list.count} matches):"

  # Format list
  list = rails ? list.offset(pag[:offset]).limit(size) : list[pag[:offset], size]
  list = list.pluck(*pluck) if rails && !pluck.empty?
  list.map!{ |e| yield(e) } if block_given?
  list = list.join("\n")
  header << format_block(list)

  # Send message with buttons
  view = Discordrb::Webhooks::View.new
  interaction_add_button_navigation(view, pag[:page], pag[:pages]) unless pag[:pages] == 1
  send_message(event, content: header, components: view)
  perror
end

# Parse game mode from string. If explicit is set, one of the 3 modes must be
# set (defaulting to 'solo'), otherwise, it defaults to 'all', or nil if
# 'null' is true
def parse_mode(msg, explicit = false, null = false)
  !!msg[/\brace\b/i] ? 'race' : (!!msg[/\bcoop\b/i] ? 'coop' : (explicit ? 'solo' : (!!msg[/\bsolo\b/i] ? 'solo' : (null ? nil : 'all'))))
end

# Parses a string looking for a score in the usual N++ 3-decimal floating point format
def parse_score(str)
  score = str[/(\s|^)([1-9]\d*|0)(\.\d{1,3})?(\s|$)/]
  perror("Couldn't find / understand the score") if score.nil?
  perror("The score is incorrect") if !verify_score(score.to_f)
  score.to_f
end

# Parse the highscoreable type (Level/Episode/Story) from a message
def parse_type(
    msg,             # Text to parse type from
    type:     nil,   # Initial type we might send
    multiple: false, # Whether to allow multiple types and return and array
    initial:  false, # Whether this is the first call to the function
    default:  nil    # Default types when none is found
  )
  # Sanitize default type
  if !['level', 'episode', 'story'].include?(default.to_s.downcase)
    default = nil
  else
    default = default.to_s.capitalize.constantize
  end

  # First, parse the parameter we sent
  type = type.to_s.capitalize.constantize unless type.nil?
  return type if !multiple && ['level', 'episode', 'story'].include?(type.to_s.downcase)

  # If it's not correct, then parse message
  ret = []
  multiple ? ret << Level   : (return Level)   if !!msg[/\blevels?\b/i] || !!msg[/lotd/i]
  multiple ? ret << Episode : (return Episode) if !!msg[/\bepisodes?\b/i] || !!msg[/eotw/i]
  multiple ? ret << Story   : (return Story)   if !!msg[/\bstory\b/i] || !!msg[/\bstories\b/i] || !!msg[/\bcolumn?\b/i] || !!msg[/\bhard\s*core\b/i] || !!msg[/\bhc\b/i] || !!msg[/cotm/i]

  if multiple
    # If still empty (and initial), push default types
    if initial && ret.empty?
      default.nil? ? ret.push(*DEFAULT_TYPES.map(&:constantize)) : ret.push(default)
    end

    # If "overall" is matched, push default types too
    if !!msg[/\boverall\b/i]
      ret.push(*DEFAULT_TYPES.map(&:constantize))
    end

    # Also, toggle the type we sent (add or remove) (see rankings navigation)
    ret.include?(type) ? ret.delete(type) : ret.push(type) if !type.nil?
    ret.uniq!
  else
    # If not multiple, we return either the default we sent, or nil (type not found)
    ret = default
  end

  ret
end

def parse_alias_type(msg, type = nil)
  ['level', 'player'].include?(type) ? type : (!!msg[/player/i] ? 'player' : 'level')
end

# Transform tab into [SI, S, SU, SL, ?, !] format
def normalize_tab(tab)
  format_tab(parse_tabs(tab)[0])
end

# Transform tab into [SI, S, SU, SL, SS, SS2] format
def formalize_tab(tab)
  parse_tabs(tab)[0].to_s
end

# Normalize the name (ID) of a highscoreable, by:
# 1) Adding missing dashes
# 2) Adding padding 0's
# 3) Capitalizing all letters
def normalize_name(name)
  return name.to_s if !name.is_a?(String) && !name.is_a?(MatchData)
  name = name.captures.compact.join('-') if name.is_a?(MatchData)
  name.split('-').map { |s| s[/\A[0-9]\Z/].nil? ? s : "0#{s}" }.join('-').upcase
rescue
  name.to_s
end

# The following are 2 auxiliary functions for the next ones
#   Parse a single player when a name has been provided
def parse_player_explicit(name, userlevel = false)
  return nil if name.strip.empty?

  # Check if player with this name exists
  player = (userlevel ? UserlevelPlayer : Player).where.not(metanet_id: nil).find_by(name: name)
  return player if player

  # Check if player with this alias exists
  if !userlevel
    player = Player.joins('INNER JOIN player_aliases ON players.id = player_aliases.player_id')
                   .where(["player_aliases.alias = ?", name])
                   .take
    return player if player
  end

  # No results
  perror("#{name} doesn't have any high scores! Either you misspelled the name / alias, or they're exceptionally bad...")
end

#   Parse a single player when a username has been provided
def parse_player_implicit(event, userlevel = false)
  username = event.user.name

  # Check if the user is identified
  user = User.find_by(discord_id: event.user.id)
  return user.player(userlevel: userlevel) if user && user.player

  # Check if player with same username exists
  player = (userlevel ? UserlevelPlayer : Player).where.not(metanet_id: nil).find_by(name: username)
  return player if player

  # No results
  perror("I couldn't find a player with your username! Have you identified yourself (with '@outte++ my name is <N++ display name>')?")
end

# Fetch a Player or UserlevelPlayer from a text string.
# Optionally may also infer the player from the username.
# TODO: Change args to kwargs
def parse_player(
    event,             # Originating event (contains text, user...)
    userlevel = false, # Whether to search in for userlevel players or regular ones
    explicit  = false, # Only parse explicit names, without inferring from username
    enforce   = false, # Even more, raise exception if no explicit name found
    implicit  = false, # The opposite, only infer from username
    third     = false, # Allow 3rd person specification (e.g. "is xela" rather than "for xela")
    flag:     nil      # For special commands, flag that will contain the player name
  )
  msg = parse_message(event).gsub(/"/, '')
  p = flag ? parse_flags(msg)[flag.to_sym].to_s : msg[/(for|of#{third ? '|is' : ''}) (.*)[\.\?]?/i, 2]

  return parse_player_implicit(event, userlevel) if implicit
  return parse_player_explicit(p, userlevel)     if p
  return parse_player_implicit(event, userlevel) if !explicit
  perror("You need to specify a player name.")   if enforce

  nil
end

# Parse a pair of players. The user may provide 0, 1 or 2 names in different
# formats, so we act accordingly and reuse the previous method.
def parse_players(event, userlevel = false)
  msg = parse_message(event)
  p = parse_term(msg, global: true)
  case p.size
  when 0
    p1 = parse_player(event, userlevel, true, true, false)
    p2 = parse_player(event, userlevel, false, false, true)
  when 1
    p1 = parse_player_explicit(p[0], userlevel)
    p2 = parse_player(event, userlevel, false, false, true)
  when 2
    p1 = parse_player_explicit(p[0], userlevel)
    p2 = parse_player_explicit(p[1], userlevel)
  else
    perror("Too many players! Please enter either 1 or 2.")
  end
  [p1, p2]
end

def parse_many_players(msg, userlevel = false)
  msg = msg[/without (.*)/i, 1] || ""
  players = msg.split(/,|\band\b|\bor\b/i).flatten.map(&:strip).reject(&:empty?)
  players.map{ |name| parse_player_explicit(name) }
end

# Parse a User object from a Discord::User object
def parse_user(discord_user)
  user = User.find_or_create_by(discord_id: discord_user.id)
  user.update(name: discord_user.name)
  user
end

# The username can include the tag after a hash
def parse_discord_user(msg)
  user = msg[NAME_PATTERN, 2].downcase
  perror("You need to provide a user.") if user.nil?

  parts = user.split('#')
  users = find_users(name: parts[0], tag: parts[1])
  case users.size
  when 0
    perror("No user named #{user} found in the server.")
  when 1
    return users.first
  else
    list = users.map{ |u| [u.name, u.tag.to_i, u.joined_at] }
                .sort_by{ |u| [u[2], u[1]] }
                .map{ |u| u[0] + '#' + u[1].to_s.ljust(4) + ' ' + u[2].strftime('%Y/%m/%d') }
                .join("\n")
    perror("Multiple users named #{parts[0]} found, please include the numerical tag as well:\n#{format_block(list)}")
  end
end

def parse_video_author(msg)
  return msg[/by (.*)[\.\?]?\Z/i, 1]
end

def parse_challenge(msg)
  return msg[/([GTOCE][+-][+-])+/]
end

def parse_challenge_code(msg)
  return msg[/([!?]+)[^-]/, 1]
end

def parse_videos(event)
  msg = parse_message(event)
  author = parse_video_author(msg)
  msg = msg.chomp(" by " + author.to_s)
  highscoreable = parse_highscoreable(event)
  challenge = parse_challenge(msg)
  code = parse_challenge_code(msg)
  videos = highscoreable.videos

  videos = videos.where('lower(author) = ? or lower(author_tag) = ?', author.downcase, author.downcase) unless author.nil?
  videos = videos.where(challenge: challenge) unless challenge.nil?
  videos = videos.where(challenge_code: code) unless code.nil?

  perror("That level doesn't have any videos!") if highscoreable.videos.empty?
  perror("I couldn't find any videos matching that request! Are you looking for one of these videos?\n#{format_block(highscoreable.videos.map(&:format_description).join("\n"))}") if videos.empty?
  return videos
end

def parse_steam_id(msg)
  id = msg[/is (.*)[\.\?]?/i, 1]
  perror("I couldn't figure out what your Steam ID was! You need to send a message in the format 'my steam id is <id>'.") if id.nil?
  perror("Your Steam ID needs to be numerical! #{id} is not valid.") if id !~ /\A\d+\Z/
  return id
end

# Parse a highscoreable by ID (e.g. SU-D-17-03) with a specific set of parameters
# Optionally provide a user for specific preferences
def parse_h_by_id_once(
    msg,            # Text to parse the ID from
    user    = nil,  # User to parse specific preferences
    channel = nil,  # Discord channel
    matches = [],   # Array to add the _normalized_ ID if found
    type:    Level, # Type of highscoreable ID
    vanilla: true,  # Whether to look for mappack IDs or regular ones
    mappack: false, # Whether we allow mappacks or not
    dashed:  true   # Strict dashed IDs vs optionally-dashed IDs
  )
  # Parse selected pattern
  packing = vanilla ? :vanilla : :mappack
  dashing = dashed ? :dashed : :dashless
  pattern = ID_PATTERNS[type.to_s][packing][dashing]

  # Match pattern
  match = msg.match(pattern)
  return ['', []] if match.nil?

  # Format name
  pack = parse_mappack(msg, user, channel)
  str = normalize_name(match)
  matches << str
  code = pack ? pack.code.upcase : 'MET'
  str.prepend(code + '-') if vanilla && mappack

  # Find highscoreable
  klass = mappack ? type.mappack : type
  res = klass.find_by(name: str)
  res ? ["Single match found for #{match}", [res]] : ['', []]
rescue
  ['', []]
end

# Parse a highscoreable based on the ID:
# 1) First we check dashed versions for levels and episodes
# 2) Then dashless for levels and episodes
#     (Thus SU-A-10 will be parsed as the episode, not as the level SU-A-1-0
#      missing some dashes, and SUA15 will be parsed as the episode SU-A-15,
#      even though it also fits the dashless level SU-A-1-5, because no such
#      level exists).
# 3) Then parse columns (no ambiguity as they don't have row letter).
def parse_highscoreable_by_id(msg, user = nil, channel = nil, mappack: false)
  ret = ['', []]

  # Mappack variants, if allowed
  matches = []
  if mappack
    ret = parse_h_by_id_once(msg, user, channel, matches, type: Level,   mappack: true, vanilla: false, dashed: true)  if ret[1].empty?
    ret = parse_h_by_id_once(msg, user, channel, matches, type: Episode, mappack: true, vanilla: false, dashed: true)  if ret[1].empty?
    ret = parse_h_by_id_once(msg, user, channel, matches, type: Level,   mappack: true, vanilla: false, dashed: false) if ret[1].empty?
    ret = parse_h_by_id_once(msg, user, channel, matches, type: Episode, mappack: true, vanilla: false, dashed: false) if ret[1].empty?
    ret = parse_h_by_id_once(msg, user, channel, matches, type: Story,   mappack: true, vanilla: false, dashed: true)  if ret[1].empty?

    # If there were ID matches, but they didn't exist, raise
    if ret[1].empty? && matches.size > 0
      ids = matches.uniq.map{ |m| verbatim(m) }.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')
      perror("There is no mappack level/episode/story by the #{'ID'.pluralize(matches.size)}: #{ids}.")
    end
  end

  # Vanilla variants
  matches = []
  ret = parse_h_by_id_once(msg, user, channel, matches, type: Level,   mappack: mappack, vanilla: true, dashed: true)  if ret[1].empty?
  ret = parse_h_by_id_once(msg, user, channel, matches, type: Episode, mappack: mappack, vanilla: true, dashed: true)  if ret[1].empty?
  ret = parse_h_by_id_once(msg, user, channel, matches, type: Level,   mappack: mappack, vanilla: true, dashed: false) if ret[1].empty?
  ret = parse_h_by_id_once(msg, user, channel, matches, type: Episode, mappack: mappack, vanilla: true, dashed: false) if ret[1].empty?
  ret = parse_h_by_id_once(msg, user, channel, matches, type: Story,   mappack: mappack, vanilla: true, dashed: true)  if ret[1].empty?

  # If there were ID matches, but they didn't exist, raise
  if ret[1].empty? && matches.size > 0
    ids = matches.uniq.map{ |m| verbatim(m) }.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')
    perror("There is no level/episode/story by the #{'ID'.pluralize(matches.size)}: #{ids}.")
  end

  ret
rescue
  ['', []]
end

# Parse a highscoreable based on a "code" (e.g. lotd/eotw/cotm)
def parse_highscoreable_by_code(msg, user = nil, channel = nil, mappack: false)
  # Parse type
  lotd = !!msg[/(level of the day|lotd)/i]
  eotw = !!msg[/(episode of the week|eotw)/i]
  cotm = !!msg[/(column of the month|cotm)/i]
  return ['', []] if !lotd && !eotw && !cotm

  klass = lotd ? Level : eotw ? Episode : Story
  type = lotd ? 'level of the day' : eotw ? 'episode of the week' : 'column of the month'

  # Parse mappack (manually specified and default one)
  pack = mappack ? parse_mappack(msg, user, channel) : nil
  ctp = pack && pack.code.upcase == 'CTP'
  type.prepend(pack.code.upcase + ' ') unless pack.code.upcase == 'MET' if pack
  perror("There is no #{type}.") if pack && !pack.lotd

  # Fetch lotd/eotw/cotm
  ret = GlobalProperty.get_current(klass, ctp)
  perror("There is no current #{type}.") if ret.nil?

  ret ? ["Single match found", [ret]] : ['', []]
rescue
  ['', []]
end

# Parse a highscoreable based on the name
# 'mappack' specifies whether searching for mappack highscoreables is allowed, not enforced
def parse_highscoreable_by_name(msg, user = nil, channel = nil, mappack: true)
  pack = mappack ? parse_mappack(msg, user, channel) : nil
  klass = pack && pack.id != 0 ? MappackLevel.where(mappack: pack) : Level
  pack = pack && pack.id != 0 ? pack.code.upcase + ' ' : 'MET '
  name = msg.split("\n")[0][/(?:for|of) (.*)/i, 1].tr('"`:', '').strip
  return ['', []] if name.empty?

  # Exact name match
  ret = ['', klass.where_like('longname', name, partial: false).to_a]
  ret[0] = "Single #{pack}name match found for #{verbatim(name)}:" if ret[1].size == 1
  ret[0] = "Multiple #{pack}name matches found for #{verbatim(name)}" if ret[1].size > 1
  return ret if !ret[1].empty?

  # Exact alias match
  query = klass.joins("INNER JOIN level_aliases ON #{klass.table_name}.id = level_id")
  ret = ['', query.where_like('alias', name, partial: false).to_a]
  ret[0] = "Single #{pack}alias match found for #{verbatim(name)}:" if ret[1].size == 1
  ret[0] = "Multiple #{pack}alias matches found for #{verbatim(name)}:" if ret[1].size > 1
  return ret if !ret[1].empty?

  # Partial name match
  ret = ['', klass.where_like('longname', name, partial: true).to_a]
  ret[0] = "Single partial #{pack}name match found for #{verbatim(name)}:" if ret[1].size == 1
  ret[0] = "Multiple partial #{pack}name matches found for #{verbatim(name)}:" if ret[1].size > 1
  return ret if !ret[1].empty?

  # Closest matches
  list = klass.all.pluck(:name, :longname)
  matches = string_distance_list_mixed(name, list)
  ret = [
    "No #{pack}matches found for #{verbatim(name)}. Did you mean...",
    matches.map{ |m| klass.find_by(name: m[0]) }
  ]
  return ret if !ret[1].empty?

  perror("No #{pack}matches found for #{verbatim(name)}.")
rescue
  ['', []]
end

# TODO:
# - Add QueryResult class that handles keeping track of the results,
#       formatting them, etc. Adjust functions and comments accordingly.

# Parse a highscoreable (Level, Episode, Story, or the corresponding Mappack ones)
# Returns it if a single result is found, or prints the list if multiple (see params).
def parse_highscoreable(
    event,          # Event whose content contains the highscoreable to parse
    list:    false, # Force to print list, even if there's a single match
    mappack: false, # Search mappack highscoreables as well
    page:    0,     # Page offset when navigating list of matches
    vanilla: true,  # Don't return Metanet highscoreables as MappackHighscoreable
    map:     false  # Force Metanet highscoreables to MappackHighscoreable
  )
  msg = parse_message(event)
  user = parse_user(event.user)
  channel = event.channel
  perror("Couldn't find the level, episode or story you were looking for :(") if msg.to_s.strip.empty?
  pack = mappack ? parse_mappack(msg, user, channel) : nil
  ret = ['', []]

  # Search for highscoreable according to different criteria
  ret = parse_highscoreable_by_id(msg, user, channel, mappack: mappack)
  ret = parse_highscoreable_by_code(msg, user, channel, mappack: mappack) if ret[1].empty?
  ret = parse_highscoreable_by_name(msg, user, channel, mappack: mappack) if ret[1].empty?

  # No results
  pack_str = pack && pack.id != 0 ? pack.code.upcase + ' ' : ''
  if ret[1].empty?
    if list
      perror("No #{pack_str}results found.")
    else
      perror("Couldn't find the #{pack_str}level, episode or story you were looking for :(")
    end
  end

  # Transform to vanilla or map if appropriate
  ret[1].map!{ |m| m.vanilla } if vanilla
  ret[1].map!{ |m| m.map } if map

  # Return single highscoreable or print list of results
  if !list && ret[1].size == 1
    return ret[1].first
  else
    format_level_matches(event, msg, page, ret, 'results')
  end
rescue => e
  lex(e, 'Failed to parse highscoreable')
  nil
end

def parse_rank(msg)
  rank = msg[/top\s*([0-9][0-9]?)/i, 1]
  rank ? rank.to_i.clamp(1, 20) : nil
end

def parse_bottom_rank(msg)
  rank = msg[/bottom\s*([0-9][0-9]?)/i, 1]
  rank ? (20 - rank.to_i).clamp(0, 19) : nil
end

def parse_ranks(msg, clamp = 20)
  ranks = msg.scan(/(?<=\s|^|$)\d{1,3}(?=\s|^|$)/).map(&:to_i)
  ranks.map!{ |r| r.clamp(0, clamp - 1) } unless clamp <= 0
  ranks.uniq!
  ranks.empty? ? [0] : ranks
end

def parse_nav(msg)
  !!msg[/\bnav((igat)((e)|(ing)))?\b/i]
end

def parse_offline(msg)
  !!msg[/\boffline\b/i]
end

def parse_maxed(msg)
  !!msg[/\bmaxed\b/i]
end

def parse_maxable(msg)
  !!msg[/\bmaxable\b/i]
end

# Parse a mappack explicitly from a message, or implicitly from the user or
# channel defaults
# explicit - Disables implicit parsing
# vanilla  - Converts Metanet mappack to nil (i.e. no mappack)
def parse_mappack(msg, user = nil, channel = nil, explicit: false, vanilla: true)
  # Init params
  text = msg && !msg.strip.empty?
  term = parse_term(msg, quoted: [], final: ['for'])
  mappack = nil

  # Parse mappack explicitly in different ways
  mappack = Mappack.find_by(name: msg.strip[/\w+/i])         if text
  mappack = Mappack.find_by(name: term)                      if text && !mappack
  mappack = Mappack.find_by(code: msg.scan(/\b[A-Z]{3}\b/i)) if text && !mappack

  # Parse mappack implicitly
  mappack = default_mappack(user, channel) if !mappack && !explicit

  # Convert to vanilla if Metanet
  mappack = nil if vanilla && mappack && mappack.id == 0

  mappack
rescue
  nil
end

# We parse a complex variety of ranges here, from individual ranks, to tops,
# bottoms, intermediate ranges, etc.
# 'full' means that if no range has been explicitly provided, then we default
# to 0th-19th, otherwise we default to 0th-1st.
def parse_range(msg, full = false)
  # Parse "topX" and "bottomX"
  rank = parse_rank(msg) || 20
  bott = parse_bottom_rank(msg) || 0
  # Parse up to 2 individual ranks (e.g. 2nd, 7th...)
  inds = msg.scan(/\b[0-9][0-9]?(?:st|nd|rd|th)\b/i)
            .map{ |r| r.to_i.clamp(0, 20) }
            .uniq
            .sort
            .take(2)
  # If there's only 1 individual rank, the interval has width 1
  inds.push(inds.first) if inds.size == 1
  # Figure out if we need to default
  dflt = parse_rank(msg).nil? && parse_bottom_rank(msg).nil?

  # If no range is provided, default to 0th count
  if dflt
    if full
      bott = 0
      rank = 20
    else
      bott = 0
      rank = 1
    end
  end

  # If an individual rank is provided, the range has width 1
  if !inds.empty?
    bott = inds[0].clamp(0, 19)
    rank = (inds[1] + 1).clamp(1, 20)
  end

  [bott, rank, bott < rank]
end

# Parse a message for tabs
# If 'tab' is passed, we're in a select menu, and we
# include either one tab or none (all)
def parse_tabs(msg, tab = nil)
  if !tab.nil?
    if ['si', 's', 'su', 'sl', 'ss', 'ss2'].include?(tab)
      [tab.upcase.to_sym]
    else
      []
    end
  else
    ret = []
    ret << :SI  if msg =~ /\b(intro|SI)\b/i
    ret << :S   if msg =~ /(\b|\A|\s)(N++|S|solo)(\b|\Z|\s)/i
    ret << :SU  if msg =~ /\b(SU|UE|ultimate)\b/i
    ret << :SL  if msg =~ /\b(legacy|SL)\b/i
    ret << :SS  if msg =~ /(\A|\s)(secret|\?)(\Z|\s)/i
    ret << :SS2 if msg =~ /(\A|\s)(ultimate secret|!)(\Z|\s)/i
    ret.size == 6 ? [] : ret
  end
end

# Ranking type
def parse_rtype(msg)
  if !!msg[/average/i] && !!msg[/point/i]
    'average_point'
  elsif !!msg[/average/i] && !!msg[/lead/i]
    'average_top1_lead'
  elsif !!msg[/average/i]
    'average_rank'
  elsif !!msg[/point/i]
    'point'
  elsif !!msg[/\bscore/i]
    'score'
  elsif parse_singular(msg) == 1
    'singular_top1'
  elsif parse_singular(msg) == -1
    'plural_top1'
  elsif !!msg[/tied/i]
    'tied_top1'
  elsif parse_maxed(msg)
    'maxed'
  elsif parse_maxable(msg)
    'maxable'
  elsif parse_cool(msg)
    'cool'
  elsif parse_star(msg)
    'star'
  elsif parse_gp(msg)
    'G++'
  elsif parse_gm(msg)
    'G--'
  else
    'top'
  end
end

# Complete rtype with additional rank info
def fix_rtype(rtype, rank)
  rtype += rank.to_s if rtype == 'top'
  rtype
end

# Regex to determine the field to order by in userlevel searches
# Order may be inverted by specifying a "-" before, or a "desc" after, or both
# It then modifies the original message to remove the order query part
def parse_order(msg, order = nil)
  regex  = /(order|sort)(ed)?\s*by\s*((\w|\+|-)*)\s*(asc|desc)?/i
  order  = order || msg[regex, 3] || ""
  desc   = msg[regex, 5] == "desc"
  invert = (order.strip[/\A-*/i].length % 2 == 1) ^ desc
  order.delete!("-")
  msg.remove!(regex)
  { msg: msg, order: order, invert: invert }
end

# Parse a quoted term from a string. Features:
# - Can handle quotes themselves, if they're escaped
# - An array of prefixes to match before the quoted term (can also be a single string)
# - Robust, never raises exceptions, always returns a string
# - Also supports a mode to match everything after the prefix, or even both
#   (in which case, the quoted match takes preference)
# 'quoted' contains the array of prefixes for quoted terms, can be empty
# 'final'  contains the array of prefixes for general matches, cannot be empty
# 'global' returns an array with all matches, rather than only the first
#          (only valid for quoted parses)
# 'remove' returns an array with the match, and the msg with the match removed
def parse_term(str, quoted: nil, final: nil, global: false, remove: false)
  return (remove ? ['', str] : '') if !str.is_a?(String) || str.strip.empty?
  final = nil if global
  prefix = [
    regexize_words(quoted),
    regexize_words(final)
  ]
  regex = [
    /#{prefix[0]}\s*"((?:(?:\\.)|[^\\"])*)"/i,
    /#{prefix[1]}\s+(.*)/i
  ]
  str.gsub!(/["“”`´]/, '"')
  if global
    matches = str.scan(regex[0]).map(&:first)
    return (remove ? [matches, str.remove(regex[0])] : matches)
  end
  match = [
    str[regex[0], 1],
    (str[regex[1], 1] unless prefix[1].empty?).to_s.strip
  ]
  c = !quoted.nil? && !final.nil? ? (!match[0].nil? ? 0 : 1) : (quoted.nil? && !final.nil? ? 1 : 0)
  remove ? [match[c].to_s, str.remove(regex[c])] : match[c].to_s
rescue
  remove ? ['', str] : ''
end

# Parses a term:
#   1) First quoted, and if found, returned
#   2) Then unquoted, and if found:
#   2.1) If it's a number, it's assumed to be an ID, casted to int and returned
#   2.2) Otherwise, assumed to be a string, returned
def parse_string_or_id(msg, quoted: nil, final: nil, remove: false)
  name, msg = parse_term(msg, quoted: quoted, remove: true)
  return (remove ? [name, msg] : name) if !name.empty?
  name, msg = parse_term(msg, final: final, remove: true)
  name = name.strip.to_i if is_num(name)
  return (remove ? [name, msg] : name)
rescue
  remove ? ['', msg] : ''
end

# Parse userlevel author from a message. Might return a string if a name is found,
# or an integer if an ID is found.
def parse_userlevel_author(msg, remove: false)
  name, msg = parse_term(msg, quoted: ['author id'], remove: true)
  if !name.empty? && is_num(name)
    name = name.strip.to_i
  else
    name, msg = parse_string_or_id(msg, quoted: ['by', 'author'], final: ['by'], remove: true)
    name.strip! if name.is_a?(String)
  end
  remove ? [name, msg] : name
rescue
  remove ? ['', msg] : ''
end

# Parse userlevel title from a message. Might return a string if a name is found,
# or an integer if an ID is found.
# Also, if 'full' is true, when a name is found the entire msg will be considered the name
def parse_userlevel_title(msg, remove: false, full: true)
  name, msg = parse_string_or_id(msg, quoted: ['for', 'of', 'title'], final: ['for', 'of'], remove: true)
  name.strip! if name.is_a?(String)
  if name.is_a?(String) && name.empty? && full
    name, msg = msg, ''
    name = name.strip.to_i if is_num(name)
  end
  remove ? [name, msg] : name
rescue
  remove ? ['', msg] : ''
end

# Same as above, but using both prepositions
def parse_userlevel_both(msg, remove: false, full: false)
  name, msg = parse_string_or_id(msg, quoted: ['for', 'by', 'author'], final: ['for', 'by'], remove: true)
  name.strip! if name.is_a?(String)
  if name.is_a?(String) && name.empty? && full
    name, msg = msg, ''
    name = name.strip.to_i if is_num(name)
  end
  remove ? [name, msg] : name
rescue
  remove ? ['', msg] : ''
end

# TODO: Adapt all uses of "author" in userlevels.rb to the new system, both when
# using the author directly, as well as when calling one of the functions from io.rb
# that have changed (parse_title_and_author, parse_userlevel, etc).

# The following function is supposed to modify the message!
#
# Supports querying for both titles and author names. If both are present, at
# least one should go in quotes, to distinguish between them (it will still work
# without quotes if the author comes before the name). The one without
# quotes must go at the end, so that everything after the particle is taken to
# be the title/author name.
#
# 'full' allows for the title to default to the whole msg if no prefix is found
def parse_title_and_author(msg, full = true)
  author, msg = parse_userlevel_author(msg, remove: true)
  title, msg = parse_userlevel_title(msg, remove: true, full: full) # Keep last! (title can be whole msg if no "for" is found)
  [title, author, msg]
end

def parse_author(event, rais = true)
  UserlevelAuthor.parse(parse_userlevel_author(parse_message(event)), event: event)
rescue
  raise if rais
  nil
end

# Parse a userlevel from a message by looking for a title or an ID, as well as
# an author or author ID, optionally.
def parse_userlevel(event, userlevel = nil)
  # --- PARSE message elements

  msg = parse_message(event)
  title, author, msg = parse_title_and_author(msg, true)
  author = UserlevelAuthor.parse(author, event: event)
  if userlevel
    return {
      query:  userlevel,
      msg:    '',
      count:  1,
      title:  userlevel.title.to_s,
      author: userlevel.author.name.to_s
    }
  end

  # --- FETCH userlevel(s)
  query = Userlevel
  err   = ""
  count = 0

  # TODO: Use this code for the userlevel_browse function too, perhaps abstract

  if title.is_a?(Integer)
    query = Userlevel.where(id: title)
    err = "No userlevel with ID #{verbatim(title)} found."
  else
    errs = []
    if !title.empty?
      query = query.where_like('title', title[0...128])
      errs << "with title #{verbatim(title[0...128])}"
    end
    if !author.nil?
      query = query.where(author: author)
      errs << "by author #{verbatim(author.name)}"
    end
    err = "No userlevel #{errs.join(' ')} found."
  end

  # --- Prepare return depending on map count
  ret   = ""
  count = query.count
  author = author.name if author.is_a?(UserlevelAuthor)
  case count
  when 0
    ret = err
  when 1
    query = query.first
  else
    ret = "Multiple matching maps found. Please refine terms or use the userlevel ID:"
  end
  { query: query, msg: ret, count: count, title: title.to_s, author: author.to_s }
end

# The palette may or may not be quoted, but it MUST go at the end of the command
# if it's not quoted. Only look in 'pal' if not nil. 'fallback' will default
# to the default palette if no good matches, otherwise exception.
def parse_palette(event, dflt = Map::DEFAULT_PALETTE, pal: nil, fallback: true)
  msg = parse_message(event)
  err = ""
  pal.strip! if !pal.nil?

  # Parse message for explicit palette specification
  pal, msg = parse_term(msg, quoted: ['palette'], final: ['palette'], remove: true) if pal.nil?
  ret = { msg: msg, palette: pal, error: err }

  if !ret[:palette].empty?
    themes = Map::THEMES.map(&:downcase)

    # If no perfect matches
    if !themes.include?(ret[:palette].downcase)
      # Look for partial matches
      matches = themes.select{ |t| !!t[/#{pal}/i] }
      if matches.size == 1
        ret[:palette] = matches.first
        return ret
      end
      match_limit = 10
      perror("Multiple matches found for palette #{verbatim(ret[:palette])}#{matches.size > match_limit ? " (#{matches.size} matches, showing #{match_limit})" : ''}:\n#{format_block(matches.take(match_limit).join("\n"))}") if matches.size > 0

      # Look for approximate matches
      matches = string_distance_list_mixed(ret[:palette].downcase, themes.each_with_index.to_a.map(&:reverse)).map(&:last)
      if matches.size == 1
        ret[:palette] = matches.first
        return ret
      end
      perror("No matches found for palette #{verbatim(ret[:palette])}. Did you mean...\n#{format_block(matches.join("\n"))}") if matches.size > 0

      # No matches whatsoever
      perror("No good matches for palette #{verbatim(ret[:palette])} found.") if !fallback
      err = "No good matches for palette #{verbatim(ret[:palette])} found, using default instead."
      pal = ''
    end
  end

  # Fall back to default if no explicit palette
  if pal.empty?
    p = parse_user(event.user).palette rescue nil
    pal = p || dflt
  end

  err += "\n" if !err.empty?
  { msg: msg, palette: pal, error: err }
rescue => e
  lex(e, 'Failed to parse palette')
end

def parse_global(msg)
  DEFAULT_GLOBAL ? !msg[/\bnewest\b/i] : !!msg[/\bglobal\b/i]
end

def parse_full(msg)
  !!msg[/full/i]
end

def parse_ties(msg, rtype = nil)
  !rtype.nil? && rtype[-2..-1] == '_t' || !!msg[/\bties\b/i]
end

def parse_tied(msg)
  !!msg[/\btied\b/i]
end

def parse_singular(msg)
  if !!msg[/\bsingular\b/i]
    1
  elsif !!msg[/\bplural\b/i]
    -1
  else
    0
  end
end

def parse_gm(msg)
  !!msg[/\bG--/i] || !!msg[/\bng\b/i]
end

def parse_gp(msg)
  !!msg[/\bG\+\+/i] || !!msg[/\bag\b/i]
end

# 'strict' means the emoji must be separated from text
# intended to ignore users with it in the name
def parse_cool(msg, strict = false)
  !!msg[/\bcool(s|(ness))?\b/i] || !!msg[/\bckc'?s?\b/i] || !!msg[/#{strict ? "(\A|\W)" : ""}😎'?s?#{strict ? "(\z|\W)" : ""}/i]
end

# see parse_cool for 'strict'
# if 'name' then we accept 'star' for parsing stars as well
def parse_star(msg, strict = false, name = false)
  !!msg[/#{strict ? "(\A|\W)" : ""}\*#{strict ? "(\z|\W)" : ""}/i] || name && !!msg[/\bstar\b/i]
end

# Parse type of leaderboard (highscore, speedrun, dual, ...)
# Second parameter determines the default
def parse_board(msg, dflt = nil, dual: false)
  return dflt if msg.to_s.empty?
  board = nil
  board = 'dual' if !!msg[/\bdual\b/i] && dual
  board = 'hs'   if !!msg[/\bhs\b/i] || !!msg[/\bhigh\s*score\b/i]
  board = 'gm'   if !!msg[/\bng\b/i] || !!msg[/\bg--(\s|$)/i]
  board = 'sr'   if !!msg[/\bsr\b/i] || !!msg[/\bspeed\s*run\b/i]
  board = dflt   if board.nil?
  board
end

# Parse arguments and flags CLI-style:
# Arg names must start with a dash and be alphanumeric (underscores allowed)
# Arg values can be anything but dashes
def parse_flags(input)
  is_event = input.is_a?(Discordrb::Events::Event)
  is_string = input.is_a?(String)
  return {} if !is_event && !is_string
  return parse_flags(remove_command(parse_message(input))) if is_event
  input.scan(/(?:\s+|^)-(\w+)(?:\s+([^-].*?))?(?=\s+-|$)/)
       .uniq{ |e| e[0] }
       .map{ |k, v| [k, v.nil? ? nil : v.squish] }
       .to_h
       .symbolize_keys
rescue
  {}
end

# Determine whether an event is initial (the first time a post gets made)
# or not (an edit, like after a button press)
def parse_initial(event)
  !event.is_a?(Discordrb::Events::ComponentEvent)
end

def format_rank(rank)
  rank.to_i == 1 ? '0th' : "top #{rank}"
end

# Formats a ranking type. These can include the range in some default cases
# (e.g. Top10 Rankings), unless the 'range' parameter is false.
# 'range' Includes the range (e.g. Top10) or not
# 'rank'  Override whatever the rank in the rtype is
# 'ties'  Adds "w/ ties" or something
# 'basic' Doesn't print words which are now parameters (e.g. cool)
def format_rtype(rtype, range: true, rank: nil, ties: false, basic: false)
  if rtype[0..2] == 'top'
    if range
      rtype = format_rank(rank || rtype[/\d+/i] || 1)
    else
      rtype = rtype.split('_')[1..-1].join('_') if !range
    end
  end
  rtype = rtype.gsub('top1', '0th').gsub('star', '*').tr('_', ' ')
  rtype.remove!('cool', '*', 'maxed', 'maxable') if basic
  "#{rtype} rankings #{format_ties(ties)}".squish
end

def format_bottom_rank(rank)
  "bottom #{20 - rank}"
end

def format_board(board)
  case board
  when 'hs'
    'highscore'
  when 'sr'
    'speedrun'
  when 'gm'
    'G--'
  when 'dual'
    'dual'
  else
    'highscore'
  end
end

# 'empty' means we print nothing
# This is used for when the calling function actually has other parameters
# that make is unnecessary to actually print the range
def format_range(bott, rank, empty = false)
  return '' if empty
  if bott == rank - 1
    "#{bott.ordinalize}"
  elsif bott == 0
    format_rank(rank)
  elsif rank == 20
    format_bottom_rank(bott)
  else
    "#{bott.ordinalize}-#{(rank - 1).ordinalize}"
  end
end

def format_singular(sing)
  case sing
  when 1
    'singular'
  when -1
    'plural'
  else
    ''
  end
end

def format_cool(cool)
  cool ? 'cool' : ''
end

def format_star(star)
  star ? '*' : ''
end

def format_maxed(maxed)
  maxed ? 'maxed' : ''
end

def format_maxable(maxable)
  maxable ? 'maxable' : ''
end

# Support for any single and multiple types
# 'empty' allows for no type, otherwise it's 'overall',
# which defaults to levels and episodes
def format_type(type, empty = false)
  return 'Overall' if type.nil?
  return type.to_s.remove('Mappack') if !type.is_a?(Array)
  type.map!{ |t| t.to_s.remove('Mappack') }
  case type.size
  when 0
    empty ? '' : 'Overall'
  when 1
    type.first
  when 2
    if type.include?('Level') && type.include?('Episode')
      'Overall'
    else
      type.map{ |t| t.to_s.downcase }.join(" and ").capitalize
    end
  when 3
    'Overall (w/ HC)'
  end
end

def format_mappack(mappack)
  !mappack.nil? ? "for #{verbatim(mappack.name)} mappack" : ''
end

def format_ties(ties)
  ties ? '(w/ ties)' : ''
end

def format_tied(tied)
  tied ? 'tied' : ''
end

def format_tab(tab)
  (tab == :SS2 ? '!' : (tab == :SS ? '?' : tab.to_s))
end

def format_tabs(tabs)
  tabs.map { |t| format_tab(t) }.to_sentence
end

def format_time
  Time.now.strftime("on %A %B %-d at %H:%M:%S (%z)")
end

def format_global(full)
  full ? 'global' : 'newest'
end

def format_full(full)
  full ? 'full' : ''
end

def format_max(max, min = false)
  !max.nil? ? " [#{min ? 'MIN' : 'MAX'}. #{(max.is_a?(Integer) ? "%d" : "%.3f") % max}]" : ''
end

def format_author(author)
  return '' if !author.is_a?(UserlevelAuthor)
  "on maps by #{verbatim(author.name)}"
end

def format_timespan(time)
  return '' unless time.is_a?(Numeric)
  levels = [
    ['d', 86400],
    ['h',  3600],
    ['m',    60],
    ['s',     1]
  ]
  terms = []
  levels.each{ |name, seconds|
    if time >= seconds
      terms << "#{(time / seconds).to_i}#{name}"
      time %= seconds
    end
  }
  terms << 'now' if terms.empty?
  terms.join(' ')
end

def format_sentence(e)
  return e[0].to_s if e.size == 1
  e[-2] = e[-2].to_s + " and #{e[-1].to_s}"
  e[0..-2].map(&:to_s).join(", ")
end

def format_list_score(s, board = nil)
  p_rank  = board != 'gm'
  p_score = board != 'gm'
  rankf   = board.nil? ? 'rank' : "rank_#{board}"
  scoref  = board.nil? ? 'score' : "score_#{board}"
  scale   = board == 'hs' ? 60.0 : 1
  fmt     = board == 'sr' ? "%4d" : "%7.3f"
  pad     = board.nil? ? 10 : 14
  rank_t  = p_rank ? "#{Highscoreable.format_rank(s[rankf])}: ": ''
  name_t  = s.highscoreable.name.ljust(pad, " ")
  score_t = p_score ? " - #{fmt % [s[scoref] / scale]}" : ''
  "#{rank_t}#{name_t}#{score_t}"
end

def format_level_list(levels)
  return if levels.empty?
  pad = levels.map{ |l| l.name.length }.max + 1
  format_block(levels.map{ |s| s.name.ljust(pad, ' ') + s.longname }.join("\n"))
end

# Format a list of levels resulting from a search
def format_level_matches(event, msg, page, matches, name)
  # Truncate list
  list = matches[1]
  if list.size > PAGE_SIZE
    page = parse_page(msg, page, false, event.message.components)
    pag  = compute_pages(list.size, page)
    list = list[pag[:offset]...pag[:offset] + PAGE_SIZE]
  end

  # Print list and optionally add navigation buttons
  content = "#{name.capitalize}: #{matches[0]}\n#{format_level_list(list)}"
  view = matches[1].size > PAGE_SIZE ? interaction_add_button_navigation(nil, pag[:page], pag[:pages]) : nil
  send_message(event, content: content, components: view)
  perror('', log: false, discord: false)
end

# Header of outte messages
def format_header(header, close: ':', upcase: true)
  header.squish!
  header[0] = header[0].upcase if upcase
  header += close
end

def tmp_filename(name)
  File.join(Dir.tmpdir, name)
end

def tmp_file(data, name = 'result.txt', binary: false, file: true)
  tmpfile = tmp_filename(name)
  File::open(tmpfile, binary ? 'wb' : 'w', crlf_newline: !binary) do |f|
    f.write(data)
  end
  file ? File::open(tmpfile) : tmpfile
end

def send_file(event, data, name = 'result.txt', binary = false)
  return nil if data.nil?
  event.attach_file(tmp_file(data, name, binary: binary))
end

# Send a message to a destination (typically a respondable event or a Discord channel)
# If the parameters are empty, then the content/file already appended to the event will
# be used, if any. Register msg in db at the end.
def send_message(
    dest,              # Destination (respondable event, or channel)
    content:    '',    # Message text
    files:      [],    # Message attachments
    components: nil,   # Message components (buttons, select menus...)
    spoiler:    false, # Whether to spoiler the attachments
    db:         true,  # Whether we should register this msg in the db
    edit:       true,  # Whether a component event should edit or send a new msg
    append:     false  # Whether to append content to preexisting message
  )
  # Save stuff already appended to message, and remove it to prevent autosend
  if dest.is_a?(Discordrb::Events::MessageEvent)
    # Grab message
    content = dest.saved_message.dup if content.empty?
    dest.drain

    # Grab attachment
    files << dest.file if files.empty?
    spoiler ||= !!dest.file_spoiler
    dest.detach_file
  end

  # Config and return if no message
  content.strip!
  files.reject!{ |f| !f.is_a?(File) }
  return if content.empty? && files.empty?

  # Only update message if it's a component event (no need to log)
  if edit && dest.is_a?(Discordrb::Events::ComponentEvent)
    content = dest.message.content + "\n" + content if append
    $status[:edits] += 1
    return dest.update_message(content: content, components: components)
  end

  # Manually spoiler attachments if necessary
  files.map!{ |f|
    if !File.basename(f).start_with?('SPOILER_')
      new_name = File.join(File.dirname(f), 'SPOILER_' + File.basename(f))
      File.rename(f.path, new_name)
      f.close
      File.open(new_name, 'r')
    else
      f
    end
  } if spoiler

  # Send message and log it in db
  user_id = dest.user.id if dest.respond_to?(:user)
  dest = dest.channel if dest.respond_to?(:channel)
  return if !dest.respond_to?(:send_message)
  msg = dest.send_message(content, false, nil, files, nil, nil, components)
  Message.create(id: msg.id, user_id: user_id, date: Time.now) if user_id && db
  $status[:messages] += 1
  msg
rescue => e
  lex(e, 'Failed to send message to Discord')
  nil
end
