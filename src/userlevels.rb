# This file contains all the userlevel-specific functionality, both internally
# (downloading and parsing, performing rankings, etc), as well as externally
# (interacting with users in the server). Thus, it essentially represents the
# equivalent of both models.rb and messages.rb for userlevel functionality.
#
# There's significant duplication of code between this file and said files, which
# stems from the fact that it was originally made as independent as possible
# to prevent messing up Metanet functionality. Therefore, an interesting (but very
# time consuming) project for the future could be to integrate this file into
# the ones above, as it was done for mappacks from the beginning more recently.

require 'time'
require 'zlib'

# Contains map data (tiles and objects) in a different table for performance reasons.
class UserlevelData < ActiveRecord::Base
end

class UserlevelTab < ActiveRecord::Base
end

# Cache for userlevel queries made using outte's browser which may be sent
# to N++ players via the socket
class UserlevelCache < ActiveRecord::Base
  # Compute the key for a query result based on the IDs, which is used to key the cache
  def self.key(ids)
    str = ids.map{ |id| id.to_s.rjust(7, '0') }.join
    sha1(str, c: false, hex: true)
  end

  # Remove entries from cache that are either expired or over the allowable limit,
  # which are not currently assigned to any user
  def self.clean
    # Fetch caches not currently assigned to any user
    not_used = self.joins('LEFT JOIN users ON userlevel_caches.id = users.query')
                   .where('query IS NULL')

    # Date of last cache as per cache limit
    last_cache = not_used.order(date: :desc).offset(OUTTE_CACHE_LIMIT).first
    max_date_1 = last_cache ? last_cache.date : Time.now

    # Date of last cache as per expiration date
    max_date_2 = Time.now - OUTTE_CACHE_DURATION

    # Wipe caches below this max date
    not_used.where("date <= ?", [max_date_1, max_date_2].max).delete_all
    true
  rescue => e
    lex(e, 'Failed to clean userlevel query cache.')
    false
  end

  # Assign this query to a user, implying it will be sent to his game
  # The same query may be assigned to any number of users
  def assign(user)
    user.update(query: id)
    update(date: Time.now)
  end
end

class UserlevelAuthor < ActiveRecord::Base
  has_many :userlevels, foreign_key: :author_id
  has_many :userlevel_akas, foreign_key: :author_id
  alias_method :akas, :userlevel_akas

  # Parse a userlevel author based on a search term:
  # Integer:
  #   Search as the author ID
  # String:
  #   Search as part of the name, or optionally, also of the aka's (old names)
  # Number of results:
  #     0 - Raise error of no matches
  #     1 - Return author
  #   <20 - Print matches
  #  >=20 - Raise error of too many matches
  def self.parse(term = nil, aliases = true, event: nil, page: nil)
    term = parse_userlevel_author(parse_message(event)) if !term && event
    if term.is_a?(Integer)
      p = self.find(term) rescue nil
      perror("Userlevel author with ID #{verbatim(term)} not found.") if p.nil?
      return p
    end
    perror("Couldn't parse userlevel author.") if !term.is_a?(String)
    return nil if term.empty?
    p = self.where_like('name', term[0...16])
    multiple = "Authors by \"#{term}\" - Please refine name or use ID instead"

    case p.count
    when 0
      perror("No author found by the name #{verbatim(term)}.") if !aliases
      p = UserlevelAka.where_like('name', term[0...16]).map(&:author).uniq
      case p.count
      when 0
        perror("No author found by the name (current or old) #{verbatim(term)}.")
      when 1
        return p.first
      else
        perror("Too many author matches! (#{p.count}). Please refine author name.") if !event
        pager(event, page, header: multiple, list: p, rails: true, pluck: [:id, :name]){ |s|
          "#{"%6d" % s[0]} - #{s[1]}"
        }
      end
    when 1
      return p.first
    else
      perror("Too many author matches! (#{p.count}). Please refine author name.") if !event
      pager(event, page, header: multiple, list: p, rails: true, pluck: [:id, :name]){ |s|
        "#{"%6d" % s[0]} - #{s[1]}"
      }
    end
  rescue => e
    lex(e, 'Failed to parse userlevel author.')
    nil
  end

  # Add an A.K.A. to the author (old name)
  def aka(str, time)
    str = INVALID_NAMES.include?(str) ? '' : str
    return if !self.akas.where(name: str).empty?
    UserlevelAka.create(author_id: self.id, name: str, date: time)
  end

  # Change author name, taking restrictions into account
  def rename(str, time = nil)
    str = INVALID_NAMES.include?(str) ? '' : str
    self.update(name: str)
    aka(str, !time.nil? ? time : Time.now.strftime(DATE_FORMAT_MYSQL))
  end
end

class UserlevelAka < ActiveRecord::Base
  belongs_to :userlevel_author, foreign_key: :author_id
  alias_method :author, :userlevel_author
  alias_method :author=, :userlevel_author=
end

class UserlevelScore < ActiveRecord::Base
  belongs_to :userlevel
  belongs_to :userlevel_player, foreign_key: :player_id
  alias_method :player, :userlevel_player
  alias_method :player=, :userlevel_player=

  def self.newest(id = Userlevel.min_id)
    self.where("userlevel_id >= #{id}")
  end

  def self.global
    self
  end

  def self.retrieve_scores(full, mode = nil, author_id = nil)
    scores = full ? self.global : self.newest
    if !mode.nil? || !author_id.nil?
      scores = scores.joins("INNER JOIN userlevels ON userlevels.id = userlevel_scores.userlevel_id")
      if !mode.nil?
        scores = scores.where("userlevels.mode = #{mode.to_i}")
      end
      if !author_id.nil?
        scores = scores.where("userlevels.author_id = #{author_id.to_i}")
      end
    end
    scores
  end

  # Count top20 scores for all userlevels and fill their completions field
  # Delicate pure SQL, doable in Rails?
  def self.seed_completions(full = false)
    query = %{
      UPDATE
        userlevels,
        (
          SELECT userlevel_id AS uid, COUNT(userlevel_id) AS cnt
          FROM userlevel_scores
          GROUP BY userlevel_id
          ORDER BY uid ASC
        ) t
      SET userlevels.completions = t.cnt
      WHERE userlevels.completions < 20 AND userlevels.id = t.uid;
    }.gsub(/\s+/, ' ').strip
    sql(query)
    Userlevel.where(completions: nil).update_all(completions: 0)
  end

  def replay_uri(steam_id)
    npp_uri(:replay, steam_id, replay_id: replay_id, qt: 0 )
  end

  # Download demo on the fly
  def demo
    replay = get_data(
      -> (steam_id) { replay_uri(steam_id) },
      -> (data) { data },
      "Error downloading userlevel #{id} replay #{replay_id}"
    )
    perror("Error downloading userlevel replay") if replay.nil?
    perror("Selected replay seems to be missing") if replay.empty?
    Demo.parse(replay[16..-1], 'Level')
  end
end

class UserlevelPlayer < ActiveRecord::Base
  has_many :userlevel_scores, foreign_key: :player_id
  has_many :userlevel_histories, foreign_key: :player_id
  alias_method :scores, :userlevel_scores

  def print_name
    name.remove("`")
  end

  def newest(id = Userlevel.min_id)
    scores.where("userlevel_id >= #{id}")
  end

  def retrieve_scores(full = false, mode = nil, author_id = nil)
    query = full ? scores : newest
    return query.order(:rank) if !mode && !author_id
    query = query.joins("INNER JOIN `userlevels` ON `userlevels`.`id` = `userlevel_scores`.`userlevel_id`")
    query = query.where("`userlevels`.`mode` = #{mode.to_i}") if !!mode
    query = query.where("`userlevels`.`author_id` = #{author_id.to_i}") if !!author_id
    query.order(:rank)
  end

  def range_s(rank1, rank2, ties, full = false, mode = nil, author_id = nil)
    t  = ties ? 'tied_rank' : 'rank'
    retrieve_scores(full, mode, author_id).where("`#{t}` >= #{rank1} AND `#{t}` <= #{rank2}")
  end

  def range_h(rank1, rank2, ties, full = false, mode = nil, author_id = nil)
    range_s(rank1, rank2, ties, full, mode, author_id).group_by(&:rank).sort_by(&:first)
  end

  def top_ns(rank, ties, full = false, mode = nil, author_id = nil)
    range_s(0, rank - 1, ties, full, mode, author_id)
  end

  def top_n_count(rank, ties, full = false, mode = nil, author_id = nil)
    top_ns(rank, ties, full, mode, author_id).count
  end

  def range_n_count(a, b, ties, full = false, mode = nil, author_id = nil)
    range_s(a, b, ties, full, mode, author_id).count
  end

  def points(ties, full = false, mode = nil, author_id = nil)
    retrieve_scores(full, mode, author_id).sum(ties ? '20 - `tied_rank`' : '20 - `rank`')
  end

  def avg_points(ties, full = false, mode = nil, author_id = nil)
    retrieve_scores(full, mode, author_id).average(ties ? '20 - `tied_rank`' : '20 - `rank`')
  end

  def total_score(full = false, mode = nil, author_id = nil)
    retrieve_scores(full, mode, author_id).sum(:score).to_f / 60
  end

  def avg_lead(ties, full = false, mode = nil, author_id = nil)
    ss = top_ns(1, ties, full, mode, author_id)
    count = ss.length
    avg = count == 0 ? 0 : ss.map{ |s|
      entries = s.userlevel.scores.map(&:score)
      (entries[0].to_i - entries[1].to_i).to_f / 60.0
    }.sum.to_f / count
    avg || 0
  end
