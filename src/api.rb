# This file contains the classes used to communicate with the various APIs we
# need to interact with:
#   - Twitch.com:   Fetching N-related streams
#   - Speedrun.com: Leaderboards, notifications for new/verified runs, etc.
#   - Steam:        Generate authentication tickets for N++
#   - N++:          Our custom game server (NPPServer) for mappacks
#   - Custom API:   Our custom API (APIServer) to request stats on command
# We also have a general socket module (Sock) which is the base for both servers

require 'json'
require 'net/http'
require 'octicons'
require 'socket'
require 'webrick'

module Twitch extend self

  GAME_IDS = {
#    'N'     => 12273,  # Commented because it's usually non-N related :(
    'N+'     => 18983,
    'Nv2'    => 105456,
    'N++'    => 369385
#    'GTASA'  => 6521    # This is for testing purposes, since often there are no N streams live
  }

  def get_twitch_token
    acquire_connection
    $twitch_token = GlobalProperty.find_by(key: 'twitch_token').value
    release_connection
    update_twitch_token if !$twitch_token
    $twitch_token
  end

  def set_twitch_token(token)
    acquire_connection
    GlobalProperty.find_by(key: 'twitch_token').update(value: token)
    release_connection
  end

  def length(s)
    (Time.now - DateTime.parse(s['started_at']).to_time).to_i / 60.0
  end

  def table_header
    "#{"Player".ljust(15, " ")} #{"Title".ljust(35, " ")} #{"Time".ljust(12, " ")} #{"Views".ljust(4, " ")}\n#{"-" * 70}"
  end

  def format_stream(s)
    name  = to_ascii(s['user_name']).strip[0...15].ljust(15, ' ')
    title = to_ascii(s['title']).strip[0...35].ljust(35, ' ')
    time  = "#{length(s).to_i} mins ago".rjust(12, ' ')
    views = s['viewer_count'].to_s.rjust(5, ' ')
    "#{name} #{title} #{time} #{views}"
  end

  def update_twitch_token
    res = Net::HTTP.post_form(
      URI.parse("https://id.twitch.tv/oauth2/token"),
      {
        client_id: $config['twitch_client'].to_s,
        client_secret: $config['twitch_secret'].to_s,
        grant_type: 'client_credentials'
      }
    )
    if res.code.to_i == 401
      err("TWITCH: Unauthorized to perform requests, please verify you have this correctly configured.")
    elsif res.code.to_i != 200
      err("TWITCH: App access token request failed (code #{res.body}).")
    else
      $twitch_token = JSON.parse(res.body)['access_token']
      set_twitch_token($twitch_token)
    end
  rescue => e
    lex(e, "TWITCH: App access token request method failed")
    sleep(5)
    retry
  end

  # TODO: Add attempts to the loop, raise if fail
  def get_twitch_game_id(name)
    get_twitch_token if !$twitch_token
    uri = URI("https://api.twitch.tv/helix/games?name=#{name}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    loop do
      res = http.get(
        uri.request_uri,
        {
          'Authorization' => "Bearer #{$twitch_token}",
          'Client-Id' => $config['twitch_client'].to_s
        }
      )
      if res.code.to_i == 401
        update_twitch_token
        sleep(5)
      elsif res.code.to_i != 200
        err("TWITCH: Game ID request failed.")
        sleep(5)
      else
        return JSON.parse(res.body)['id'].to_i
      end
    end
  rescue => e
    lex(e, 'TWITCH: Game ID request method failed.')
    sleep(5)
    retry
  end

 # TODO: Add attempts to the loops, raise if fail
 # TODO: Add offset/pagination for when there are many results
  def get_twitch_streams(name, offset = nil)
    if !GAME_IDS.key?(name)
      err("TWITCH: Supplied game not known.")
      return
    end
    get_twitch_token if !$twitch_token
    uri = URI("https://api.twitch.tv/helix/streams?first=100&game_id=#{GAME_IDS[name]}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    res = nil
    loop do
      res = http.get(
        uri.request_uri,
        {
          'Authorization' => "Bearer #{$twitch_token}",
          'Client-Id' => $config['twitch_client'].to_s
        }
      )
      if res.code.to_i == 401
        update_twitch_token
        sleep(5)
      elsif res.code.to_i != 200
        err("TWITCH: Stream list request for #{name} failed (code #{res.code.to_i}).")
        sleep(5)
      else
        return JSON.parse(res.body)['data']
      end
    end
  rescue => e
    lex(e, "TWITCH: Stream list request method for #{name} failed.")
    sleep(5)
    retry
  end

  def update_twitch_streams
    # Update streams for each followed game
    GAME_IDS.each{ |game, id|
      new_streams = get_twitch_streams(game)
      $twitch_streams[game] = [] if !$twitch_streams.key?(game)

      # Reject blacklisted streams
      new_streams.reject!{ |s| TWITCH_BLACKLIST.include?(s['user_id'].to_i) }

      # Update values of already existing streams
      $twitch_streams[game].each{ |stream|
        new_stream = new_streams.select{ |s| s['user_id'] == stream['user_id'] }.first
        if !new_stream.nil?
          stream.merge!(new_stream)
          stream['on'] = true
        else
          stream['on'] = false
        end
      }

      # Add new streams
      new_streams.reject!{ |s|
        $twitch_streams[game].map{ |ss| ss['user_id'] }.include?(s['user_id'])
      }
      new_streams.each{ |stream| stream['on'] = true }
      $twitch_streams[game].push(*new_streams)

      # Delete obsolete streams
      $twitch_streams[game].reject!{ |stream|
        stream.key?('on') && !stream['on'] && stream.key?('posted') && (Time.now.to_i - stream['posted'] > TWITCH_COOLDOWN)
      }

      # Reorder streams
      $twitch_streams[game].sort_by!{ |s| -Time.parse(s['started_at']).to_i }
    }
  end

  def active_streams
    $twitch_streams.map{ |game, list|
      [game, list.select{ |s| s['on'] }]
    }.to_h
  end

  def new_streams
    active_streams.map{ |game, list|
      [game, list.select{ |s| !s['posted'] && Time.parse(s['started_at']).to_i > $boot_time.to_i }]
    }.to_h
  end

  def post_stream(stream)
    return if $content_channel.nil?
    game = GAME_IDS.invert[stream['game_id'].to_i]
    return if !game
    send_message($content_channel, content: "#{ping(TWITCH_ROLE)} #{verbatim(stream['user_name'])} started streaming **#{game}**! #{verbatim(stream['title'])} <https://www.twitch.tv/#{stream['user_login']}>")
    return if !$twitch_streams.key?(game)
    s = $twitch_streams[game].select{ |s| s['user_id'] ==  stream['user_id'] }.first
    s['posted'] = Time.now.to_i if !s.nil?
  rescue => e
    lex(e, 'Failed to post new Twitch stream')
  end

  # TODO: Allow for positive emoji to counteract negative emoji to prevent snipers
  def report_stream(event)
    msg = event.message.content
    msg =~ /<(https:\/\/www.twitch.tv\/(.+?))>$/i
    url, user = $1, $2
    return if !user
    embed = Discordrb::Webhooks::Embed.new(
      description: "🚨 Stream by [`#{user}`](<#{url}>) has been reported.",
      color:       SPEEDRUN_COLOR_NEW,
      timestamp:   Time.now,
      footer:      Discordrb::Webhooks::EmbedFooter.new(text: "Reported by #{event.user.name}")
    )
    send_message($content_channel, embed: embed)
  end

  # TODO: Accumulate reports to different streams in db, after a certain amount trigger autoban
  def ban_stream(event)
    msg = event.message.content
    msg =~ /<(https:\/\/www.twitch.tv\/(.+?))>$/i
    url, user = $1, $2
    return if !user
    n = 5
    embed = Discordrb::Webhooks::Embed.new(
      description: "🔨 Stream by [`#{user}`](<#{url}>) has been blacklisted.",
      color:       SPEEDRUN_COLOR_REJ,
      timestamp:   Time.now,
      footer:      Discordrb::Webhooks::EmbedFooter.new(text: "After having #{n} streams reported.")
    )
    send_message($content_channel, embed: embed)
  end
end

# Handle Speedrun.com API
module Speedrun extend self

  # Basic API info
  WEB_ROOT    = 'https://www.speedrun.com'
  API_ROOT    = 'https://www.speedrun.com/api'
  API_VERSION = 1
  RETRIES     = 5

  # API routes we use (max count = 200)
  ROUTE_CATEGORIES         = 'categories'
  ROUTE_GAMES              = 'games'
  ROUTE_LEADERBOARDS       = 'leaderboards/%s/category/%s' # game ID, category ID
  ROUTE_LEADERBOARDS_LEVEL = 'leaderboards/%s/level/%s/%s' # game ID, level ID, category ID
  ROUTE_RUNS               = 'runs'
  ROUTE_SERIES             = 'series'
  ROUTE_SERIES_GAMES       = 'series/%s/games'             # series ID

  # Map common platform IDs to names. We still fetch the platform resource, but
  # this allows to use custom abbreviated names which are not in the API.
  PLATFORMS = {
    '7g6m8erk' => 'DS',
    'wxeo3zer' => 'DSi',
    '8gej2n93' => 'PC',
    'nzelkr6q' => 'PS4',
    'nzeljv9q' => 'PS4 Pro',
    '5negk9y7' => 'PSP',
    '7m6ylw9p' => 'Switch',
    '3167lw9q' => 'Switch 2',
    'n568oevp' => 'Xbox 360',
    'o7e2mx6w' => 'Xbox One'
  }

  # N series info
  SERIES_ID = 'g45kx54q'
  GAMES = {
    'm1mjnk12' => 'N++',
    '268wr76p' => 'N+',
    'y654p8de' => 'N v1.4',
    'm1mokp62' => 'N v2.0',
    'v1ponv46' => 'Cat Ext'
  }
  DEFAULT_GAME = 'm1mjnk12'

  MAX_REPORT_AGE = 7 * 24 * 60 * 60 # Oldest runs to consider new (i.e. notifiable)

  # Prefetch some information that hardly changes (games, categories and variables)
  @@games = GAMES.map{ |k, v| [k, {}] }.to_h

  # Cache to store HTTP requests to the API for a few minutes, specially useful when
  # navigating paginated lists (e.g. leaderboards). The API limit is 100 requets
  # per minute, so it's hard to reach, but this way we save time anyway.
  @@cache = Cache.new

  def get_game(game)
    @@games[game]
  end

  def get_category(game, cat)
    @@games[game][:categories][cat]
  end

  def get_variable(game, cat, var)
    @@games[game][:categories][cat][:variables][var]
  end

  def get_value(game, cat, var, val)
    @@games[game][:categories][cat][:variables][var][:values][val]
  end

  def key(route, params)
    "#{route}:#{params.to_json}"
  end

  def uri(route, params)
    route = route.join('/') if route.is_a?(Array)
    query = params.map{ |k, v| "#{k}=#{v}" }.join('&')
    URI("%s/v%d/%s?%s" % [API_ROOT, API_VERSION, route, query])
  end

  def request(route, params)
    uri = uri(route, params)
    req = Net::HTTP::Get.new(uri)
    versions = [RUBY_VERSION, ActiveRecord.version, Discordrb::VERSION]
    req['User-Agent'] = "inne++ Discord Bot (#{GITHUB_LINK}) Ruby/%s Rails/%s discordrb/%s" % versions
    req['Cache-Control'] = 'no-cache'
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 1){ |http|
      http.request(req)
    }
    dbg("Speedrun API request: #{uri}\nCache: #{res['x-cache']}") if SPEEDRUN_DEBUG_LOGS
    res.is_a?(Net::HTTPSuccess) ? res.body.to_s : nil
  rescue Timeout::Error
    nil
  end

  # Wrapper to look up in our local cache before actually making the request.
  # The Speedrun.com CDN doesn't actually honor the 'no-cache' header, so
  # we have to include a cache-busting parameter.
  def get(route, params, cache: true)
    params.reject!{ |key, value| value.nil? }
    key = key(route, params)
    params[:cache] = "%08x" % rand(2 ** 32) unless cache # Cache busting not included in key
    body = cache && @@cache.get(key) || request(route, params)
    return if !body
    @@cache.add(key, body)
    JSON.parse(body)
  end

  def parse_game(data)
    # Parse embedded categories and variables, if present
    if data['categories']
      categories = data['categories']['data'].map{ |cat| [cat['id'], parse_category(cat)] }.to_h
    else
      categories = {}
    end

    # Parse embedded mods, if present
    moderators = data['moderators']
    if moderators.key?('data')
      moderators = moderators['data'].map{ |mod| [mod['id'], parse_user(mod)] }.to_h
    else
      moderators = moderators.map{ |id, type| [id, { id: id, name: id, type: type }]  }.to_h
    end

    # Parse embedded platforms, if present. They're embedded as a hash, but otherwise
    # come a list of platform IDs. Ditto for genres and developers.
    platforms = data['platforms']
    if data['platforms'].is_a?(Hash)
      platforms = platforms['data'].map{ |plat| [plat['id'], parse_platform(plat)] }.to_h
    else
      platforms.map{ |id| [id, { id: id, name: id }]  }.to_h
    end

    # Parse embedded genres, if present
    genres = data['genres']
    if data['genres'].is_a?(Hash)
      genres = genres['data'].map{ |genre| [genre['id'], parse_genre(genre)] }.to_h
    else
      genres.map{ |id| [id, { id: id, name: id }]  }.to_h
    end

    # Parse embedded developers, if present
    developers = data['developers']
    if data['developers'].is_a?(Hash)
      developers = developers['data'].map{ |dev| [dev['id'], parse_developer(dev)] }.to_h
    else
      developers.map{ |id| [id, { id: id, name: id }]  }.to_h
    end

    # Parse embedded levels, if present
    if data['levels']
      levels = data['levels']['data'].map{ |level| [level['id'], parse_level(level)] }.to_h
    else
      levels = {}
    end

    {
      id:           data['id'],
      name:         data['names']['international'],
      abbreviation: data['abbreviation'],
      alias:        GAMES[data['id']], # Only for the N series ones
      uri:          data['weblink'],
      date:         Time.parse(data['release-date']),
      cover:        data['assets']['cover-large']['uri'],
      categories:   categories,
      moderators:   moderators,
      platforms:    platforms,
      genres:       genres,
      developers:   developers,
      levels:       levels
    }
  end

  def parse_developer(data)
    {
      id:   data['id'],
      name: data['name']
    }
  end

  def parse_genre(data)
    {
      id:   data['id'],
      name: data['name']
    }
  end

  def parse_platform(data)
    {
      id:     data['id'],
      name:   data['name'],
      alias:  PLATFORMS[data['id']], # Only for a few we've set
      date:   data['released']
    }
  end

  # TODO: Find a way to add the flag (Unicode emoji for countries using the code)
  def parse_user(data)
    return { id: data['name'], name: data['name'] } if data['rel'] == 'guest'
    limbo = !data['location']
    {
      id:           data['id'],
      name:         data['names']['international'],
      uri:          data['weblink'],
      country:      !limbo ? data['location']['country']['names']['international'] : nil,
      country_code: !limbo ? data['location']['country']['code'] : nil,
      role:         data['role'],
      date:         data['signup'] ? Time.parse(data['signup']) : nil
    }
  end

  def parse_value(id, data)
    {
      id:          id,
      name:        data['label'],
      description: data['rules'], # Only present when variable is a sub-category
      flags:       data['flags']  # Only present when variable is a sub-category
    }
  end

  def parse_variable(data)
    {
      id:          data['id'],
      name:        data['name'],
      default:     data['values']['default'],  # Default value for this variable (nil = none)
      category:    data['category'],           # nil = applies to all categories
      subcategory: data['is-subcategory'],     # Leaderboards shown as drop-menus instead of filters
      mandatory:   data['mandatory'],          # Must be specified on submission
      custom:      data['user-defined'],       # User sets custom value on submission
      obsoletes:   data['obsoletes'],          # Runs are considered for leaderboards
      values:      data['values']['values'].map{ |id, val| [id, parse_value(id, val)] }.to_h
    }
  end

  def parse_category(data)
    variables = {}
    variables = data['variables']['data'].map{ |var|
      [var['id'], parse_variable(var)]
    }.to_h if data['variables']

    {
      id:           data['id'],
      name:         data['name'],
      uri:          data['weblink'],
      description:  data['rules'],
      il:           data['type'] == 'per-level',
      player_count: data['players']['value'],
      player_exact: data['players']['type'] == 'exactly',
      misc:         data['miscellaneous'],
      variables:    variables
    }
  end

  def parse_video(data)
    {
      uri: data['uri']
    }
  end

  def parse_level(data)
    {
      id:          data['id'],
      name:        data['name'],
      uri:         data['weblink'],
      description: data['rules']
    }
  end

  # Parse a raw run. The player list may be optionally provided, since in some
  # cases (such as leaderboards) it's impossible to embed them directly in the runs.
  def parse_run(data, players = nil)
    # Parse embedded player resource, if present
    if data['players'].is_a?(Hash) && data['players']['data']
      players = data['players']['data'].map{ |p| parse_user(p) }
    elsif players
      players = data['players'].map{ |p|
        field = p['rel'] == 'user' ? :id : :name
        pp = players.find{ |pp| pp[field] == p[field.to_s] }
        pp || { id: p['id'], name: p['name'] || '-' }
      }
    else
      players = data['players'].map{ |p| { id: p['id'], name: p['name'] || '-' } }
    end

    # Parse video resource, if present
    if !!data&.[]('videos')&.[]('links')
      videos = data['videos']['links'].map{ |vid| parse_video(vid) }
    else
      videos = []
    end

    {
      # Basic info
      game:     data['game'],
      uri:      data['weblink'],
      players:  players,

      # Classification of the run
      category:  data['category'],
      level:     data['level'],
      variables: data['values'],

      # User provided info
      description: data['comment'],
      videos:      videos,

      # System info
      platform: data['system']['platform'],
      emulated: data['system']['emulated'],

      # Times
      rta: data['times']['realtime_t'],
      igt: data['times']['ingame_t'],

      # Status
      verified:      data['status']['status'] == 'verified',
      rejected:      data['status']['status'] == 'rejected',
      reject_reason: data['status']['reason'],
      examiner:      data['status']['examiner'],

      # Dates
      date:           (Time.parse(data['date']) rescue nil),
      date_submitted: (Time.parse(data['submitted']) rescue nil),
      date_verified:  (Time.parse(data['status']['verify-date']) rescue nil)
    }
  end

  # See parse_run
  def parse_leaderboard(data, players = nil, range: nil)
    # Runs with a place of 0 typically don't belong to this leaderboard
    count = data['runs'].count
    runs = data['runs'].select{ |run| range ? range.cover?(run['place']) : run['place'] > 0 }
                       .map{ |run| parse_run(run['run'], players).merge(place: run['place']) }
    {
      game:     data['game'],
      category: data['category'],
      values:   data['values'],
      uri:      format_url(data['game'], data['category'], data['values']), # data['weblink'] is broken
      count:    count,
      runs:     runs
    }
  end

  # Retrieve game, category and variable information for all N games
  def fetch_basic_info
    embed = 'categories.variables,moderators,platforms,genres,developers,levels'
    res = get(ROUTE_SERIES_GAMES % SERIES_ID, { embed: embed })
    return if !res
    @@games = res['data'].map{ |game| [game['id'], parse_game(game)] }.to_h
  end

  # Ensure the basic information (games, categories, variables, platforms) is available
  def ensure_basic_info(game = default_game)
    return false if !@@games.key?(game)
    attempts = 0
    fetch_basic_info while (attempts += 1) <= RETRIES && @@games[game].empty?
    !@@games[game].empty?
  end

  # Fetch latest runs and check for new ones
  # TODO: Truncate full list first, parse afterwards, to avoid parsing all runs
  # TODO: Pagination doesn't work like this, due to mixing multiple lists
  def fetch_runs(game, count: SPEEDRUN_NEW_COUNT, page: 0, cache: true, status: nil, order: nil, parse: true)
    return [] if game && !ensure_basic_info(game)
    order ||= status == 'verified' ? 'verify-date' : 'submitted'
    params = { game: game, status: status, max: count, offset: count * page, orderby: order, direction: 'desc', embed: 'players' }
    res = get(ROUTE_RUNS, params, cache: cache)
    return [] if !res
    parse ? res['data'].map{ |run| parse_run(run) } : res['data']
  end

  # Get the leaderboards for a given category, optionally filtering by platform and any variable
  def fetch_boards(game, category, variables: {}, platform: nil)
    return { game: game, category: category, uri: nil, runs: [] } if !ensure_basic_info(game)
    params = { embed: 'players' }
    params[:platform] = platform if platform
    variables.each{ |var, val| params["var-#{var}"] = val }
    res = get(ROUTE_LEADERBOARDS % [game, category], params)
    return { game: game, category: category, uri: nil, values: {}, runs: [] } if !res
    players = res['data']['players']['data'].map{ |p| parse_user(p) } if res['data']['players']
    parse_leaderboard(res['data'], players)
  end

  # Check for new N runs that need to be notified
  def fetch_new_runs
    GAMES.map{ |id, name|
      ['new', 'verified', 'rejected'].map{ |status|
        sleep(0.5)
        property = GlobalProperty.find_by(key: "last_#{status}_#{id}_speedrun")
        threshold = Time.parse(property.value)
        new_threshold = threshold
        runs = fetch_runs(id, cache: false, status: status).select{ |run|
          time = run[status == 'verified' ? :date_verified : :date_submitted]
          next false if !time
          new_threshold = time if time > new_threshold
          time > threshold && (status != 'rejected' ? time > Time.now - MAX_REPORT_AGE : true)
        }
        property.update(value: new_threshold)
        runs
      }
    }.flatten
  end

  # Fetch any new runs (in all games), good for testing
  def fetch_new_runs_test
    $threshold = {
      'new'      => Time.now,
      'verified' => Time.now,
      'rejected' => Time.now
    } unless $threshold
    ['new', 'verified', 'rejected'].map{ |status|
      new_threshold = $threshold[status]
      runs = fetch_runs(nil, cache: false, status: status, parse: false).select{ |run|
        field = status == 'verified' ? run['status']['verify-date'] : run['submitted']
        next false if !field
        time = Time.parse(field)
        new_threshold = time if time > new_threshold
        time > $threshold[status] && (status != 'rejected' ? time > Time.now - MAX_REPORT_AGE : true)
      }
      $threshold[status] = new_threshold
      runs
    }.flatten
  end

  # Return the ID of the default game
  def default_game
    GAMES.invert['N++']
  end

  # Return the ID of the default category of a game
  def default_category(game)
    return if !ensure_basic_info(game)
    get_game(game)[:categories].first[1][:id]
  end

  # Return the ID of the default value of a given variable
  def default_value(game, cat, var)
    return if !ensure_basic_info(game)
    get_variable(game, cat, var)[:default]
  end

  # Checks if the game ID is valid
  def validate_game(game)
    @@games.key?(game)
  end

  # Checks if the category ID is valid and corresponds to the given game
  # Assumes the game is valid
  def validate_category(game, cat)
    return if !ensure_basic_info(game)
    get_game(game)[:categories].any?{ |id, _| id == cat }
  end

  # Checks if the variable ID is valid and corresponds to the given game and category
  # Assumes the game and category are valid
  def validate_variable(game, cat, var)
    return if !ensure_basic_info(game)
    get_category(game, cat)[:variables].any?{ |id, _| id == var }
  end

  # Checks if the value ID is valid and corresponds to the given variable
  # Assumes the game, category and variable are valid
  def validate_value(game, cat, var, val)
    return if !ensure_basic_info(game)
    get_variable(game, cat, var)[:values].any?{ |id, _| id == val }
  end

  # Ensure the game ID is valid, default if not
  def sanitize_game(game)
    validate_game(game) ? game : default_game
  end

  # Ensure the category ID is valid, default if not
  def sanitize_category(game, cat)
    return if !ensure_basic_info(game)
    validate_category(game, cat) ? cat : default_category(game)
  end

  # Ensure the variable ID is valid, default _TO NIL_ if not
  def sanitize_variable(game, cat, var)
    return if !ensure_basic_info(game)
    validate_variable(game, cat, var) ? var : nil
  end

  # Ensure the value ID is valid, default if not
  def sanitize_value(game, cat, var, val)
    return if !ensure_basic_info(game)
    validate_value(game, cat, var, val) ? val : default_value(game, cat, var)
  end

  # Build the Speedrun web URL for the corresponding leaderboards
  def format_url(game, category = nil, values = {})
    url = "#{WEB_ROOT}/#{@@games[game][:abbreviation]}"
    return url if !category
    url << '?x=' << category
    return url if values.empty?
    url << '-' << values.map{ |var, val| "#{var}.#{val}" }.join('-')
    url
  end

  # Format a run into usable textual fields
  def format_run(run)
    # Fetch main components of the run
    game      = @@games[run[:game]]
    category  = game[:categories][run[:category]]
    platform  = game[:platforms][run[:platform]]
    level     = !!run[:level] ? game[:levels][run[:level]] : nil
    variables = run[:variables].map{ |var_id, val_id|
      category[:variables][var_id][:values][val_id][:name]
    }.join(', ')

    # Format fields
    {
      game:     game[:alias] || game[:name],
      platform: platform[:alias] || platform[:name],
      mode:     category[:il] ? 'IL' : category[:il].nil? ? '?' : 'RTA',
      category: category[:name],
      type:     !!level ? level[:name] : !run[:variables].empty? ? variables : '-',
      players:  run[:players].map{ |p| p[:name] }.join(', '),
      rta:      format_timespan(run[:rta], ms: true, iso: true),
      igt:      format_timespan(run[:igt], ms: true, iso: true),
      date:     (run[:date_submitted].strftime('%Y/%m/%d') rescue 'Unknown'),
      status:   run[:verified] ? 'VER' : run[:rejected] ? 'REJ' : 'NEW',
      color:    run[:verified] ? ANSI::GREEN : run[:rejected] ? ANSI::RED : ANSI::YELLOW,
      emoji:    run[:verified] ? '✅' : run[:rejected] ? '❌' : '💥'
    }
  end

  # Format latest runs
  def format_table(runs, color: true, emoji: false)
    # Draft table fields
    colors = []
    runs.map!{ |run|
      run = format_run(run)
      run[:status] += ' ' + run[:emoji] if emoji
      colors << run[:color]
      run.values.take(10)
    }

    # Compute padding (not necessary anymore since we're using make_table)
    header = ["Game", "System", "Mode", "Category", "Type", "Players", "RTA", "IGT", "Date", "Status"]
    align = ['-', '-', '-', '-', '-', '-', '', '', '-', '']
    max_padding = [7, 8, 4, 32, 32, 32, 12, 12, 10, 12]
    padding = header.map(&:length)
    padding = runs.transpose.lazy.zip(padding, max_padding).map{ |col, min, max|
      col.max_by(&:length).length.clamp(min, max)
    }.force if !runs.empty?

    # Format rows (add header, apply padding and coloring) and craft table
    runs.prepend(header)
    runs.each{ |run|
      run.map!.with_index{ |field, i| "%#{align[i]}*.*s" % [padding[i], padding[i], field] }
    }
    runs[1..-1].each.with_index{ |run, i| run[-1] = ANSI.format(run[-1], bold: true, fg: colors[i]) } if color
    runs[0].map!{ |field| ANSI.bold + field + ANSI.none }
    runs.insert(1, :sep)
    make_table(runs)
  end

  # Format the leaderboards
  def format_boards(boards)
    game = get_game(boards[:game])
    cat = get_category(boards[:game], boards[:category])
    header = "📜 #{GAMES[game[:id]]} Speedruns — #{cat[:name]}"
    vars = boards[:values].map{ |var, val| get_value(boards[:game], boards[:category], var, val)[:name] }.join(', ')
    header += " (#{vars})" unless vars.empty?
    list = boards[:runs].map{ |run|
      fields = format_run(run).merge(place: run[:place])
      case game[:alias]
      when 'N++'
        place_emoji = 'plus_' + run[:place].ordinalize
      when 'N v1.4', 'N v2.0'
        place_emoji = 'gold_' + run[:place].ordinalize
      else
        place_emoji = 'trophy_' + run[:place].ordinalize
      end
      place = app_emoji(place_emoji) || EMOJI_NUMBERS[run[:place]] || "**#{run[:place]}**"
      players = mdurl('**' + run[:players].map{ |p| p[:name] }.join(', ') + '**', run[:uri])
      time = fields[:rta] + (fields[:igt] != '-' ? " (#{fields[:igt]} IGT)" : '')
      time = verbatim(time)
      plat_emoji = nil
      ['PC', 'PSP', 'PS', 'Xbox', 'Switch', '2DS', '3DS', 'DS'].each{ |plat|
        break plat_emoji = app_emoji("plat_#{plat}") if fields[:platform][/#{plat}/i]
      }
      plat_emoji = '💻' if ['N v1.4', 'N v2.0'].include?(GAMES[game[:id]])
      platform = plat_emoji || "(#{fields[:platform]})"
      "%s %s: %s — %s %s" % [place, players, time, fields[:date], platform]
    }.join("\n")
    embed = Discordrb::Webhooks::Embed.new(
      title:       header,
      description: list,
      url:         boards[:uri],
      color:       SPEEDRUN_COLOR_INFO,
      thumbnail:   Discordrb::Webhooks::EmbedThumbnail.new(url: game[:cover])
    )
    embed
  end

  # Formats a single run as an embed
  def format_embed(run, emoji: true)
    # Format fields
    game = @@games[run[:game]]
    fields = format_run(run)
    examiner = game[:moderators][run[:examiner]]
    examiner = "[`#{examiner[:name]}`](#{examiner[:uri]})" if examiner
    player_url = run[:players][0][:uri]
    type = !!run[:level] ? 'Level' : !run[:variables].empty? ? 'Subcategory' : '-'

    # Distinguish by status
    if run[:verified]
      date  = run[:date_verified] ? ' on ' + run[:date_verified].strftime('%Y/%m/%d') : ''
      color = SPEEDRUN_COLOR_VER
      title = "New #{fields[:game]} speedrun verified!"
      desc  = "Run verified by #{examiner}#{date}."
    elsif run[:rejected]
      color = SPEEDRUN_COLOR_REJ
      title = "New #{fields[:game]} speedrun rejected!"
      desc  = "Run rejected by #{examiner} due to:\n" + format_block(run[:reject_reason])
    else
      color = SPEEDRUN_COLOR_NEW
      title = "New #{fields[:game]} speedrun submitted!"
      desc  = 'Run pending verification.'
    end
    title.prepend(fields[:emoji] + ' ') if emoji

    # Build embed object
    embed = Discordrb::Webhooks::Embed.new(
      title:       title,
      description: desc,
      url:         run[:uri],
      color:       color,
      timestamp:   run[:date_submitted],
      author:      Discordrb::Webhooks::EmbedAuthor.new(name: fields[:players], url: player_url),
      footer:      Discordrb::Webhooks::EmbedFooter.new(text: 'Submitted to Speedrun.com', icon_url: 'https://www.speedrun.com/images/1st.png'),
      thumbnail:   Discordrb::Webhooks::EmbedThumbnail.new(url: game[:cover])
    )

    # Add inline fields
    embed.add_field(inline: true, name: 'Game',     value: fields[:game])
    embed.add_field(inline: true, name: 'Category', value: fields[:category])
    embed.add_field(inline: true, name: type     ,  value: fields[:type]) unless type == '-'
    embed.add_field(inline: true, name: 'System',   value: fields[:platform])
    embed.add_field(inline: true, name: 'RTA',      value: fields[:rta])
    embed.add_field(inline: true, name: 'IGT',      value: fields[:igt])
    embed
  end

end

#------------------------------------------------------------------------------#
#                           STEAM TICKET DOCUMENTATION                         |
#------------------------------------------------------------------------------#
# Parts                                                                        |
#   Game Connect token (24 bytes): Identifies each session                     |
#   Session Header (28 bytes):     Additional session information              |
#   Ownership ticket (>46 bytes):  Proves ownership of app                     |
#------------------------------------------------------------------------------#
# Game Connect token                                                           |
#     4B - Token size (always 20)                                              |
#     8B - GC token   (seemingly random)                                       |
#     8B - SteamID64                                                           |
#     4B - Token generation timestamp                                          |
#------------------------------------------------------------------------------#
# Session header                                                               |
#     4B - Header size (always 24)                                             |
#     4B - ?           (always 1)                                              |
#     4B - ?           (always 2)                                              |
#     4B - IP of Steam node we connected to?                                   |
#     4B - ?                                                                   |
#     4B - Time connected in ms                                                |
#     4B - Connection count with this ticket                                   |
#------------------------------------------------------------------------------#
# Ownership ticket                                                             |
#     4B - Complete size incl. signature (only present in full tickets)        |
#     4B - Ticket size including itself                                        |
#     4B - Ticket version (currently 4)                                        |
#     8B - SteamID64                                                           |
#     4B - App ID (230270 for N++)                                             |
#     4B - External IP                                                         |
#     4B - Internal IP                                                         |
#     4B - License flags (usually 2)                                           |
#     4B - Ticket generation timestamp                                         |
#     4B - Ticket expiration timestamp (21 days)                               |
#     2B - License count                                                       |
#     ## - License IDs (4B x count, 94152 for N++)                             |
#     2B - DLC count                                                           |
#     ## - DLC list (ID + license count + license IDs each)                    |
#     2B - Reserved / padding                                                  |
#   128B - Ownership ticket signature (see verify_signature)                   |
#------------------------------------------------------------------------------#
# Notes                                                                        |
#   - Ownership tickets are issued on command and prove ownership for Steam ID |
#     ID / App ID pair. They expire in 21 days and we reuse them if possible.  |
#   - Authentication tickets include the other blocks which are session        |
#     dependent. GC tokens are issued automatically by Steam on login and in   |
#     other ocassions, such as starting a game. The whole ticket is validated  |
#     and at that point it expires in about 5 minutes. This is then sent to    |
#     Metanet's server to authenticate, we remain authenaticated for 1 hour.   |
#   - We use a custom Python utility (util/auth.py) to talk to Steamworks's    |
#     API using the steam-py library to generate the tokens and validate the   |
#     full tickets. We login using refresh tokens which are stored as env vars |
#------------------------------------------------------------------------------#

class SteamTicket < ActiveRecord::Base
  # The ticket length is variable, for N++ they should always be 234 bytes
  TOKEN_LENGTH      =  20
  SESSION_LENGTH    =  24
  MIN_TICKET_LENGTH = 230

  # Exit statuses of the Python authentication script
  EXIT_OK                       = 0
  EXIT_NO_CREDENTIALS           = 1
  EXIT_NO_OWNERSHIP_TICKET      = 2
  EXIT_NO_AUTHENTICATION_TICKET = 3

  # Make parsed attributes available after instantiation like regular attributes
  attr_accessor :token,      :token_time, :conn_ip,     :conn_duration,
                :conn_count, :version,    :external_ip, :internal_ip,
                :flags,      :created_at, :expires,     :licenses,
                :dlcs,       :signature
  after_save :parse
  after_initialize :parse

  # Generate a new ticket by running a Python util that connects to Steam's API
  def self.generate(app_id, username: nil, password: nil, token: nil, ticket: nil, file: nil)
    path = "#{PATH_STEAM_AUTH} #{app_id} -s"
    path << " -u #{username}" if username
    path << " -p #{password}" if password
    path << " -t #{token}"    if token
    path << " -o #{ticket}"   if ticket
    path << " -f #{file}"     if file
    dbg("Requesting new Steam ticket for #{app_id}...")
    stdout, stderr, status = python(path, output: true)
    return if status.nil?
    return err("Steam credentials expired or unavailable", discord: true) if status.exitstatus == EXIT_NO_CREDENTIALS
    return if !status.success? || stdout.blank?
    add_ascii(stdout.strip)
  end

  # Parse a raw ticket into a struct with the same field names as the ticket object
  def self.parse(ticket)
    # Basic integrity checks
    if ticket.length < MIN_TICKET_LENGTH
      err("Ticket is too short (#{ticket.length} < #{MIN_TICKET_LENGTH})")
      return
    end

    # Read fields as a buffer
    buffer = StringIO.new(ticket)
    _, token, _, token_time = ioparse(buffer, 'L<Q<2L<') # GC token
    _, _, _, conn_ip, _, conn_duration, conn_count = ioparse(buffer, 'L<7') # Session header
    _, _, version, id, app, ext_ip, int_ip, flags, gen_time, exp_time = ioparse(buffer, 'L<3Q<L<6') # Ownership ticket
    license_count, = ioparse(buffer, 'S<')
    licenses = ioparse(buffer, "L<#{license_count}")
    dlc_count, = ioparse(buffer, 'S<')
    dlcs = {}
    dlc_count.times.map{
      dlc_id, package_count= ioparse(buffer, 'L<S<')
      dlcs[dlc_id] = ioparse(buffer, "L<#{package_count}")
    }
    signature, = ioparse(buffer, 'x2a128')

    # Convert times and IP addresses to more suited types
    token_time, gen_time, exp_time = [token_time, gen_time, exp_time].map{ |t| Time.at(t) }
    conn_ip, ext_ip, int_ip = [conn_ip, ext_ip, int_ip].map{ |ip| IPAddr.new(ip, Socket::AF_INET) }
    conn_duration /= 1000.0 # from ms to s

    # Build struct
    Struct.new(
      :token,       :token_time,  :conn_ip,  :conn_duration,
      :conn_count,  :version,     :steam_id, :app_id,
      :external_ip, :internal_ip, :flags,    :created_at,
      :expires,     :licenses,    :dlcs,     :signature,
      :ticket
    ).new(
      token,      token_time, conn_ip, conn_duration,
      conn_count, version,    id,      app,
      ext_ip,     int_ip,     flags,   gen_time,
      exp_time,   licenses,   dlcs,    signature,
      ticket
    )
  rescue => e
    lex(e, 'Failed to parse Steam ticket')
    nil
  end

  # Parse a ticket in ASCII form, which is how they're typically sent over the wire
  def self.parse_ascii(ticket)
    parse([ticket].pack('H*'))
  end

  # Creates a new ticket or updated the one corresponding to this user / app pair.
  def self.add(ticket, date = Time.now)
    dbg("Parsing Steam ticket...")
    fields = parse(ticket)
    return nil if !fields
    dbg("Creating Steam ticket...")
    obj = find_or_create_by(steam_id: fields.steam_id, app_id: fields.app_id)
    obj.update(ticket: ticket, date: date)
    obj
  end

  # Create a new ticket object from an ASCII ticket
  def self.add_ascii(ticket)
    add([ticket].pack('H*'))
  end

  # The ownership ticket portion is signed by Steam using their system public key.
  # The method is 1024bit RSA-SHA1 so the sig should be 128 bytes.
  def self.verify_signature(data, signature)
    OpenSSL::PKey::RSA.new(File.read(PATH_STEAM_KEY)).verify('SHA1', signature, data)
  end

  # Extract the ownership ticket part, which has an expiration period of 21 days
  # Optionally also include the signature
  def ownership_ticket(sign = false)
    offset = TOKEN_LENGTH + SESSION_LENGTH + 12
    size = ticket.unpack1('L<', offset: offset)
    ticket[offset, size + (sign ? 128 : 0)]
  end

  # Check Steam's signature is present and valid
  def signed?
    signature && self.class.verify_signature(ownership_ticket, signature)
  end

  # We leave 5 minutes to spare, no point reusing a ticket at that point
  def expired?
    Time.now > expires - 5 * 60
  end

  # Dump ticket in ASCII
  def ascii
    ticket.unpack1('H*').upcase
  end

  # Refresh the token of this ticket. If expired, generates a fresh ticket altogether.
  def refresh(username: nil, password: nil, token: nil, file: nil)
    tkt = !expired? ? ownership_ticket(true).unpack1('H*') : nil
    self.class.generate(app_id, username: username, password: password, token: token, ticket: tkt, file: file)
  end

  private

  # This function will run when the object is initialized, thus giving access to
  # the new attributes that are not present in the db directly but rather parsed
  # from the raw ticket afterwards
  def parse
    return unless ticket
    self.class.parse(ticket).each_pair{ |name, value|
      next if ['steam_id', 'app_id', 'ticket'].include?(name)
      self.send("#{name}=".to_sym, value)
    }
  end
end

# See "Socket Variables" in constants.rb for docs
module Sock extend self
  @@servers = {}

  # Stops all servers
  def self.off
    @@servers.keys.each{ |s| Sock.stop(s) }
  end

  # Start a basic HTTP server at the specified port
  def start(port, name)
    # Create WEBrick HTTP server
    @@servers[name] = WEBrick::HTTPServer.new(
      Port: port,
      AccessLog: [
        [$stdout, "#{name} %h %m %U"],
        [$stdout, "#{name} %s %b bytes %T"]
      ]
    )
    # Setup callback for requests (ensuring we are connected to SQL)
    @@servers[name].mount_proc '/' do |req, res|
      action_inc('http_requests')
      acquire_connection
      handle(req, res)
      release_connection
    end
    # Start server (blocks thread)
    log("Started #{name} server")
    @@servers[name].start
  rescue => e
    lex(e, "Failed to start #{name} server")
  end

  # Stops server, needs to be summoned from another thread
  def stop(name)
    @@servers[name].shutdown
    log("Stopped #{name} server")
  rescue => e
    lex(e, "Failed to stop #{name} server")
  end

  # Ensure certain required parameters are present in the URL query (works for GET, not POST)
  def enforce_params(req, res, params)
    missing = params - req.query.keys
    return true if missing.empty?
    missing = missing.map{ |par| '"' + par + '"' }.join(', ')
    res.status = 400
    res.body = "Parameters #{missing} missing."
    false
  end

  # Return a client error whenever they mess up
  def client_error(res, msg = 'Unable to parse request', code = 400)
    res.status = code
    res.body = msg
    nil
  end

  # Return a server error whenever we mess up
  def server_error(res, msg = 'Unable to process request', code = 500)
    res.status = code
    res.body = msg
    nil
  end

  # Verifies if a file exists, otherwise returns a 404
  def check_file(res, path)
    return true if File.file?(path)
    client_error(res, 'File not found', 404)
    false
  end

  # Get the MIME type of a file given the name
  def get_mimetype(filename)
    table = WEBrick::HTTPUtils::DefaultMimeTypes
    WEBrick::HTTPUtils.mime_type(filename, table)
  end

  # Send arbitrary data or an arbitrary file as a response
  def send_data(res, data: nil, file: nil, type: nil, name: nil, inline: true, cache: nil, binary: true, compress: nil)
    # Data must be provided either directly or in a file
    if !data && !file
      return server_error(res)
    elsif !data && file
      return unless check_file(res, file)
      name ||= file
      data = binary ? File.binread(file) : File.read(file)
    end

    # Optionally compress the body
    encoding = nil
    if compress
      compress.split(',').each{ |method|
        case method.strip
        when 'gzip', 'x-gzip'
          data = Zlib.gzip(data)
          encoding = 'gzip'
          break
        when 'deflate'
          data = Zlib.deflate(data)
          encoding = 'deflate'
          break
        end
      }
    end

    # Determine value of headers (cache and content disposition)
    disposition = inline ? 'inline' : 'attachment'
    cache = case cache
    when true
      'public, max-age=31536000, immutable'
    when false
      'no-cache'
    when Integer
      cache > 0 ? "public, max-age=#{cache}, immutable" : 'no-cache'
    else
      nil
    end

    # Set HTTP headers, code and body
    res['Content-Type']        = type || get_mimetype(name)
    res['Content-Length']      = data.bytesize
    res['Content-Disposition'] = "#{disposition}; filename=\"#{File.basename(name) || 'data.bin'}\""
    res['Content-Encoding']    = encoding if encoding
    res['Cache-Control']       = cache if cache
    res.status = 200
    res.body = data
  end
end

module NPPServer extend self
  extend Sock

  def on
    start(SOCKET_PORT, 'CLE')
  end

  def off
    stop('CLE')
  end

  def handle(req, res)
    # Ignore empty requests
    return respond(res) if req.path.strip == '/'

    # Parse request parameters
    mappack = req.path.split('/')[1][/\w+/i]
    method  = req.request_method
    query   = req.path.sub(METANET_PATH, '').split('/')[2..-1].join('/')

    # Log POST bodies
    if $log[:socket] && method == 'POST'
      timestamp = Time.now.strftime('%Y-%m-%d-%H-%M-%S-%L')
      File.binwrite(File.join(DIR_LOGS, sanitize_filename(query) + '_' + timestamp), req.body)
    end

    # Always log players in, regardless of mappack
    return respond(res, Player.login(mappack, req)) if method == 'POST' && query == METANET_POST_LOGIN

    # Automatically forward requests for unknown or disabled mappacks
    return fwd(req, res) if !Mappack.find_by(enabled: true, code: mappack)

    # CUSE requests only affect userlevel searching
    if mappack == 'cuse'
      return fwd(req, res) unless method == 'GET' && query == METANET_GET_SEARCH
      return respond(res, Userlevel.search(req))
    end

    # Parse request
    body = 0
    case method
    when 'GET'
      case query
      when METANET_GET_SCORES
        body = MappackScore.get_scores(mappack, req.query.map{ |k, v| [k, v.to_s] }.to_h, req)
      when METANET_GET_REPLAY
        body = MappackScore.get_replay(mappack, req.query.map{ |k, v| [k, v.to_s] }.to_h, req)
      when METANET_GET_SEARCH
        body = Userlevel.search(req)
      end
    when 'POST'
      req.continue # Respond to "Expect: 100-continue"
      case query
      when METANET_POST_SCORE
        body = Scheduler.with_lock do # Prevent restarts during score submission
          MappackScore.add(mappack, req.query.map{ |k, v| [k, v.to_s] }.to_h, req)
        end
      when METANET_POST_LOGIN
        body = Player.login(mappack, req)
      end
    end

    body == 0 ? fwd(req, res) : respond(res, body)
  rescue => e
    action_inc('http_errors')
    lex(e, "CLE socket failed to parse request for: #{req.path}")
    nil
  end

  def respond(res, body = nil)
    if body.nil?
      res.status = 400
      res.body = ''
    else
      res.status = 200
      res.body = body
    end

    # Log response body in terminal (plain text) or file (binary)
    return if !$log[:socket]
    if !body || body.encoding.name == 'UTF-8'
      dbg('CLE Response: ' + (body || 'No body'))
    else
      timestamp = Time.now.strftime('%Y-%m-%d-%H-%M-%S-%L')
      File.binwrite(File.join(DIR_LOGS, 'res_' + timestamp), body)
    end
  end

  def fwd(req, res)
    respond(res, CLE_FORWARD ? forward(req) : nil)
  end
end

module APIServer extend self
  extend Sock

  def on
    start(API_PORT, 'API')
  end

  def off
    stop('API')
  end

  def handle(req, res)
    res.status = 403
    res.body = ''
    path = req.path.strip[1..]
    query = req.query.map{ |k, v| [k, v.to_s] }.to_h
    return if path =~ /\.\./i
    route = path.split('/').first
    compress = req.header['accept-encoding'][0]
    case req.request_method
    when 'GET'
      case route
      when nil
        send_data(res, data: build_page('home'){ handle_home() }, name: 'index.html', compress: compress)
      when 'favicon.ico'
        send_data(res, file: File.join(PATH_ICONS, API_FAVICON + '.ico'), cache: true)
      when 'api'
        send_data(res, file: path, cache: true, compress: compress)
      when 'git'
        link = "<a href=\"#{GITHUB_LINK}\">outte++ <img src=\"octicon/repo_12.svg\"></a>"
        body = build_page('git', "Latest changes to the #{link} repo in GitHub") { handle_git(query) }
        send_data(res, data: body, name: 'git.html', compress: compress, cache: true)
      when 'img'
        send_data(res, file: path, cache: true)
      when 'octicon'
        file = path.split('/').last
        name, size, color = file.remove('.svg').split('_')
        send_data(res, data: build_octicon(name, size, color), name: file, cache: true)
      when 'scores'
        body = build_page('scores', 'Show the latest submitted top20 highscores to vanilla leaderboards'){ handle_scores(query) }
        send_data(res, data: body, name: 'scores.html', compress: compress)
      when 'run'
        body = build_page('run', 'Show information about a given run') { handle_run(query) }
        send_data(res, data: body, name: 'run.html', compress: compress, cache: true)
      end
    when 'POST'
      req.continue # Respond to "Expect: 100-continue"
      query = req.query_string.split('&').map{ |s| s.split('=') }.to_h
      case route
      when 'screenshot'
        ret = handle_screenshot(query, req.body)
        if !ret.key?(:file)
          client_error(res, ret[:msg] || 'Unknown query error')
        elsif !ret[:file]
          server_error(res, 'Error generating screenshot')
        else
          send_data(res, data: ret[:file], name: ret[:name])
        end
      end
    end
  rescue => e
    lex(e, "API socket failed to parse request for: #{req.path}")
    handle_error(res, 'Failed to handle request')
  end

  # Fetch a file for the API to server
  def fetch_file(file)
    File.join(DIR_API, file)
  end

  # Retrieves a timestamp to use for file versioning (cache busting)
  def file_timestamp(file)
    File.mtime(fetch_file(file)).to_i.to_s
  end

  # Replace a token string in an HTML template with an actual value
  def replace_token(file, token, value)
    file.gsub!('TOKEN' + token, value)
  end

  # Escape plain HTML text
  def escape_html(str)
    str.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end

  # Concatenate path and query properly to form a valid URI route
  def make_route(path, query = {}, add: {}, remove: [], off: nil, rev: nil, page: nil)
    query = query.merge(add.stringify_keys).except('off', 'rev', 'p', *remove.map(&:to_s))
    query['p']   = page.to_i if page
    query['off'] = off.to_i if off
    query['rev'] = rev ? 1 : 0 if !rev.nil?
    return path if query.empty?
    query = query.map{ |k, v| "#{k}=#{v}" }.join('&')
    "#{path}?#{query}"
  end

  # Build home page
  def handle_home
    ''
  end

  # Template for all public API webpages
  def build_page(title, desc = nil, &block)
    # Build content
    time = Time.now
    content = yield
    content.prepend("#{create_minitable(title, desc, time)}\n<br>\n") if desc

    # Edit tokens into template
    html = File.read(fetch_file(API_TEMPLATE))
    replace_token(html, 'CSS',     file_timestamp(API_STYLE))
    replace_token(html, 'JS',      file_timestamp(API_SCRIPT))
    replace_token(html, 'TITLE',   title)
    replace_token(html, 'CONTENT', content)
    html
  end

  # Builds the mini table at the top
  def build_minitable(fields)
    rows = fields.map{ |k, v|
      "<tr><td class=\"catName\">#{k}:</td><td class=\"catValue\">#{v}</td></tr>"
    }.join("\n")
    "<table>\n#{rows}\n</table>"
  end

  # Fills the minitable fields
  def create_minitable(name, desc, time)
    build_minitable({
      'Description'     => desc,
      'Request time'    => Time.now.strftime('%F %T %Z'),
      'Processing time' => "%.2f ms" % [1000 * (Time.now - time)]
    })
  end

  # Build navigation bar for browsing lists or tables
  def build_navbar(route, params, first: nil, last: nil, page: nil, pages: nil, size: nil)
    if page          # Page-based navigation
      [
        page > 1 ? %{<a href="#{make_route(route, params, page: 1)}" tooltip="First"><img src="octicon/move-to-start_16.svg" alt="Previous"></a>} : nil,
        page > 1 ? %{<a href="#{make_route(route, params, page: page - 1)}" tooltip="Previous"><img src="octicon/arrow-left_16.svg" alt="Previous"></a>} : nil,
        size ? "#{(page - 1) * size + 1} - #{page * size}" : "#{page} / #{pages}",
        page < pages ? %{<a href="#{make_route(route, params, page: page + 1)}" tooltip="Next"><img src="octicon/arrow-right_16.svg" alt="Next"></a>} : nil,
        page < pages ? %{<a href="#{make_route(route, params, page: pages)}" tooltip="Last"><img src="octicon/move-to-end_16.svg" alt="Last"></a>} : nil
      ].compact.join("\n")
    else             # Offset-based navigation
      [
        %{<a href="#{make_route(route, params)}" tooltip="First"><img src="octicon/move-to-start_16.svg" alt="Previous"></a>},
        first ? %{<a href="#{make_route(route, params, off: first, rev: true)}" tooltip="Previous"><img src="octicon/arrow-left_16.svg" alt="Previous"></a>} : nil,
        last ? %{<a href="#{make_route(route, params, off: last)}" tooltip="Next"><img src="octicon/arrow-right_16.svg" alt="Next"></a>} : nil,
        %{<a href="#{make_route(route, params, off: 0, rev: true)}" tooltip="Last"><img src="octicon/move-to-end_16.svg" alt="Last"></a>}
      ].compact.join("\n")
    end
  end

  # Return list of latest highscores
  def handle_scores(params)
    time = Time.now

    # Sanitize parameters
    allowed = ['off', 'rev', 'id', 'player', 'type', 'tab']
    params.reject!{ |k, v| !allowed.include?(k) }
    if params['off']
      if is_num(params['off'])
        params['off'] = params['off'].to_i.clamp(0, 2 ** 31 - 1).to_s
      else
        params.delete('off')
      end
    end
    params.delete('type') if params['type'] && !(0..2).cover?(params['type'].to_i)
    params.delete('tab') if params['tab'] && !(0..6).cover?(params['tab'].to_i)
    params.delete('id') if !params['type']

    # Parse query parameters
    offset = params['off'].to_i if params['off']
    rev = params['rev'] == '1'
    type = TYPES.find{ |k, v| v[:id] == params['type'].to_i }.last if params['type']
    id = params['id'].to_i if params['id']
    player = params['player'].to_i if params['player']
    tab = params['tab'].to_i if params['tab']

    # Format table header
    header = %{
      <tr class="data">
        <th tooltip="Score ID in outte's db">Index</th>
        <th tooltip="Score ID in Metanet's db">ID</th>
        <th tooltip="Player ID in Metanet's db">Player ID</th>
        <th tooltip="Latest recorded name">Player name</th>
        <th tooltip="Level / Episode / Story / Userlevel">Board type</th>
        <th tooltip="Internal ID">Board ID</th>
        <th tooltip="Standard ID">Board</th>
        <th tooltip="Rank for non-obsolete highscores">Rank</th>
        <th tooltip="Score in seconds">Score</th>
        <th tooltip="Run length / framecount">Frames</th>
        <th tooltip="Pieces of gold collected">Gold</th>
        <th tooltip="Date of archival">Date</th>
        <th class="tight" tooltip="Obsolete run">O</th>
        <th class="tight" tooltip="Cheated run">C</th>
      </tr>
    }

    # Fetch scores
    size = 50
    list = Archive.where(offset ? "id #{rev ? '>' : '<'} #{offset}" : '')
                  .where(type   ? { highscoreable_type: type[:name] } : nil)
                  .where(id     ? { highscoreable_id:   id          } : nil)
                  .where(player ? { metanet_id:         player      } : nil)
                  .where(tab    ? { tab:                tab         } : nil)
                  .order(date: rev ? :asc : :desc)
                  .limit(size)
                  .pluck(
                    :id,         :replay_id, :metanet_id, :highscoreable_id, :score,
                    :framecount, :gold,      :date,       :expired,          :cheated,
                    :highscoreable_type
                  )
    list.reverse! if rev
    attrs = list.transpose
    pnames = Player.where(metanet_id: attrs[2]).pluck(:metanet_id, :name).to_h
    lnames = [
      Level.where(id: attrs[3]).pluck(:id, :name).to_h,
      Episode.where(id: attrs[3]).pluck(:id, :name).to_h,
      Story.where(id: attrs[3]).pluck(:id, :name).to_h
    ]
    ranks = Score.where(replay_id: attrs[1]).pluck(:replay_id, :rank).to_h

    # Format table rows
    yes = '<div class="icon-yes"></div>'
    no = '<div class="icon-no"></div>'
    rows = list.map{ |s|
      player_uri = make_route('scores', params, add: { player: s[2] })
      board_uri = make_route('scores', params, add: { type: TYPES[s[10]][:id], id: s[3] })
      replay_uri = make_route('run', { type: TYPES[s[10]][:id], id: s[1] })
      date = s[7] <= Archive::EPOCH ? "Before #{Archive::EPOCH.strftime('%F')}" : s[7].strftime('%F %T')
      %{
        <tr class="data">
        <td class="numeric">#{s[0]}</td>
        <td class="numeric">#{s[1]}</td>
        <td class="numeric">#{s[2]}</td>
        <td class="text"><a href="#{player_uri}">#{escape_html(pnames[s[2]][0, 16])}</a></td>
        <td class="normal">#{s[10]}</td>
        <td class="numeric">#{s[3]}</td>
        <td class="normal"><a href="#{board_uri}">#{lnames[TYPES[s[10]][:id]][s[3]]}</a></td>
        <td class="numeric#{ranks[s[1]] == 0 ? ' on' : ''}">#{ranks[s[1]]}</td>
        <td class="numeric"><a href="#{replay_uri}">#{'%.3f' % [s[4] / 60.0]}</a></td>
        <td class="numeric">#{s[5]}</td>
        <td class="numeric">#{s[6]}</td>
        <td class="normal">#{date}</td>
        <td class="normal tight">#{s[8] ? yes : no}</td>
        <td class="normal tight">#{s[9] ? yes : no}</td>
        </tr>
      }
    }.join("\n")

    # Format table caption with filters
    if attrs[0]
      navbar = build_navbar('scores', params, first: attrs[0].max, last: attrs[0].min)
    elsif params['off']
      navbar = build_navbar('scores', params)
    end
    types = TYPES.map{ |name, att|
      #next att[:name] if type && att[:id] == type[:id]
      route = make_route('scores', params, add: { type: att[:id] }, remove: [:id])
      "<a href=\"#{route}\" tooltip=\"#{att[:name].pluralize} scores\">#{att[:name]}</a>"
    }
    types.prepend("<a href=\"#{make_route('scores', params, remove: [:type])}\" tooltip=\"All types\">All</a>")
    types = types.join("\n")

    tabs = TABS_SOLO.sort_by{ |_, v| v[:index] }.map{ |_, att|
      #next att[:code] if att[:tab] == tab
      route = make_route('scores', params, add: { tab: att[:tab] }, remove: [:id])
      "<a href=\"#{route}\" tooltip=\"#{att[:name]} scores\">#{att[:code]}</a>"
    }
    tabs.prepend("<a href=\"#{make_route('scores', params, remove: [:tab])}\" tooltip=\"All tabs\">All</a>")
    tabs = tabs.join("\n")
    players = "<a href=\"#{make_route('scores', params, remove: [:player])}\" tooltip=\"All players\">All</a>"
    caption = %{
      <caption>
        <div class="separated">
          <span>
            <b>Type</b>: #{types} | <b>Tab</b>: #{tabs} | <b>Players</b>: #{players}
          </span>
          <span>
            #{navbar}
          </span>
        </div>
      </caption>
    }

    # Format table
    %{
      <table class=\"data\">
        #{caption}
        #{header}
        #{rows}
      </table>
    }
  end

  # Show information about a particular run
  def handle_run(params)
    time = Time.now
    type = TYPES.find{ |k, v| v[:id] == params['type'].to_i }.last

    # Form for manually choosing type and replay ID
    default_ids = []
    options = TYPES.map{ |k, v|
      default = Archive.where(highscoreable_type: v[:name]).last.replay_id
      default_ids << default
      selected = params['type'].to_i == v[:id] ? 'selected' : ''
      "<option value=\"#{v[:id]}\" data-default=\"#{default}\" #{selected}>#{v[:name]}</option>"
    }.join
    default_id = params['id'] ? params['id'].to_i : default_ids[type[:id]]
    form = %{
      <form class="centerH">
        <div style="display: grid; grid-template-columns: auto 60px; gap: 4px; align-items: center;">
          <label for="htype">Type:</label>
          <select id="htype" name="type" required style="width: 100%%;">
            #{options}
          </select>
        </div>
        <div style="display: grid; grid-template-columns: auto 60px; gap: 4px; align-items: center;">
          <label for="hid">ID:</label>
          <input id="hid" name="id" inputmode="numeric" maxlength="7" value="#{default_id}" required style="width: 100%%;">
        </div>
        <button type="submit">Get</button>
      </form>
    }
    err = "#{form}\n<br><br>\n<div class=\"off\" style=\"text-align: center;\">%s</div>"

    # Parse parameters
    allowed = ['id', 'type']
    params.reject!{ |k, v| !allowed.include?(k) }
    return err % '' if !params['type'] && !params['id']
    params.delete('type') if !is_num(params['type']) || !(0..2).cover?(params['type'].to_i)
    params.delete('id') if !is_num(params['id']) || !(0..9999999).cover?(params['id'].to_i)
    return err % 'Please specify a valid type' if !params['type']
    return err % 'Please specify a valid ID' if !params['id']

    # Fetch run
    run = Archive.find_by(highscoreable_type: type[:name], replay_id: params['id'].to_i)
    return err % "Run not found in database" if !run
    h = run.highscoreable
    s = run.highscore
    p = run.player
    d = run.demo

    # Embedded binary data in Base64 (map, replay and attract files)
    replay_data = d.demo if d
    if h.is_level?
      map_data = h.map.dump_level
      if replay_data
        demo_data    = h.dump_demo(Demo.decode(replay_data, true))
        attract_data = [map_data.size - 8, demo_data.size, map_data[8..], demo_data].pack('L<2a*a*')
      end
    end

    # Links
    route_board   = make_route('scores', { type: run.highscoreable_type, id: run.highscoreable_id })
    route_player  = make_route('scores', { player: run.metanet_id })
    route_map     = "data:application/octet-stream;base64,#{Base64.encode64(map_data)}"     if map_data
    route_replay  = "data:application/octet-stream;base64,#{Base64.encode64(replay_data)}"  if replay_data
    route_attract = "data:application/octet-stream;base64,#{Base64.encode64(attract_data)}" if attract_data
    url_board   = "<a href=\"#{route_board}\">#{escape_html(h.name[0, 24])}</a>"
    url_player  = "<a href=\"#{route_player}\">#{escape_html(p.name[0, 24])}</a>"
    url_map     = "<a href=\"#{route_map}\" download=\"#{sanitize_filename(h.name)}\" tooltip=\"Map file for the editor\">Map</a>" if route_map
    url_replay  = "<a href=\"#{route_replay}\" download=\"replay\" tooltip=\"Gzipped, suitable for nclone\">Replay</a>" if route_replay
    url_attract = "<a href=\"#{route_attract}\" download=\"#{h.id % 2 ** 16}\" tooltip=\"Suitable for N++ main menu, TAS tool...\">Attract</a>" if route_attract
    urls = [url_map, url_replay, url_attract].compact.join(', ')

    # Run properties
    attrs = [
      ['outte++ ID',        "", run.id],
      ['Replay ID',         "", run.replay_id],
      ['Player ID',         "", run.metanet_id],
      ['Player name',       "", url_player],
      ['Board type',        "", run.highscoreable_type],
      ['Board internal ID', "", run.highscoreable_id],
      ['Board usual ID',    "", url_board],
      ['Board name',        "", h.is_level? ? h.longname : nil],
      ['Rank',              "", s ? s.rank : 'No longer a highscore'],
      ['Score',             "", '%.3f' % [run.score / 60.0]],
      ['Frame count',       "", run.framecount],
      ['Gold count',        "", run.gold],
      ['Date of archival',  "", run.date],
      ['Obsolete run',      run.expired ? 'on' : 'off', run.expired.to_s.capitalize],
      ['Cheated run',       run.cheated ? 'on' : 'off', run.cheated.to_s.capitalize],
      ['Download',          "", urls]
    ].reject{ |a, b, c| !c }.map{ |a, b, c|
      cls = !b.empty? ? " class=\"#{b}\"" : ''
      "<tr><td><b>#{a}:</b></td><td#{cls}>#{c}</td></tr>"
    }.join("\n")

    prop_table = %{
      <table class="bordered">
        #{attrs}
      </table>
    }

    # Demo analysis
    if !d
      analysis = "<div class=\"off\">Replay not found in database</div>"
    elsif !h.is_level?
      analysis = "#{type[:name]} replays can't be analyzed yet."
    else
      bytes = d.decode
      inputs = bytes.map{ |b| [b & 4 > 0, b & 1 > 0, b & 2 > 0] } # LJR
      n = bytes.size.to_s.length
      codes = ['←', '↑', '→']

      # Condensed format
      yes = '<div class="icon-yes"></div>'
      no = '<div class="icon-no"></div>'
      frame = 0
      rows = bytes.chunk(&:itself).map{ |b, list|
        f = [b & 4 > 0, b & 1 > 0, b & 2 > 0]
        len = list.length
        frame += len
        [
          frame - len,
          frame - 1,
          len,
          (f[0] ? 'L' : '') + (f[2] ? 'R' : '') + (f[1] ? 'J' : ''),
          f[0] ? yes : no,
          f[1] ? yes : no,
          f[2] ? yes : no
        ].map{ |str| "<td>#{str}</td>" }.join
      }.map{ |row| "<tr>#{row}</tr>" }.join("\n")
      analysis0 = %{
        <table class="inputs">
        <tr><th>Start</th><th>End</th><th>Length</th><th>Input</th><th>L</th><th>J</th><th>R</th></tr>
        #{rows}
        </table>
      }

      # Table format
      rows = inputs.map.with_index{ |f, i|
        [
          i.to_s.rjust(n, '0'),
          *f.map.with_index{ |b, j| b ? codes[j] : '' }
        ].map{ |str| "<td>#{str}</td>" }.join
      }.map{ |row| "<tr>#{row}</tr>" }.join("\n")
      analysis1 = %{
        <table class="inputs">
        <tr><th>Frame</th><th>L</th><th>J</th><th>R</th></tr>
        #{rows}
        </table>
      }

      # Symbolic format
      symbols = "·↑→↗←↖←↖"
      rows = bytes.map{ |b| symbols[b] }.each_slice(60).with_index.map{ |row, i|
        "<tr><td>#{(60 * i).to_s.rjust(n, '0')}</td><td>#{row.join('</td><td>')}</td></tr>"
      }.join("\n")
      analysis2 = %{
        <table>
        #{rows}
        </table>
      }

      # Literal format
      analysis3 = inputs.map{ |f|
        (f[0] ? 'L' : '') + (f[2] ? 'R' : '') + (f[1] ? 'J' : '')
      }.join(".")

      # Select menu
      views = [
        'Condensed', 'Table', 'Symbolic', 'Literal'
      ].map.with_index{ |opt, i|
        selected = i == 0 ? ' selected' : ''
        "<option value=\"#{i}\"#{selected}>#{opt}</option>"
      }.join("\n")

      # Analysis box
      analysis = %{
        <div style="gap:4px;">
          View:
          <select id="demo-analysis-view">
            #{views}
          </select>
          <div class="text-box" style="max-width:50vw;max-height:40ex" id="demo-analysis-content">
            <div data-view="0">#{analysis0}</div>
            <div data-view="1" hidden>#{analysis1}</div>
            <div data-view="2" hidden>#{analysis2}</div>
            <div data-view="3" hidden>#{analysis3}</div>
          </div>
        </div>
      }
    end

    # Final body
    %{
      <div style="display: grid; grid-template-columns: max-content max-content max-content; gap: 4px; align-items: start; justify-content: center;">
        #{form}
        #{prop_table}
        #{analysis}
      </div>
    }
  end

  # Latest changes to the project using GitHub's API
  def handle_git(params)
    # Pagination
    count = 25
    page = [params['p'].to_i, 1].max
    total = `git rev-list --count --all`.to_i
    pag = compute_pages(total, page, count)

    # Header
    header = ['Commit', 'Description', 'Author', 'Branch', 'Changes', 'Date'].map{ |th| "<th>#{th}</th>" }.join("\n")

    # Parse commits
    raw = `git log -n #{count} --skip=#{pag[:offset]} --decorate=full --date=iso-strict --numstat --format='@@@%H|%D|%cI|%an|%ae|%cn|%ce|%s%n%B'`
    commits = []
    current = nil

    raw.each_line do |line|
      if line.start_with?("@@@")             # New commit
        commits << current if current

        # First line after sentinel (@@@) contains basic commit fields
        hash, refs, date, aname, amail, cname, cmail, msg = line[3..].split("|")

        # Parse refs (branches and tags)
        branches = []
        tags = []
        refs.split(",").each do |ref|
          next if ref =~ /remotes/i
          ref.sub!(/HEAD ->/, '')
          ref.strip!
          case ref
          when /^refs\/heads\//
            branches << ref.sub('refs/heads/', '')
          when /^refs\/tags\//
            tags << ref.sub('refs/tags/', '')
          end
        end

        # New commit block
        current = {
          hash: hash,
          date: date,
          author: {
            name:  aname,
            email: amail
          },
          committer: {
            name:  cname,
            email: cmail
          },
          description: msg,
          extended: '',
          files: {},
          changes: 0,
          additions: 0,
          deletions: 0,
          branches: branches,
          tags: tags
        }
      elsif line =~ /^(\d+)\s+(\d+)\s+(.+)$/ # File changes
        add, del, name = $1.to_i, $2.to_i, $3
        current[:changes] += 1
        current[:additions] += add
        current[:deletions] += del
        current[:files][name] = [add, del]
      elsif line.strip.empty?                # Empty line
        # Ignore
      else                                   # Remainder of description
        current[:extended] << line
      end
    end

    # Add final commit
    commits << current if current

    # Rows
    rows = commits.map{ |comm|
      commit = "<a href=\"#{GITHUB_LINK}/commit/#{comm[:hash]}\" tooltip=\"#{comm[:hash]}\">#{comm[:hash][0, 7]}</a>"
      author = "<a href=\"https://github.com/#{comm[:author][:name]}?tab=repositories/\">#{comm[:author][:name]}</a>"
      branches = "<a href=\"#{GITHUB_LINK}/tree/#{comm[:hash]}\">master</a>"
      %{
        <tr>
          <td><img src="octicon/git-commit_12.svg"> #{commit}</td>
          <td>#{comm[:description][0, 128]}</td>
          <td><img src="octicon/person_12.svg"> #{author}</td>
          <td><img src="octicon/git-branch_12.svg"> #{branches}</td>
          <td>#{comm[:changes]} (<span class="on">+#{comm[:additions]}</span>, <span class="off">-#{comm[:deletions]}</span>)</td>
          <td>#{comm[:date]}</td>
        </tr>
      }
    }.join("\n")

    # Format table
    %{
      <table class=\"data\">
        <caption>
          #{build_navbar('git', params, page: pag[:page], pages: pag[:pages], size: count)}
        </caption>
        #{header}
        #{rows}
      </table>
    }
  end

  def handle_screenshot(params, payload)
    # Parse highscoreable
    h = nil
    [Level, Episode, Story, Userlevel].each{ |type|
      id = params["#{type.to_s.downcase}_id"]
      next if !id
      ul = type == Userlevel
      key = ul ? :id : :name
      h = type.find_by(key => id)
      h = type.mappack.find_by(key => id) if !h && !ul
      return { msg: "#{type} #{id} not found" } if !h
    }
    return { msg: 'Highscoreable must be supplied via "level_id", "episode_id", "story_id" or "userlevel_id"' } if !h

    # Parse palette
    if payload && !payload.empty?
      changed = Map.change_custom_palette(payload)
      return { msg: 'Provided palette data is corrupt' } if !changed
      palette = 'custom'
    elsif params['palette']
      palette_idx = Map::THEMES.index(params['palette'])
      return { msg: "Palette #{params['palette']} doesn't exist" } if !palette_idx
      palette = Map::THEMES[palette_idx]
    else
      palette = 'vasquez'
    end

    # Generate screenshot
    filename = h.is_userlevel? ? h.id.to_s : h.name
    { file: Map.screenshot(palette, h: h), name: filename + '.png' }
  rescue => e
    lex(e, 'Failed to handle API screenshot request')
    { file: nil }
  end

  def handle_error(res, msg, code = 500)
    body = "<div class=\"centered title off\">#{msg}</div>"
    server_error(res, build_page('error'){ body })
  rescue => e
    lex(e, 'Failed to handle API error')
  end
end
