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
      new_streams.reject!{ |s| TWITCH_BLACKLIST.include?(s['user_name']) }

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

  # Send raw data as a response
  def send_data(res, data, type: 'application/octet-stream', name: nil, inline: true, cache: nil)
    disposition = inline ? 'inline' : 'attachment'
    res['Content-Type']        = type
    res['Content-Length']      = data.length
    res['Content-Disposition'] = "#{disposition}; filename=\"#{name || 'data.bin'}\""
    res['Cache-Control']       = "public, max-age=#{cache}" unless !cache
    res.status = 200
    res.body = data
  end

  # Sends a raw file as a response
  def send_file(res, file, type: 'application/octet-stream', name: nil, inline: true, cache: nil)
    if !File.file?(file)
      res.status = 404
      res.body = "File not found"
      return
    end
    send_data(res, File.binread(file), type: type, name: name || File.basename(file), inline: inline, cache: cache)
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
    route = req.path.split('/').last
    case req.request_method
    when 'GET'
      case route
      when nil
        res.status = 200
        res.body = "Welcome to outte's public API!"
      when 'favicon.ico'
        path = File.join(PATH_AVATARS, API_FAVICON + '.png')
        send_file(res, path, type: 'image/png', cache: 365 * 86400)
      end
    when 'POST'
      req.continue # Respond to "Expect: 100-continue"
      query = req.query_string.split('&').map{ |s| s.split('=') }.to_h
      case route
      when 'screenshot'
        ret = handle_screenshot(query, req.body)
        if !ret.key?(:file)
          res.status = 400
          res.body = ret[:msg] || 'Unknown query error'
        elsif !ret[:file]
          res.status = 500
          res.body = 'Error generating screenshot'
        else
          send_data(res, ret[:file], type: 'image/png', name: ret[:name])
        end
      end
    end
  rescue => e
    lex(e, "API socket failed to parse request for: #{req.path}")
    nil
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
end