end

class UserlevelHistory < ActiveRecord::Base
  belongs_to :userlevel_player, foreign_key: :player_id
  alias_method :player, :userlevel_player
  alias_method :player=, :userlevel_player=

  # Transform rankings to history format ready to be created
  def self.compose(rankings, rank, time)
    rankings.select{ |r| r[1] > 0 }.map do |r|
      {
        timestamp:  time,
        rank:       rank,
        player_id:  r[0],
        count:      r[1]
      }
    end
  end

  # Compare current rankings with historic ones and compute differences
  def self.compare(r, time)
    type = r == -1 ? :points : :rank
    ties = r == 1

    # Fetch relevant histories to compare against
    last = where('timestamp <= ?', time).order(timestamp: :desc).first.timestamp
    histories = where(timestamp: last - 3600 .. last)

    # Fetch current and old rankings, compute differences
    ranking = Userlevel.rank(type, ties, r - 1).map.with_index{ |e, rank| [rank, *e] }
    ranking_prev = histories.where(rank: r)
                            .order(count: :desc)
                            .pluck(:player_id, :count)
                            .map.with_index{ |e, rank| [rank, *e] }
    diffs = ranking.map{ |rank, id, count, _|
      old_rank, _, old_count = ranking_prev.find{ |_, old_id, _| id == old_id }
      old_rank ? { rank: old_rank - rank, score: count - old_count } : nil
    }

    # Find padding and format leaderboard
    pad_name   = ranking.map(&:last).map(&:length).max
    pad_count  = ranking.map{ |o| o[2].to_s.length }.max
    pad_rank   = [diffs.compact.map{ |c| c[:rank].abs.to_s.length }.max.to_i, 2].max
    pad_change = diffs.compact.map{ |c| c[:score].abs.to_s.length }.max.to_i
    ranking = ranking.map.with_index{ |p, i|
      diff = ''
      score = "#{"%02d" % i}: #{format_string(p[3], pad_name)} - #{"%#{pad_count}d" % p[2]}"
      Highscoreable.format_diff_change(diffs[i], diff, true, pad_rank, pad_change)
      "#{score} #{diff}"
    }.join("\n")

    ranking
  end

  # Generate the highscoring report for a specific ranking type
  def self.report(type = 1)
    word = type > 0 ? format_rank(type).capitalize : 'Point'
    word += ' (w/ ties)' if type == 1
    header = mdtext("#{word} report (newest #{USERLEVEL_REPORT_SIZE} maps)", header: 2)
    diff = format_block(compare(type, Time.now - 12 * 60 * 60))
    header + "\n" + diff
  end
end

class Userlevel < ActiveRecord::Base
  include Downloadable
  include Highscoreable
  include Map
  include Levelish
  alias_attribute :name, :title
  has_many :userlevel_scores
  belongs_to :userlevel_author, foreign_key: :author_id
  alias_method :author,  :userlevel_author
  alias_method :author=, :userlevel_author=
  alias_method :scores,  :userlevel_scores
  create_enum(:mode, [:solo, :coop, :race])
  # Attributes:
  #   id           - ID of the userlevel in Metanet's database (and ours)
  #   author_id    - Map author user ID in Metanet's database (and ours)
  #   title        - Map title
  #   favs         - Number of favourites / ++s
  #   date         - Date of publishing, UTC times
  #   mode         - Playing mode [0 - Solo, 1 - Coop, 2 - Race]
  #   score_update - When the scores were last updated in the db
  #   map_update   - When the map properties (like favs) were last updated in the db
  #   tiles        - Tile data compressed in zlib, stored in userlevel_data
  #   objects      - Object data compressed in zlib, stored in userlevel_data
  # Note: For details about how map data is stored, see the encode_ and decode_ methods below.

  # TODO: Optimize this in a single query
  def self.dump_csv
    count = self.count
    csv = "id,author_id,author,title,favs,date,mode\n"
    csv << self.all.each_with_index.map{ |m, i|
      dbg("Dumping userlevel #{"%6d" % [i + 1]} / #{count}...", pad: true, newline: false)
      "#{m.id},#{m.author_id},#{m.author.name.tr(',', ';')},#{m.title.tr(',', ';')},#{m.favs},#{m.date.strftime(DATE_FORMAT_OUTTE)},#{m.mode.to_i}"
    }.join("\n")
    Log.clear
    csv
  end

  def self.mode(mode)
    mode == -1 ? Userlevel : Userlevel.where(mode: mode)
  end

  def self.tab(qt, mode = -1)
    query = Userlevel::mode(mode)
    query = query.joins('INNER JOIN userlevel_tabs ON userlevel_tabs.userlevel_id = userlevels.id')
                 .where("userlevel_tabs.qt = #{qt}") if qt != QT_NEWEST
    query
  end

  def self.levels_uri(steam_id, qt = QT_NEWEST, page = 0, mode = MODE_SOLO)
    npp_uri(:levels, steam_id, qt: qt, mode: mode, page: page)
  end

  def self.serial(maps)
    maps.map{ |m|
      {
        id:     m.id,
        author: (m.author.name rescue ""),
        title:  m.title,
        date:   m.date.strftime(DATE_FORMAT_OUTTE),
        favs:   m.favs
      }
    }
  end

  def self.get_levels(qt = QT_NEWEST, page = 0, mode = MODE_SOLO)
    uri  = Proc.new { |steam_id, qt, page, mode| Userlevel::levels_uri(steam_id, qt, page, mode) }
    data = Proc.new { |data| data }
    err  = "error querying page #{page} of userlevels from category #{qt}"
    get_data(uri, data, err, qt, page, mode)
  end

  # For compatibility with Level, Episode and Story
  def self.mappack
    Userlevel
  end

  #----------------------------------------------------------------------------#
  #                       USERLEVEL QUERY DOCUMENTATION                        |
  #----------------------------------------------------------------------------#
  # File structure                                                             |
  #   Global header (48B)                                                      |
  #   Map headers (44B each)                                                   |
  #   Map data blocks                                                          |
  #----------------------------------------------------------------------------#
  # Global header structure                                                    |
  #    16B - Query date in %Y-%m-%d-%H:%M format, seems approximate            |
  #     4B - Map count                                                         |
  #     4B - Page number                                                       |
  #     4B - Type (0 = Level, 1 = Episode, 2 = Story). Always 0.               |
  #     4B - Query type (0 - 37), see QT_ enum                                 |
  #     4B - Game mode (0 = Solo, 1 = Coop, 2 = Race, 3 = HC)                  |
  #     4B - Cache duration in seconds (usually 5 or 1200)                     |
  #     4B - Max page size (usually 500, sometimes 25)                         |
  #     4B - Unknown field (usually 0 or 5)                                    |
  #----------------------------------------------------------------------------#
  # Map header structure                                                       |
  #     4B - Userlevel ID (first one is 22715)                                 |
  #     4B - Author ID, -1 if not found                                        |
  #    16B - Author name, truncated                                            |
  #     4B - Favourite (++) count                                              |
  #    16B - Date in %Y-%m-%d-%H:%M format                                     |
  #----------------------------------------------------------------------------#
  # Map data block structure                                                   |
  #     4B - Block length, including 6B mini-header                            |
  #     2B - Object count                                                      |
  #   Rest - Zlib-compressed map data (see dump_level for documentation)       |
  #----------------------------------------------------------------------------#

  # Parse binary file with userlevel collection received from N++'s server
  def self.parse(buffer)
    buffer = StringIO.new(buffer.to_s)
    return false if buffer.size <= 48

    # Parse header (48B)
    header = Struct.new(:date, :count, :page, :type, :qt, :mode, :cache, :max, :unknown)
                   .new(*ioparse(buffer, 'a16l<8'))
    return false if !USERLEVEL_TABS.key?(header.qt) || header.count <= 0

    # Parse map headers (44B each)
    rawMap = Struct.new(:id, :author_id, :author, :favs, :date, :count, :title, :tiles, :objects)
    maps = Array.new(header.count).map do
      rawMap.new(*ioparse(buffer, 'l<2a16l<a16')).tap do |map|
        map.author = parse_str(map.author)
        map.date = Time.strptime(map.date, DATE_FORMAT_NPP)
      end
    end

    # Update relationships (return true if there are pages left to update)
    if header.qt != QT_NEWEST
      tab = USERLEVEL_TABS[header.qt]
      count = tab[:size] != -1 ? [tab[:size] - header.page * PART_SIZE, header.count].min : header.count
      return false if count <= 0
      maps.lazy.take(count).each_with_index{ |m, i|
        UserlevelTab.find_or_create_by(mode: header.mode, qt: header.qt, index: header.page * PART_SIZE + i)
                    .update(userlevel_id: m.id)
      }
      return (header.page * PART_SIZE + count < tab[:size] || tab[:size] == -1) && header.count == PART_SIZE
    end

    # Parse map data (variable length blocks)
    maps.each do |map|
      len, map.count = ioparse(buffer, 'L<S<')
      assert_left(buffer, len - 6)
      data = Zlib::Inflate.inflate(buffer.read(len - 6)) rescue next
      map.title = parse_str(data[OFFSET_TITLE - 8, 128 + 16 + 2])
      map.tiles = data[OFFSET_TILES - 8, ROWS * COLUMNS].bytes.each_slice(COLUMNS).to_a
      map.objects = data[OFFSET_OBJECTS - 8..].bytes.each_slice(5).to_a
    end

    # Update database
    maps.each do |map|
      # Userlevel object
      entry = Userlevel.find_or_create_by(id: map.id).update(
        title:      map.title,
        author_id:  map.author_id,
        favs:       map.favs,
        date:       map.date.strftime(DATE_FORMAT_MYSQL),
        mode:       header.mode,
        map_update: Time.now.strftime(DATE_FORMAT_MYSQL)
      )

      # Userlevel author
      UserlevelAuthor.find_or_create_by(id: map.author_id).rename(map.author, map.date)

      # Userlevel map data (don't update)
      next if UserlevelData.find_by(id: map.id)
      UserlevelData.create(
        id:          map.id,
        tile_data:   Map.encode_tiles(map.tiles),
        object_data: Map.encode_objects(map.objects)
      )
    end
  rescue => e
    lex(e, 'Error updating userlevels')
    false
  end

  # Dump 48 byte header used by the game for userlevel queries
  def self.query_header(
      count,                     # Map count
      page:  0,                  # Query page
      type:  TYPE_LEVEL,         # Type (0 = levels, 1 = episodes, 2 = stories)
      qt:    QT_SEARCH_BY_TITLE, # Query type (36 = search by title)
      mode:  MODE_SOLO,          # Mode (0 = solo, 1 = coop, 2 = race, 3 = hc)
      cache: NPP_CACHE_DURATION, # Cache duration in seconds (def. 5, unused for searches)
      max:   QUERY_LIMIT_HARD    # Max results per page (def. 500)
    )
    header = Time.now.strftime(DATE_FORMAT_NPP).b
    header += [count, page, type, qt, mode, cache, max, 0].pack('l<8')
  end

  # Dump binary file containing a collection of userlevels using the format
  # of query results that the game utilizes
  # (see self.parse for documentation of this format)
  # TODO: Add more integrity checks (category...)
  def self.dump_query(maps, mode, qt: QT_SEARCH_BY_TITLE)
    # Integrity checks
    perror("Some of the queried userlevels have an incorrect game mode.") if maps.any?{ |m| MODES.invert[m.mode] != mode }
    if maps.size > QUERY_LIMIT_HARD
      maps = maps.take(QUERY_LIMIT_HARD)
      alert("Too many queried userlevels, truncated to #{QUERY_LIMIT_HARD} maps.")
    end

    # Compose query result
    header  = query_header(maps.size, mode: mode, qt: qt)
    headers = maps.map{ |m| m.dump_header }.join
    data    = maps.map{ |m| m.dump_data }.join
    header + headers + data
  end

  # Handle intercepted N++'s userlevel queries via the socket
  def self.search(req)
    # Parse request parameters
    params = req.query.map{ |k, v| [k, v.to_s] }.to_h
    search = params['search'].tr('+', '').strip
    mode = params['mode'].to_i

    # Integrity checks
    return (CLE_FORWARD ? forward(req) : nil) if search != 'outte'
    player = Player.find_by(steam_id: params['steam_id'])
    return (CLE_FORWARD ? forward(req) : nil) if !player
    user = player.users(array: false).where.not(query: nil).first
    return (CLE_FORWARD ? forward(req) : nil) if !user
    query = UserlevelCache.find_by(id: user.query)
    return (CLE_FORWARD ? forward(req) : nil) if !query
    res = query.result
    m = res[32...36].unpack('l<')[0]
    return (CLE_FORWARD ? forward(req) : nil) if mode != m

    # Return saved userlevel query
    action_inc('http_levels')
    res
  rescue => e
    lex(e, 'Failed to socket userlevel query.')
    nil
  end

  # Produces the SQL order string, used when fetching maps from the db
  def self.sort(order = "", invert = false)
    return "" if !order.is_a?(String)
     # possible spellings for each field, to be used for sorting or filtering
     # doesn't include plurals (except "favs", read next line) because we "singularize" later
     # DO NOT CHANGE FIRST VALUE (its also the column name)
    fields = {
      :id     => ["id", "map id", "map_id", "level id", "level_id"],
      :title  => ["title", "name"],
      #:author => ["author", "player", "user", "person", "mapper"],
      :date   => ["date", "time", "datetime", "moment", "day", "period"],
      :favs   => ["favs", "fav", "++", "++'", "favourite", "favorite"]
    }
    inverted = [:date, :favs] # the order of these fields will be reversed by default
    fields.each{ |k, v|
      if v.include?(order.strip.singularize)
        order = k
        break
      end
    }
    return "" if !order.is_a?(Symbol)
    # sorting by date and id is equivalent, sans the direction
    str = order == :date ? "id" : fields[order][0]
    str += " DESC" if inverted.include?(order) ^ invert
    str
  end

  def self.min_id
    Userlevel.where(scored: true).order(id: :desc).limit(USERLEVEL_REPORT_SIZE).last.id
  end

  def self.newest(id = min_id)
    self.where("id >= #{id}")
  end

  def self.global
    self
  end

  # find the optimal score / amount of whatever rankings or stat
  def self.find_max(rank, global, mode = nil, author_id = nil)
    case rank
    when :points
      query = global ? self.global : self.newest
      query = query.where(mode: mode) if !mode.nil?
      query = query.where(author_id: author_id) if !author_id.nil?
      query = query.count * 20
      global ? query : [query, USERLEVEL_REPORT_SIZE * 20].min
    when :avg_points
      20
    when :avg_rank
      0
    when :maxable
      self.ties(nil, false, global, true, mode, author_id)
    when :maxed
      self.ties(nil, true, global, true, mode, author_id)
    when :score
      query = UserlevelScore.retrieve_scores(global, mode, author_id)
      query.where(rank: 0).sum(:score).to_f / 60.0
    else
      query = global ? self.global : self.newest
      query = query.where(mode: mode) if !mode.nil?
      query = query.where(author_id: author_id) if !author_id.nil?
      query = query.count
      global ? query : [query, USERLEVEL_REPORT_SIZE].min
    end
  end

  def self.find_min(full, mode = nil, author_id = nil)
    limit = 0
    if full
      if author_id.nil?
        limit = MIN_G_SCORES
      else
        limit = MIN_U_SCORES
      end
    else
      if author_id.nil?
        limit = MIN_U_SCORES
      else
        limit = 0
      end
    end
    limit
  end

  def self.spreads(n, small = false, player_id = nil, full = false)
    scores = full ? UserlevelScore.global : UserlevelScore.newest
    bench(:start) if BENCHMARK
    # retrieve player's 0ths if necessary
    ids = scores.where(rank: 0, player_id: player_id).pluck(:userlevel_id) if !player_id.nil?
    # retrieve required scores and compute spreads
    ret1 = scores.where(rank: 0)
    ret1 = ret1.where(userlevel_id: ids) if !player_id.nil?
    ret1 = ret1.pluck(:userlevel_id, :score).to_h
    ret2 = scores.where(rank: n)
    ret2 = ret2.where(userlevel_id: ids) if !player_id.nil?
    ret2 = ret2.pluck(:userlevel_id, :score).to_h
    ret = ret2.map{ |id, s| [id, ret1[id] - s] }
              .sort_by{ |id, s| small ? s : -s }
              .take(NUM_ENTRIES)
              .to_h
    # retrieve player names
    pnames = scores.where(userlevel_id: ret.keys, rank: 0)
                   .joins("INNER JOIN `userlevel_players` ON `userlevel_players`.`id` = `userlevel_scores`.`player_id`")
                   .pluck('`userlevel_scores`.`userlevel_id`', '`userlevel_players`.`name`')
                   .to_h
    ret = ret.map{ |id, s| [id.to_s, s / 60.0, pnames[id]] }
    bench(:step) if BENCHMARK
    ret
  end

  # @par player_id: Excludes levels in which the player is tied for 0th
  # @par maxed:     Whether we are computing maxed or maxable levels
  # @par full:      Whether we use all userlevels or only the newest ones
  # @par count:     Whether to query all info or only return the map count
  # @par mode:      0 = Solo, 1 = Coop, 2 = Race, nil = All
  # @par author_id: Include only maps by this author
  def self.ties(player_id = nil, maxed = false, full = false, count = false, mode = nil, author_id = nil)
    bench(:start) if BENCHMARK
    scores = UserlevelScore.retrieve_scores(full, mode, author_id)
    # retrieve most tied for 0th leves
    ret = scores.where(tied_rank: 0)
                .group(:userlevel_id)
                .order(!maxed ? 'COUNT(`userlevel_scores`.`id`) DESC' : '', :userlevel_id)
                .having('COUNT(`userlevel_scores`.`id`) >= 3')
                .having(!player_id.nil? ? '`amount` = 0' : '')
                .pluck('`userlevel_id`', 'COUNT(`userlevel_scores`.`id`)', !player_id.nil? ? "COUNT(IF(`player_id` = #{player_id}, `player_id`, NULL)) AS `amount`" : '1')
                .map{ |s| s[0..1] }
                .to_h
    # retrieve total score counts for each level (to compare against the tie count and determine maxes)
    counts = scores.where(userlevel_id: ret.keys)
                   .group(:userlevel_id)
                   .order('COUNT(`userlevel_scores`.`id`) DESC')
                   .count(:id)
    if !count
      # retrieve player names owning the 0ths on said level
      pnames = scores.where(userlevel_id: ret.keys, rank: 0)
                     .joins("INNER JOIN `userlevel_players` ON `userlevel_players`.`id` = `userlevel_scores`.`player_id`")
                     .pluck('`userlevel_scores`.`userlevel_id`', '`userlevel_players`.`name`')
                     .to_h
      # retrieve userlevels
      userl = Userlevel.where(id: ret.keys)
                       .map{ |u| [u.id, u] }
                       .to_h
      ret = ret.map{ |id, c| [userl[id], c, counts[id], pnames[id]] }
    else
      ret = maxed ? ret.count{ |id, c| counts[id] == c } : ret.count
    end
    bench(:step) if BENCHMARK
    ret
  end

  def self.rank(type, ties = false, par = nil, full = false, global = false, author_id = nil)
    scores = global ? UserlevelScore.global : UserlevelScore.newest
    if !author_id.nil?
      ids = Userlevel.where(author_id: author_id).pluck(:id)
      scores = scores.where(userlevel_id: ids)
    end

    bench(:start) if BENCHMARK
    case type
    when :rank
      scores = scores.where(par < 19 ? "`#{ties ? "tied_rank" : "rank"}` #{par == 0 ? '=' : '<='} #{par}" : '')
                     .group(:player_id)
                     .order('`count_id` DESC')
                     .count(:id)
    when :tied
      scores_w  = scores.where("`tied_rank` #{par == 0 ? '=' : '<='} #{par}")
                        .group(:player_id)
                        .order('`count_id` DESC')
                        .count(:id)
      scores_wo = scores.where("`rank` #{par == 0 ? '=' : '<='} #{par}")
                        .group(:player_id)
                        .order('`count_id` DESC')
                        .count(:id)
      scores = scores_w.map{ |id, count| [id, count - scores_wo[id].to_i] }
                       .sort_by{ |id, c| -c }
    when :points
      scores = scores.group(:player_id)
                     .order("SUM(#{ties ? "20 - `tied_rank`" : "20 - `rank`"}) DESC")
                     .sum(ties ? "20 - `tied_rank`" : "20 - `rank`")
    when :avg_points
      scores = scores.select("COUNT(`player_id`)")
                     .group(:player_id)
                     .having("COUNT(`player_id`) >= #{find_min(global, nil, author_id)}")
                     .order("AVG(#{ties ? "20 - `tied_rank`" : "20 - `rank`"}) DESC")
                     .average(ties ? "20 - `tied_rank`" : "20 - `rank`")
    when :avg_rank
      scores = scores.select("COUNT(`player_id`)")
                     .group(:player_id)
                     .having("COUNT(`player_id`) >= #{find_min(global, nil, author_id)}")
                     .order("AVG(`#{ties ? "tied_rank" : "rank"}`)")
                     .average(ties ? "`tied_rank`" : "`rank`")
    when :avg_lead
      scores = scores.where(rank: [0, 1])
                     .pluck(:player_id, :userlevel_id, :score)
                     .group_by{ |s| s[1] }
                     .reject{ |u, s| s.count < 2 }
                     .map{ |u, s| [s[0][0], s[0][2] - s[1][2]] }
                     .group_by{ |s| s[0] }
                     .map{ |p, s| [p, s.map(&:last).sum / (60.0 * s.map(&:last).count)] }
                     .sort_by{ |p, s| -s }
    when :score
      scores = scores.group(:player_id)
                     .order("SUM(`score`) DESC")
                     .sum('`score` / 60')
    end
    bench(:step) if BENCHMARK

    scores = scores.take(NUM_ENTRIES) if !full

    # Find all players in advance (better performance)
    players = UserlevelPlayer.where(id: scores.map(&:first)).pluck(:id, :name).to_h
    scores = scores.map{ |id, count| [id, count, players[id]] }
    scores.reject!{ |id, count, name| count <= 0  } unless type == :avg_rank
    bench(:step) if BENCHMARK

    scores
  end

  # Technical
  def self.sanitize(string, par)
    sanitize_sql_for_conditions([string, par])
  end

  # For compatibility
  def map
    self
  end

  def vanilla
    self
  end

  def data
    UserlevelData.find(self.id)
  end

  def tile_data(**kwargs)
    data.tile_data
  end

  def object_data(**kwargs)
    data.object_data
  end

  # Generate compressed map dump in the format the game uses when browsing
  def dump_data
    block  = self.dump_level(query: true)
    dblock = Zlib::Deflate.deflate(block, 9)
    ocount = (block.size - 0xB0 - 966 - 80) / 5

    data  = _pack(dblock.size + 6, 4) # Length of full data block (4B)
    data += _pack(ocount,          2) # Object count              (2B)
    data += dblock                    # Zlib-compressed map data  (?B)
    data
  end

  # Generate 44 byte map header of the dump above
  def dump_header
    author_str = (to_ascii(author.name.to_s)[0...16] rescue "").ljust(16, "\x00").b
    date_str   = date.strftime(DATE_FORMAT_NPP).ljust(16, "\x00").b

    header  = _pack(id, 4)        # Userlevel ID ( 4B)
    header += _pack(author_id, 4) # User ID      ( 4B)
    header +=  author_str         # User name    (16B)
    header += _pack(favs, 4)      # Map ++'s     ( 4B)
    header += date_str            # Map date     (16B)
    header
  end
end

# <---------------------------------------------------------------------------->
# <---                           MESSAGES                                   --->
# <---------------------------------------------------------------------------->

def format_userlevels(maps, page, pagesize: PAGE_SIZE, color: false)
  return "" if maps.size == 0
  maps = Userlevel::serial(maps)

  # Calculate required column padding
  max_padding = {n: 6, id: 6, title: 30, author: 16, date: 16, favs: 4 }
  min_padding = {n: 1, id: 2, title:  5, author:  6, date: 16, favs: 2 }
  def_padding = {n: 3, id: 6, title: 25, author: 16, date: 16, favs: 2 }
  if !maps.nil? && !maps.empty?
    n_padding =      [ [ (pagesize * (page - 1) + maps.size).to_s.length,   max_padding[:n]     ].min, min_padding[:n]      ].max
    id_padding =     [ [ maps.map{ |map| map[:id].to_i }.max.to_s.length,   max_padding[:id]    ].min, min_padding[:id]     ].max
    title_padding  = [ [ maps.map{ |map| map[:title].to_s.length }.max,     max_padding[:title] ].min, min_padding[:title]  ].max
    author_padding = [ [ maps.map{ |map| map[:author].to_s.length }.max,    max_padding[:title] ].min, min_padding[:author] ].max
    date_padding   = [ [ maps.map{ |map| map[:date].to_s.length }.max,      max_padding[:date]  ].min, min_padding[:date]   ].max
    favs_padding   = [ [ maps.map{ |map| map[:favs].to_i }.max.to_s.length, max_padding[:favs]  ].min, min_padding[:favs]   ].max
    padding = {n: n_padding, id: id_padding, title: title_padding, author: author_padding, date: date_padding, favs: favs_padding }
  else
    padding = def_padding
  end

  # Print header
  output = ANSI.under + ANSI.bold
  output += "%-#{padding[:n]}s "      % "N"
  output += "%-#{padding[:id]}s "     % "ID"
  output += "%-#{padding[:title]}s "  % "TITLE"
  output += "%-#{padding[:author]}s " % "AUTHOR"
  output += "%-#{padding[:date]}s "   % "DATE"
  output += "%-#{padding[:favs]}s"    % "++"
  output += ANSI.clear + "\n"
  #output += "-" * (padding.inject(0){ |sum, pad| sum += pad[1] } + padding.size - 1) + "\n"

  colors = { n: ANSI.red, id: ANSI.yellow, title: ANSI.blue, author: ANSI.cyan, date: ANSI.magenta, favs: ANSI.green }

  # Print levels
  if maps.nil? || maps.empty?
    output += " " * (padding.inject(0){ |sum, pad| sum += pad[1] } + padding.size - 1) + "\n"
  else
    maps.each_with_index{ |m, i|
      line = color ? ANSI.red : ''
      line += "%#{padding[:n]}.#{padding[:n]}s " % (pagesize * (page - 1) + i + 1).to_s
      line += ANSI.reset if color
      padding.reject{ |k, v| k == :n  }.each{ |k, v|
        line += colors[k] if color
        if m[k].is_a?(Integer)
          line += "%#{padding[k]}.#{padding[k]}s " % [m[k].to_s]
        else
          line += "%-#{padding[k]}.#{padding[k]}s " % m[k].to_s.gsub('```', '')
        end
        line += ANSI.reset if color
      }
      output << line + "\n"
    }
  end
  format_block(output)
end

# The next function queries userlevels from the database based on a number of
# parameters, like the title, the author, the tab and the mode, as well as
# allowing for arbitrary orders.
#
# Parameters:
#   The parameters are only used when the function has been called by interacting
#   with a pre-existing post, in which case we parse the header of the message as
#   though it was a user command, to figure out the original query, and then modify
#   it by the values of the parameters (e.g. incrementing the page).
#
#   Therefore, be CAREFUL when modifying the header of the message. It must still
#   be a valid regex command containing all necessary info.
def send_userlevel_browse(
    event,       # Calling event
    page:   nil, # Page offset, for button page navigation
    order:  nil, # Chosen orden from select menu
    tab:    nil, # Chosen tab from select menu
    mode:   nil, # Chosen mode from select menu
    query:  nil, # Full query, to execute this rather than parse the message
    exec:   true # Execute query (otherwise, for interactions, the text will remain)
  )

  # <------ PARSE all message elements ------>

  bench(:start) if BENCHMARK
  # Determine whether this is the initial query (new post) or an interaction
  # query (edit post).
  initial    = parse_initial(event)
  reset_page = page.nil? && exec && !initial
  msg        = query.nil? ? parse_message(event) : ''
  h          = parse_order(msg, order) # Updates msg
  msg        = h[:msg]
  order      = h[:order]
  invert     = h[:invert]
  order_str  = Userlevel::sort(order, invert)
  if query.nil?
    search, author, msg = parse_title_and_author(msg, false)
    search = search.to_s # Prev func might return int
    search = unescape(search) if search.is_a?(String)
    author = unescape(author) if author.is_a?(String)
    author = UserlevelAuthor.parse(author, event: event)
  else
    search = query[:title]
    author = UserlevelAuthor.parse(query[:author], event: event)
  end
  page = parse_page(msg, page, reset_page)
  mode = MODES.select{ |k, v| v == (mode || parse_mode(msg, true)) }.keys.first

  # Determine the category / tab
  cat = QT_NEWEST
  USERLEVEL_TABS.each{ |qt, v| cat = qt if tab.nil? ? !!(msg =~ /#{v[:name]}/i) : tab == v[:name] }
  is_tab = USERLEVEL_TABS.select{ |k, v| v[:update] }.keys.include?(cat)

  #<------ FETCH userlevels ------>

  pagesize = event.channel.type == Discordrb::Channel::TYPES[:dm] ? 20 : 10

  if exec
    # Filter userlevels
    if query.nil?
      query = Userlevel::tab(cat, mode)
      query = query.where(author_id: author.id) if !author.nil?
      query = query.where(Userlevel.sanitize("title LIKE ?", "%" + search[0...128] + "%")) if !search.empty?
    else
      query = query[:query]
    end

    # Compute count, page number, total pages, and offset
    count = query.count
    pag   = compute_pages(count, page, pagesize)

    # Order userlevels
    query = !order_str.empty? ? query.order(order_str) : (is_tab ? query.order("`index` ASC") : query.order("id DESC"))

    # Fetch userlevels
    maps = query.offset(pag[:offset]).limit(pagesize).to_a
  else
    count = msg[/Results:?[\s\*]*(\d+)/i, 1].to_i
    pag   = compute_pages(count, page, pagesize)
  end

  # <------ FORMAT message ------>

  # CAREFUL reformatting the first two lines of the output message (the header),
  # since they are used for parsing the message. When someone interacts with it,
  # either by pressing a button or making a selection in the menu, we need to
  # modify the query and edit the message. We use the header to figure out what
  # the original query was, by parsing it exactly as though it were a user
  # message, so it needs to have a format compatible with the regex we use to
  # parse commands. I know, genius implementation.
  if exec
    output = "Browsing #{USERLEVEL_TABS[cat][:name]}#{mode == -1 ? '' : ' ' + MODES[mode]} maps"
    output += " by #{verbatim(author.name[0...64])} (author id #{verbatim(author.id)})" if !author.nil?
    output += " for #{verbatim(search[0...64])}" if !search.empty?
    output += " sorted by #{invert ? "-" : ""}#{!order_str.empty? ? order : (is_tab ? "default" : "date")}."
    output += format_userlevels(maps, pag[:page], pagesize: pagesize)
    output += count == 0 ? "\nNo results :shrug:" : "Page: **#{pag[:page]}** / **#{pag[:pages]}**. Results: **#{count}**."
  else
    output = event.message.content
  end

  bench(:step) if BENCHMARK

  # <------ SEND message ------>

  # Normalize pars
  order_str = "default" if order_str.nil? || order_str.empty?
  order_str = order_str.downcase.split(" ").first
  order_str = "date" if order_str == "id" || order_str == 'default' && cat == QT_NEWEST

  # Create and fill component collection (View)
  view = Discordrb::Webhooks::View.new
  if !(initial && count == 0)
    cur_emoji = initial ? nil : get_emoji(event, 'button:play:')
    interaction_add_action_navigation(view, pag[:page], pag[:pages], 'play', 'Play', (EMOJIS_FOR_PLAY - [cur_emoji]).sample)
    interaction_add_select_menu_order(view, 'browse', order_str, cat != QT_NEWEST)
    interaction_add_select_menu_tab(view, 'browse', USERLEVEL_TABS[cat][:name])
    interaction_add_select_menu_mode(view, 'browse', MODES[mode], false)
  end

  send_message(event, content: output, components: view)
rescue => e
  lex(e, 'Error browsing userlevels.', event: event)
end

# Add an existing userlevel query result to the cache, so that it can be sent
# via the socket to those players which specify so
# Returns whether the cache creation and assignment was successful
# TODO: Find a way to parse the mode directly from the select menu
def send_userlevel_cache(event)
  # Parse message for userlevel IDs and mode
  msg    = parse_message(event, clean: false)
  header = msg.split('```')[0].gsub(/(for|by) .*/, '')
  ids    = msg[/```(.*)```/m, 1].strip.split("\n")[1..-1].map{ |l| l[/\d+\s+(\d+)/, 1].to_i }
  mode   = MODES.invert[parse_mode(header, true)]
  user   = parse_user(event.user)

  # User must be identified
  if !user.player
    modal(
      event,
      title:       'I don\'t know who you are.',
      custom_id:   'modal:identify',
      label:       'Enter your N++ player name:',
      placeholder: 'Player name',
      required:    true
    )
    return false
  end

  # If query is already cached, assign it to this user
  key = UserlevelCache.key(ids)
  cache = UserlevelCache.find_by(key: key)
  if cache
    cache.assign(user)
    send_userlevel_browse(event, exec: false)
    return true
  end

  # If query wasn't cached, fetch userlevels and build response
  maps   = Userlevel.where(id: ids).order("FIND_IN_SET(id, '#{ids.join(',')}')")
  result = Userlevel.dump_query(maps, mode)

  # Store query result in cache
  UserlevelCache.create(key: key, result: result).assign(user)
  send_userlevel_browse(event, exec: false)
  true
rescue => e
  lex(e, 'Error updating userlevel cache.', event: event)
  false
end

# Wrapper for functions that need to be execute in a single userlevel
# (e.g. download, screenshot, scores...)
# This will parse the query, find matches, and:
#   1) If there are no matches, display an error
#   2) If there is 1 match, execute function passed in the block
#   3) If there are multiple matches, execute the browse function
# We pass in the msg (instead of extracting it from the event)
# because it might've been modified by the caller function already.
def send_userlevel_individual(event, msg, userlevel = nil, &block)
  map = parse_userlevel(event, userlevel)
  case map[:count]
  when 0
    event << map[:msg]
    return
  when 1
    yield(map)
  else
    send_message(event, content: map[:msg])
    sleep(0.250) # Prevent rate limiting
    send_userlevel_browse(event, query: map)
  end
end

def send_userlevel_demo_download(event)
  msg = parse_message(event)
  msg.sub!(/(for|of)?\w*userlevel\w*/i, '')
  msg.sub!(/\w*download\w*/i, '')
  msg.sub!(/\w*replay\w*/i, '')
  msg.squish!
  send_userlevel_individual(event, msg){ |map|
    map[:query].update_scores
    rank  = [parse_range(msg).first, map[:query].scores.size - 1].min
    score = map[:query].scores[rank]
    perror("This userlevel has no scores.") if !score

    output = "Downloading #{rank.ordinalize} score by `#{score.player.name}` "
    output += "(#{"%.3f" % [score.score / 60.0]}) in userlevel #{verbatim(map[:query].title)} "
    output += "with ID #{verbatim(map[:query].id.to_s)} "
    output += "by #{verbatim(map[:query].author.name)} "
    output += "from #{verbatim(map[:query].date.strftime('%F'))}"
    event << format_header(output)
    send_file(event, Demo.encode(score.demo), "#{map[:query].id}_#{rank}", true)
  }
rescue => e
  lex(e, 'Error fetching userlevel demo download.', event: event)
end

def send_userlevel_download(event)
  msg = parse_message(event)
  msg.sub!(/(for|of)?\w*userlevel\w*/i, '')
  msg.sub!(/\w*download\w*/i, '')
  msg.squish!
  send_userlevel_individual(event, msg){ |map|
    output = "Downloading userlevel #{verbatim(map[:query].title)} "
    output += "with ID #{verbatim(map[:query].id.to_s)} "
    output += "by #{verbatim(map[:query].author.name)} "
    output += "from #{verbatim(map[:query].date.strftime('%F'))}"
    event << format_header(output)
    send_file(event, map[:query].dump_level, map[:query].id.to_s, true)
  }
rescue => e
  lex(e, 'Error fetching userlevel download.', event: event)
end

# We can pass the actual level instead of parsing it from the message
# This is used e.g. by the random userlevel function
def send_userlevel_screenshot(event, userlevel = nil)
  msg = parse_message(event)
  msg.sub!(/(for|of)?\w*userlevel\w*/i, '')
  msg.sub!(/\w*screenshot\w*/i, '')
  msg.squish!
  h = parse_palette(event)
  send_userlevel_individual(event, h[:msg], userlevel){ |map|
    output = "#{h[:error]}"
    output += "Screenshot for userlevel #{verbatim(map[:query].title)} "
    output += "with ID #{verbatim(map[:query].id.to_s)} "
    output += "by #{verbatim(map[:query].author.name)} "
    output += "from #{verbatim(map[:query].date.strftime('%F'))} "
    output += "using palette #{verbatim(h[:palette])}:"
    event << output
    bench(:start) if BENCH_IMAGES
    send_file(event, map[:query].screenshot(h[:palette]), map[:query].id.to_s + ".png", true)
  }
rescue => e
  lex(e, 'Error sending userlevel screenshot.', event: event)
end

def send_userlevel_scores(event)
  msg = parse_message(event)
  msg.sub!(/(for|of)?\w*userlevel\w*/i, '')
  msg.sub!(/\w*scores\w*/i, '')
  msg.squish!
  frac = false # parse_frac(msg)
  send_userlevel_individual(event, msg){ |map|
    map[:query].update_scores if !OFFLINE_STRICT
    output = "#{format_frac(frac)} scores for userlevel #{verbatim(map[:query].title)} "
    output += "with ID #{verbatim(map[:query].id.to_s)} "
    output += "by #{verbatim(map[:query].author.name)} "
    output += "from #{verbatim(map[:query].date.strftime('%F'))}"
    count = map[:query].completions
    header = format_header(output)
    boards = format_block(map[:query].format_scores(frac: frac))
    footer = count && count >= 20 ? "Scores: **#{count}**" : ''
    event << header + boards + footer
  }
rescue => e
  lex(e, 'Error sending userlevel scores.', event: event)
end

def send_userlevel_rankings(event)
  msg       = parse_message(event)
  rank      = parse_rank(msg) || 1
  rank      = 1 if rank < 0
  rank      = 20 if rank > 20
  ties      = parse_ties(msg)
  full      = parse_full(msg)
  global    = parse_global(msg)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  type      = ""

  if msg =~ /average/i
    if msg =~ /point/i
      top     = Userlevel.rank(:avg_points, ties, nil, full, global, author_id)
      type    = "average points"
      max     = Userlevel.find_max(:avg_points, global, nil, author_id)
    elsif msg =~ /lead/i
      top     = Userlevel.rank(:avg_lead, nil, nil, full, global, author_id)
      type    = "average lead"
      max     = nil
    else
      top     = Userlevel.rank(:avg_rank, ties, nil, full, global, author_id)
      type    = "average rank"
      max     = Userlevel.find_max(:avg_rank, global, nil, author_id)
    end
  elsif msg =~ /point/i
    top       = Userlevel.rank(:points, ties, nil, full, global, author_id)
    type      = "total points"
    max       = Userlevel.find_max(:points, global, nil, author_id)
  elsif msg =~ /score/i
    top       = Userlevel.rank(:score, nil, nil, full, global, author_id)
    type      = "total score"
    max       = Userlevel.find_max(:score, global, nil, author_id)
  elsif msg =~ /tied/i
    top       = Userlevel.rank(:tied, ties, rank - 1, full, global, author_id)
    type      = "tied #{format_rank(rank)}"
    max       = Userlevel.find_max(:rank, global, nil, author_id)
  else
    top       = Userlevel.rank(:rank, ties, rank - 1, full, global, author_id)
    type      = format_rank(rank)
    max       = Userlevel.find_max(:rank, global, nil, author_id)
  end

  count         = top.size
  score_padding = top.map{ |r| r[1].to_i.to_s.length }.max
  name_padding  = top.map{ |r| r[2].length }.max
  fmt           = top[0][1].is_a?(Integer) ? "%#{score_padding}d" : "%#{score_padding + 4}.3f"
  top           = top.each_with_index.map{ |p, i|
                    "#{"%02d" % i}: #{format_string(p[2], name_padding)} - #{fmt % p[1]}"
                  }.join("\n")
  footer = "Minimum number of scores required: #{Userlevel.find_min(global, nil, author_id)}" if msg =~ /average/i

  full   = format_full(full)
  global = format_global(global)
  ties   = format_ties(ties)
  header = "Userlevel #{full} #{global} #{type} #{ties} rankings #{format_author(author)} #{format_max(max)} #{format_time}"
  event << format_header(header)
  count <= 20 ? event << format_block(top) : send_file(event, top, "userlevel-rankings.txt", false)
  event << footer if footer
rescue => e
  lex(e, 'Error performing userlevel rankings.', event: event)
end

def send_userlevel_count(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  full      = parse_global(msg)
  rank      = parse_rank(msg) || 20
  bott      = parse_bottom_rank(msg) || 0
  ind       = nil
  dflt      = parse_rank(msg).nil? && parse_bottom_rank(msg).nil?
  tabs      = parse_tabs(msg)
  ties      = parse_ties(msg)
  tied      = parse_tied(msg)
  20.times.each{ |r| ind = r if !!(msg =~ /\b#{r.ordinalize}\b/i) }

  # If no range is provided, default to 0th count
  if dflt
    bott = 0
    rank = 1
  end

  # If an individual rank is provided, the range has width 1
  if !ind.nil?
    bott = ind
    rank = ind + 1
  end

  # The range must make sense
  if bott >= rank
    event << "You specified an empty range! (#{bott.ordinalize}-#{(rank - 1).ordinalize})"
    return
  end

  # Retrieve score count in specified range
  if tied
    count = player.range_n_count(bott, rank - 1, true, full, nil, author_id) - player.range_n_count(bott, rank - 1, type, tabs, false, full, nil, author_id)
  else
    count = player.range_n_count(bott, rank - 1, ties, full, nil, author_id)
  end

  # Format range
  if bott == rank - 1
    header = "#{bott.ordinalize}"
  elsif bott == 0
    header = format_rank(rank)
  elsif rank == 20
    header = format_bottom_rank(bott)
  else
    header = "#{bott.ordinalize}-#{(rank - 1).ordinalize}"
  end

  max  = Userlevel.find_max(:rank, full, nil, author_id)
  ties = format_ties(ties)
  tied = format_tied(tied)
  full = format_global(full)

  header = "#{player.name} has #{count} out of #{max} #{full} #{tied} #{header} scores #{ties} #{format_author(author)}"
  event << format_header(header, close: '.')
rescue => e
  lex(e, 'Error getting userlevel highscore count.', event: event)
end

def send_userlevel_points(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  ties      = parse_ties(msg)
  full      = parse_global(msg)
  max       = Userlevel.find_max(:points, full, nil, author_id)
  points    = player.points(ties, full, nil, author_id)
  ties      = format_ties(ties)
  full      = format_global(full)

  header = "#{player.name} has #{points} out of #{max} #{full} userlevel points #{ties} #{format_author(author)}"
  event << format_header(header, close: '.')
rescue => e
  lex(e, 'Error computing userlevel points.', event: event)
end

def send_userlevel_avg_points(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  ties      = parse_ties(msg)
  full      = parse_global(msg)
  avg       = player.avg_points(ties, full, nil, author_id)
  ties      = format_ties(ties)
  full      = format_global(full)

  header = "#{player.name} has #{"%.3f" % avg} average #{full} userlevel points #{ties} #{format_author(author)}"
  event << format_header(header, close: '.')
rescue => e
  lex(e, 'Error computing userlevel average points.', event: event)
end

def send_userlevel_avg_rank(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  ties      = parse_ties(msg)
  full      = parse_global(msg)
  avg       = 20 - player.avg_points(ties, full, nil, author_id)
  ties      = format_ties(ties)
  full      = format_global(full)

  header = "#{player.name} has an average #{"%.3f" % avg} #{full} userlevel rank #{ties} #{format_author(author)}"
  event << format_header(header, close: '.')
rescue => e
  lex(e, 'Error computing userlevel average rank.', event: event)
end

def send_userlevel_total_score(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  full      = parse_global(msg)
  max       = Userlevel.find_max(:score, full, nil, author_id)
  score     = player.total_score(full, nil, author_id)
  full      = format_global(full)

  header = "#{player.name}'s total #{full} userlevel score is #{"%.3f" % score} out of #{"%.3f" % max} #{format_author(author)}"
  event << format_header(header, close: '.')
rescue => e
  lex(e, 'Error computing userlevel total score.', event: event)
end

def send_userlevel_avg_lead(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  ties      = parse_ties(msg)
  full      = parse_global(msg)
  avg       = player.avg_lead(ties, full, nil, author_id)
  ties      = format_ties(ties)
  full      = format_global(full)

  header = "#{player.name} has an average #{"%.3f" % avg} #{full} userlevel 0th lead #{ties} #{format_author(author)}"
  event << format_header(header, close: '.')
rescue => e
  lex(e, 'Error computing userlevel average lead.', event: event)
end

def send_userlevel_list(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  rank      = parse_rank(msg) || 20
  bott      = parse_bottom_rank(msg) || 0
  ties      = parse_ties(msg)
  full      = parse_global(msg)
  if rank == 20 && bott == 0 && !!msg[/0th/i]
    rank = 1
    bott = 0
  end
  res = player.range_s(bott, rank - 1, ties, full, nil, author_id)
              .joins("INNER JOIN `userlevels` ON `userlevels`.`id` = `userlevel_scores`.`userlevel_id`")
              .pluck("CONCAT(LPAD(`rank`, 2, '0'), ': [', LPAD(`userlevel_id`, 6, ' '), '] ', `title`, ' (', ROUND(`score` / 60.0, 3), ')')")
  event << "Total: #{res.count}"
  send_file(event, res.join("\n"), "#{full ? "global-" : ""}userlevel-scores-#{player.name}.txt")
rescue => e
  lex(e, 'Error getting userlevel highscore list.', event: event)
end

def send_userlevel_stats(event)
  msg       = parse_message(event)
  player    = parse_player(event, true)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  ties      = parse_ties(msg)
  full      = parse_global(msg)
  counts    = player.range_h(0, 19, ties, full, nil, author_id)
                    .map{ |rank, scores| [rank, scores.length] }

  histogram = AsciiCharts::Cartesian.new(
    counts,
    bar: true,
    hide_zero: true,
    max_y_vals: 15,
    title: 'Histogram'
  ).draw

  totals  = counts.map{ |rank, count|
    "#{Highscoreable.format_rank(rank)}: #{"   %5d" % count}"
  }.join("\n\t")
  overall = "Totals:    %5d" % counts.reduce(0){ |sum, c| sum += c[1] }

  full = format_global(full)
  event << format_header("#{full.capitalize} userlevels highscoring stats for #{player.name} #{format_author(author)} #{format_time}")
  event << format_block("          Scores\n\t#{totals}\n#{overall}\n#{histogram}")
rescue => e
  lex(e, 'Error computing userlevel stats.', event: event)
end

def send_userlevel_spreads(event)
  msg    = parse_message(event)
  n      = (msg[/([0-9][0-9]?)(st|nd|rd|th)/, 1] || 1).to_i
  player = parse_player(event, true, true, false)
  small  = !!(msg =~ /smallest/)
  full   = parse_global(msg)
  perror("I can't show you the spread between 0th and 0th...") if n == 0

  spreads  = Userlevel.spreads(n, small, player.nil? ? nil : player.id, full)
  namepad  = spreads.map{ |s| s[0].length }.max
  scorepad = spreads.map{ |s| s[1] }.max.to_i.to_s.length + 4
  spreads  = spreads.each_with_index
                    .map { |s, i| "#{"%02d" % i}: #{"%-#{namepad}s" % s[0]} - #{"%#{scorepad}.3f" % s[1]} - #{s[2]}"}
                    .join("\n")

  spread = small ? "smallest" : "largest"
  rank   = (n == 1 ? "1st" : (n == 2 ? "2nd" : (n == 3 ? "3rd" : "#{n}th")))
  full   = format_global(full)
  event << format_header("#{full.capitalize} userlevels #{!player.nil? ? "owned by #{player.name}" : ""} with the #{spread} spread between 0th and #{rank}")
  event << format_block(spreads)
rescue => e
  lex(e, 'Error computing userlevel spreads.', event: event)
end

def send_userlevel_maxed(event)
  msg       = parse_message(event)
  player    = parse_player(event, true, true, false)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  full      = parse_global(msg)
  ties      = Userlevel.ties(player.nil? ? nil : player.id, true, full, false, nil, author_id)
                       .select { |s| s[1] == s[2] }
                       .map { |s| "#{"%6d" % s[0].id} - #{"%6d" % s[0].author_id} - #{format_string(s[3])}" }
  count  = ties.count{ |s| s.length > 1 }
  player = player.nil? ? "" : " without " + player.name
  full   = format_global(full)
  block  = "    ID - Author - Player\n#{ties.join("\n")}"
  header = "There are #{count} potentially maxed #{full} userlevels #{format_time} #{player} #{format_author(author)}"
  event << format_header(header)
  count <= 20 ? event << format_block(block) : send_file(event, block, "maxed-userlevels.txt", false)
rescue => e
  lex(e, 'Error computing userlevel maxes.', event: event)
end

def send_userlevel_maxable(event)
  msg       = parse_message(event)
  player    = parse_player(event, true, true, false)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  full      = parse_global(msg)
  ties      = Userlevel.ties(player.nil? ? nil : player.id, false, full, false, nil, author_id)
                       .select { |s| s[1] < s[2] }
                       .sort_by { |s| -s[1] }
  count = ties.count
  ties  = ties.take(NUM_ENTRIES).map { |s|
    "#{"%6s" % s[0].id} - #{"%4d" % s[1]} - #{"%6d" % s[0].author_id} - #{format_string(s[3])}"
  }
  player = player.nil? ? "" : " without " + player.name
  full   = format_global(full)
  header = "All #{count} #{full} userlevels with the most ties for 0th #{format_time} #{player} #{format_author(author)}"
  event << format_header(header)
  event << format_block("    ID - Ties - Author - Player\n#{ties.join("\n")}")
rescue => e
  lex(e, 'Error computing userlevel maxables.', event: event)
end

def send_random_userlevel(event)
  msg       = parse_message(event)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  amount    = [(msg[/\d+/] || 1).to_i, PAGE_SIZE].min
  mode      = parse_mode(msg, true)
  full      = parse_global(msg)
  maps      = full ? Userlevel.global : Userlevel.newest

  maps = maps.where(mode: mode.to_sym)
  maps = maps.where(author_id: author_id) if !author_id.nil?
  maps = maps.sample(amount)

  if amount > 1
    event << format_header("Random selection of #{amount} #{mode} #{format_global(full)} userlevels #{!author.nil? ? "by #{author.name}" : ""}")
    event << format_userlevels(maps, 1)
  else
    send_userlevel_screenshot(event, maps.first)
  end
rescue => e
  lex(e, 'Error fetching random userlevel.', event: event)
end

def send_userlevel_mapping_summary(event)
  # Parse message parameters
  msg       = parse_message(event)
  author    = UserlevelAuthor.parse(parse_userlevel_both(msg), event: event)
  author_id = !author.nil? ? author.id : nil
  mode      = parse_mode(msg, false, true)

  # Fetch userlevels
  maps = Userlevel.global
  maps = maps.where(mode: mode.to_sym) if !mode.nil?
  maps = maps.where(author_id: author_id) if !author_id.nil?
  count = maps.count

  # Perform summary
  header = "Userlevel mapping summary#{" for #{author.name}" if !author.nil?}"
  stats = "Maps:           #{count}\n"
  if author.nil?
    authors  = maps.distinct.count(:author_id)
    prolific = maps.group(:author_id).order("COUNT(`id`) DESC").count(:id).first
    popular  = maps.group(:author_id).order("SUM(`favs`) DESC").sum(:favs).first
    refined  = maps.group(:author_id).order("AVG(`favs`) DESC").average(:favs).first
    stats << "Authors:        #{authors}\n"
    stats << "Maps / author:  #{"%.3f" % (count.to_f / authors)}\n"
    stats << "Most maps:      #{prolific.last} (#{Userlevel.find_by(author_id: prolific.first).author.name})\n"
    stats << "Most ++'s:      #{popular.last} (#{Userlevel.find_by(author_id: popular.first).author.name})\n"
    stats << "Most avg ++'s:  #{"%.3f" % refined.last} (#{Userlevel.find_by(author_id: refined.first).author.name})\n"
  end
  if !maps.is_a?(Array) || !maps.empty?
    first = maps.order(:id).first
    stats << "First map:      #{first.date.strftime(DATE_FORMAT_OUTTE)} (#{first.id})\n"
    last = maps.order(id: :desc).first
    stats << "Last map:       #{last.date.strftime(DATE_FORMAT_OUTTE)} (#{last.id})\n"
    best = maps.order(favs: :desc).first
    stats << "Most ++'ed map: #{best.favs} (#{best.id})\n"
    sum = maps.sum(:favs).to_i
    stats << "Total ++'s:     #{sum}\n"
    avg = sum.to_f / count
    stats << "Avg. ++'s:      #{"%.3f" % avg}\n"
  end
  event << format_header(header) + format_block(stats)
end

def send_userlevel_highscoring_summary(event)
  # Parse message parameters
  msg       = parse_message(event)
  player    = parse_player(event, true, true, false)
  author    = parse_author(event, false)
  author_id = !author.nil? ? author.id : nil
  full      = parse_global(msg)
  mode      = parse_mode(msg, false, true)

  perror("The global userlevel highscoring summary is disabled for now until it's optimized, you can still do:\n* The newest highscoring summary.\n* The global highscoring summary _for a specific player_.") if full && !player && !author

  # Fetch userlevels
  maps = full ? Userlevel.global : Userlevel.newest
  maps = maps.where(mode: mode.to_sym) if !mode.nil?
  maps = maps.where(author_id: author_id) if !author_id.nil?
  count = maps.count

  # Fetch scores
  scores = (player.nil? ? UserlevelScore : player).retrieve_scores(full, mode, author_id)
  count_a = scores.distinct.count(:userlevel_id)
  count_s = scores.count

  # Perform summary
  header = "#{format_global(full).capitalize} userlevel highscoring summary #{format_author(author)} #{"for #{player.name}" if !player.nil?}"
  stats = ""
  if player.nil?
    min = full ? MIN_G_SCORES : MIN_U_SCORES
    scorers   = scores.distinct.count(:player_id)
    prolific1 = scores.group(:player_id).order("COUNT(`id`) DESC").count(:id).first
    prolific2 = scores.where("`rank` <= 9").group(:player_id).order("COUNT(`id`) DESC").count(:id).first
    prolific3 = scores.where("`rank` <= 4").group(:player_id).order("COUNT(`id`) DESC").count(:id).first
    prolific4 = scores.where("`rank` = 0").group(:player_id).order("COUNT(`id`) DESC").count(:id).first
    highscore = scores.group(:player_id).order("SUM(`score`) DESC").sum(:score).first
    manypoint = scores.group(:player_id).order("SUM(20 - `rank`) DESC").sum("20 - `rank`").first
    averarank = scores.select("COUNT(`rank`)").group(:player_id).having("COUNT(`rank`) >= #{min}").order("AVG(`rank`)").average(:rank).first
    maxes     = Userlevel.ties(nil, true,  full, true, nil, author_id)
    maxables  = Userlevel.ties(nil, false, full, true, nil, author_id)
    tls   = scores.where(rank: 0).sum(:score).to_f / 60.0
    tls_p = highscore.last.to_f / 60.0
    stats << "Scored maps:      #{count_a}\n"
    stats << "Unscored maps:    #{count - count_a}\n"
    stats << "Scores:           #{count_s}\n"
    stats << "Players:          #{scorers}\n"
    stats << "Scores / map:     #{"%.3f" % (count_s.to_f / count)}\n"
    stats << "Scores / player:  #{"%.3f" % (count_s.to_f / scorers)}\n"
    stats << "Total score:      #{"%.3f" % tls}\n"
    stats << "Avg. score:       #{"%.3f" % (tls / count_a)}\n"
    stats << "Maxable maps:     #{maxables}\n"
    stats << "Maxed maps:       #{maxes}\n"
    stats << "Most Top20s:      #{prolific1.last} (#{UserlevelPlayer.find(prolific1.first).name})\n"
    stats << "Most Top10s:      #{prolific2.last} (#{UserlevelPlayer.find(prolific2.first).name})\n"
    stats << "Most Top5s:       #{prolific3.last} (#{UserlevelPlayer.find(prolific3.first).name})\n"
    stats << "Most 0ths:        #{prolific4.last} (#{UserlevelPlayer.find(prolific4.first).name})\n"
    stats << "Most total score: #{"%.3f" % tls_p} (#{UserlevelPlayer.find(highscore.first).name})\n"
    stats << "Most points:      #{manypoint.last} (#{UserlevelPlayer.find(manypoint.first).name})\n"
    stats << "Best avg rank:    #{averarank.last} (#{UserlevelPlayer.find(averarank.first).name})\n" rescue nil
  else
    tls = scores.sum(:score).to_f / 60.0
    stats << "Total Top20s: #{count_s}\n"
    stats << "Total Top10s: #{scores.where("`rank` <= 9").count}\n"
    stats << "Total Top5s:  #{scores.where("`rank` <= 4").count}\n"
    stats << "Total 0ths:   #{scores.where("`rank` = 0").count}\n"
    stats << "Total score:  #{"%.3f" % tls}\n"
    stats << "Avg. score:   #{"%.3f" % (tls / count_s)}\n"
    stats << "Total points: #{scores.sum("20 - `rank`")}\n"
    stats << "Avg. rank:    #{"%.3f" % scores.average(:rank)}\n"
  end
  event << format_header(header) + format_block(stats)
end

def send_userlevel_summary(event)
  msg = parse_message(event)
  mapping     = !!msg[/mapping/i]
  highscoring = !!msg[/highscoring/i]
  both        = !(mapping || highscoring)
  send_userlevel_mapping_summary(event)     if mapping     || both
  send_userlevel_highscoring_summary(event) if highscoring || both
rescue => e
  lex(e, 'Error performing userlevel summary.', event: event)
end

def send_userlevel_trace(event)
  perror("Sorry, tracing is disabled.") if !FEATURE_NTRACE
  wait_msg = send_message(event, content: 'Queued...', db: false) if $mutex[:trace].locked?
  $mutex[:trace].synchronize do
    wait_msg.delete if !wait_msg.nil? rescue nil
    parse_message(event).sub!(/user\s*level/i, '')
    parse_message(event).squish!
    msg = parse_palette(event)[:msg]
    send_userlevel_individual(event, msg){ |map|
      Map.trace(event, anim: !!parse_message(event)[/anim/i], h: map[:query])
    }
  end
rescue => e
  lex(e, 'Error performing userlevel trace.', event: event)
end

def send_userlevel_times(event)
  event << "Userlevel database update times:"

  next_level = ($status_update + STATUS_UPDATE_FREQUENCY) - Time.now.to_i
  next_level_minutes = (next_level / 60).to_i
  next_level_seconds = next_level - (next_level / 60).to_i * 60
  event << "* I'll update the userlevel database in #{next_level_minutes} minutes and #{next_level_seconds} seconds."

  next_level = GlobalProperty.get_next_update('userlevel_score') - Time.now
  next_level_hours = (next_level / (60 * 60)).to_i
  next_level_minutes = (next_level / 60).to_i - (next_level / (60 * 60)).to_i * 60
  event << "* I'll update the newest userlevel scores in #{next_level_hours} hours and #{next_level_minutes} minutes."

  next_level = GlobalProperty.get_next_update('userlevel_tab') - Time.now
  next_level_hours = (next_level / (60 * 60)).to_i
  next_level_minutes = (next_level / 60).to_i - (next_level / (60 * 60)).to_i * 60
  event << "* I'll update the userlevel tabs (e.g. hardest) in #{next_level_hours} hours and #{next_level_minutes} minutes."
rescue => e
  lex(e, 'Error fetching userlevel update times.', event: event)
end

def respond_userlevels(event)
  msg = parse_message(event)
  action_inc('commands')

  # Exclusively global methods
  if !msg[NAME_PATTERN, 2]
    return send_userlevel_rankings(event)  if msg =~ /\brank/i
  end

  return send_userlevel_browse(event)        if msg =~ /\bbrowse\b/i || msg =~ /\bsearch\b/i
  return send_userlevel_screenshot(event)    if msg =~ /\bscreenshots?\b/i
  return send_userlevel_scores(event)        if msg =~ /scores\b/i
  return send_userlevel_demo_download(event) if (msg =~ /\breplay\b/i || msg =~ /\bdemo\b/i) && msg =~ /\bdownload\b/i
  return send_userlevel_download(event)      if msg =~ /\bdownload\b/i
  return send_userlevel_trace(event)         if msg =~ /\btrace\b/i || msg =~ /\banim/i
  return send_userlevel_count(event)         if msg =~ /how many/i
  return send_userlevel_spreads(event)       if msg =~ /spread/i
  return send_userlevel_avg_points(event)    if msg =~ /average/i && msg =~ /point/i && msg !~ /rank/i
  return send_userlevel_points(event)        if msg =~ /point/i && msg !~ /rank/i
  return send_userlevel_avg_rank(event)      if msg =~ /average/i && msg =~ /rank/i && !!msg[NAME_PATTERN, 2]
  return send_userlevel_avg_lead(event)      if msg =~ /average/i && msg =~ /lead/i && msg !~ /rank/i
  return send_userlevel_total_score(event)   if msg =~ /total score/i && msg !~ /rank/i
  return send_userlevel_list(event)          if msg =~ /\blist\b/i
  return send_userlevel_stats(event)         if msg =~ /stat/i
  return send_userlevel_maxed(event)         if msg =~ /maxed/i
  return send_userlevel_maxable(event)       if msg =~ /maxable/i
  return send_random_userlevel(event)        if msg =~ /random/i
  return send_userlevel_summary(event)       if msg =~ /summary/i
  return send_userlevel_times(event)         if msg =~ /\bwhen\b/i

  action_dec('commands')
  event << "Sorry, I didn't understand your userlevel command."
end
