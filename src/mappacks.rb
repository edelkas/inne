# This file includes all the classes related to mappacks (levels, episodes, stories,
# demos, etc). It parses new mappacks, calculates integrity hashes, etc. Notably,
# it handles all CLE server communications (score submission, leaderboards, replay
# downloading, etc).

class Mappack < ActiveRecord::Base
  has_many :mappack_scores
  has_many :mappack_levels
  has_many :mappack_episodes
  has_many :mappack_stories
  has_many :mappack_channels
  alias_method :scores,   :mappack_scores
  alias_method :levels,   :mappack_levels
  alias_method :episodes, :mappack_episodes
  alias_method :stories,  :mappack_stories
  alias_method :channels, :mappack_channels

  # Parse all mappacks in the mappack directory into the database
  #   update - Update preexisting mappacks (otherwise, only parses newly added ones)
  #   all    - Update all versions of each mappack
  #   hard   - Perform a hard update (see self.read)
  def self.seed(update: false, all: true, hard: false)
    # Fetch mappacks
    perror("Mappacks directory not found, not seeding.", log: true) if !Dir.exist?(DIR_MAPPACKS)
    mappacks = {}
    Dir.entries(DIR_MAPPACKS).select{ |d| !!d[/\d+_.+/] }.sort.map{ |d|
      id, code, version = d.split('_')
      mappacks[code] = { id: id.to_i, versions: [] } if !mappacks.key?(code)
      mappacks[code][:id] = id.to_i
      mappacks[code][:versions] << version.to_i
    }

    # Integrity checks:
    # - Ensure no ID conflicts
    # - Ensure all versions are present
    mappacks.group_by{ |code, atts| atts[:id] }.each{ |id, packs|
      perror("Mappack ID conflict: #{packs.map{ |p| p[0].upcase }.join(', ')}.", log: true) if packs.size > 1
    }
    mappacks.each{ |code, atts|
      missing = (1 .. atts[:versions].max).to_a - atts[:versions]
      perror("#{code.upcase} missing versions #{missing.join(', ')}.", log: true) unless missing.empty?
    }

    # Read mappacks
    mappacks.each{ |code, atts|
      id       = atts[:id]
      versions = atts[:versions].sort

      versions.each{ |version|
        next if !all && version < versions.max
        mappack = Mappack.find_by(id: id)
        if mappack
          next unless update
          perror("Mappack with ID #{id} already belongs to #{mappack.code.upcase}.", log: true) if mappack.code.upcase != code.upcase
          if version < mappack.version && !hard
            perror("Cannot soft update #{code.upcase} to v#{version} (already at v#{mappack.version}).", log: true)
          end
          mappack.update(version: version)
          mappack.read(v: version, hard: hard)
        else
          perror("#{code.upcase} v1 should exist (trying to create v#{version}).", log: true) if version != 1
          Mappack.create(id: id, code: code, version: 1).read(v: 1, hard: true)
        end
      }
    }

    # Update mappack digest
    digest
  rescue => e
    lex(e, "Error seeding mappacks to database")
  end

  # Update the digest file, which summarizes mappack info into a file that can
  # be queried via the internet, containing the ID, code and version for each
  # mappack, one per line.
  def self.digest
    dig = Mappack.all.order(:id).pluck(:id, :code, :version).map{ |m|
      m.join(' ') + "\n"
    }.join
    File.write(PATH_MAPPACK_INFO, dig)
  rescue => e
    lex(e, 'Failed to generate mappack digest file')
  end

  # Return the folder that contains this mappack's files
  def folder(v: nil)
    if !v
      err("The mappack version needs to be provided.")
      return
    end

    dir = File.join(DIR_MAPPACKS, "#{"%03d" % [id]}_#{code}_#{v}")
    Dir.exist?(dir) ? dir : nil
  end

  # TODO: Parse challenge files, in a separate function with its own command,
  # which is also called from the general seed and read functions.

  # Parses map files corresponding to this mappack, and updates the database
  #   v       - Specifies the version of the mappack
  #   hard    - A hard update is aimed at versions with significant changes,
  #             e.g., different amount of maps. In this case, the highscoreables
  #             are deleted. For soft updates, checks of similarity are enforced,
  #             and a report of changes is printed.
  #   discord - Log errors back to Discord.
  def read(v: nil, hard: false)
    # Integrity check for mappack version
    v = version || 1 if !v
    perror("Cannot soft update an older mappack version (#{v} vs #{version}).", log: true) if v < version && !hard
    name_str = "#{code.upcase} v#{v}"

    # Check for mappack directory
    log("Parsing mappack #{name_str}...")
    dir = folder(v: v)
    perror("Directory for mappack #{name_str} not found, not reading", log: true) if !dir

    # Fetch mappack files
    files = Dir.entries(dir).select{ |f|
      path = File.join(dir, f)
      File.file?(path) && File.extname(path) == ".txt"
    }.sort
    alert("No appropriate files found in directory for mappack #{name_str}") if files.count == 0

    if !hard
      # Soft updates: Ensure the new tabs will replace the old ones precisely
      tabs_old = MappackLevel.where(mappack_id: id).distinct.pluck('`tab` AS `tab_int`').sort
      tabs_new = files.map{ |f|
        tab = TABS_NEW.values.find{ |att| att[:files].key?(f[0..-5]) }
        tab ? tab[:mode] * 7 + tab[:tab] : nil
      }.compact.uniq.sort
      perror("Tabs for mappack #{code.upcase} do not coincide, cannot do soft update.", log: true) if tabs_old != tabs_new
    else
      # Hard updates: Delete highscoreables
      levels.delete_all(:delete_all)
      episodes.delete_all(:delete_all)
      stories.delete_all(:delete_all)
    end

    # Delete map data from newer versions
    MappackData.joins('INNER JOIN `mappack_levels` ON `mappack_levels`.`id` = `highscoreable_id`')
               .where("`mappack_id` = #{id} AND `version` >= #{v}").delete_all

    # Parse mappack files
    file_errors = 0
    map_errors = 0
    changes = { name: 0, tiles: 0, objects: 0 } if !hard
    files.each{ |f|
      # Find corresponding tab
      tab_code = f[0..-5]
      tab = TABS_NEW.values.find{ |att| att[:files].key?(tab_code) }
      if tab.nil?
        alert("Unrecognized file #{tab_code} parsing mappack #{name_str}")
        next
      end

      # Parse file
      maps = Map.parse_metanet_file(File.join(dir, f), tab[:files][tab_code], name_str)
      if maps.nil?
        file_errors += 1
        perror("Parsing of #{name_str} #{f} failed, ending soft update.", log: true) if !hard
        next
      end

      # Precompute some indices for the database
      mappack_offset = TYPES['Level'][:slots] * id
      file_index     = tab[:files].keys.index(tab_code)
      file_offset    = tab[:files].values.take(file_index).sum
      tab_offset     = tab[:start]
      tab_index      = tab[:mode] * 7 + tab[:tab]

      count = maps.count
      # In soft updates, map count must be the same (or smaller, if tab is
      # partitioned in multiple files, but never higher)
      perror("Map count in #{code.upcase} #{f} exceeds database ones, must do hard update.", log: true) if !hard && count > levels.where(tab: tab_index).count

      # Create new database records
      maps.each_with_index{ |map, map_offset|
        dbg("#{hard ? 'Creating' : 'Updating'} record #{"%-3d" % (map_offset + 1)} / #{count} from #{f} for mappack #{name_str}...", newline: false)
        if map.nil?
          map_errors += 1
          perror("Parsing of #{name_str} #{f} map #{map_offset} failed, ending soft update.", log: true) if !hard
          next
        end
        tab_id   = file_offset    + map_offset # ID of level within tab
        inner_id = tab_offset     + tab_id     # ID of level within mappack
        level_id = mappack_offset + inner_id   # ID of level in database

        # Create mappack level
        change_level = false
        if hard
          level = MappackLevel.find_or_create_by(id: level_id)
          change_level = true
        else
          level = MappackLevel.find_by(id: level_id)
          perror("#{code.upcase} level with ID #{level_id} should exist.", log: true) if !level
          if map[:title].strip != level.longname
            changes[:name] += 1
            change_level = true
          end
        end

        level.update(
          inner_id:   inner_id,
          mappack_id: id,
          mode:       tab[:mode],
          tab:        tab_index,
          episode_id: level_id / 5,
          name:       code.upcase + '-' + compute_name(inner_id, 0),
          longname:   map[:title].strip,
          gold:       map[:gold]
        ) if change_level

        # Save new mappack data (tiles and objects) if:
        #   Hard update - Always
        #   Soft update - Only when the map data is different
        prev_tiles = level.tile_data(version: v - 1)
        new_tiles  = Map.encode_tiles(map[:tiles])
        save_tiles = prev_tiles != new_tiles

        prev_objects = level.object_data(version: v - 1)
        new_objects  = Map.encode_objects(map[:objects])
        save_objects = prev_objects != new_objects

        new_data = hard || save_tiles || save_objects
        if new_data
          data = MappackData.find_or_create_by(highscoreable_id: level_id, version: v)
          if hard || save_tiles
            data.update(tile_data: new_tiles)
            changes[:tiles] += 1 if !hard
          end
          if hard || save_objects
            data.update(object_data: new_objects)
            changes[:objects] += 1 if !hard
          end
        end

        # Create corresponding mappack episode, except for secret tabs.
        next if tab[:secret] || level_id % 5 > 0
        story = tab[:mode] == 0 && (!tab[:x] || map_offset < 5 * tab[:files][tab_code] / 6)

        episode = MappackEpisode.find_by(id: level_id / 5)
        if hard
          episode = MappackEpisode.create(
            id:         level_id / 5,
            inner_id:   inner_id / 5,
            mappack_id: id,
            mode:       tab[:mode],
            tab:        tab_index,
            story_id:   story ? level_id / 25 : nil,
            name:       code.upcase + '-' + compute_name(inner_id / 5, 1)
          ) unless episode
        else
          perror("#{code.upcase} episode with ID #{level_id / 5} should exist, stopping soft update.", log: true) if !episode
        end

        # Create corresponding mappack story, only for non-X-Row Solo.
        next if !story || level_id % 25 > 0

        story = MappackStory.find_by(id: level_id / 25)
        if hard
          story = MappackStory.create(
            id:         level_id / 25,
            inner_id:   inner_id / 25,
            mappack_id: id,
            mode:       tab[:mode],
            tab:        tab_index,
            name:       code.upcase + '-' + compute_name(inner_id / 25, 2)
          ) unless story
        else
          perror("#{code.upcase} story with ID #{level_id / 25} should exist, stopping soft update.", log: true) if !story
        end
      }
      Log.clear

      # Log results for this file
      count = maps.count(nil)
      map_errors += count
      if count == 0
        dbg("Parsed file #{tab_code} for mappack #{name_str} without errors", pad: true)
      else
        alert("Parsed file #{tab_code} for mappack #{name_str} with #{count} errors", pad: true)
      end
    }

    # Fill in episode and story gold counts based on their corresponding levels
    episode_count = episodes.size
    episodes.find_each.with_index{ |e, i|
      dbg("Setting gold count for #{name_str} episode #{i + 1} / #{episode_count}...", progress: true)
      e.update(gold: MappackLevel.where(episode_id: e.id).sum(:gold))
    }
    Log.clear
    story_count = stories.size
    stories.find_each.with_index{ |s, i|
      dbg("Setting gold count for #{name_str} story #{i + 1} / #{story_count}...", progress: true)
      s.update(gold: MappackEpisode.where(story_id: s.id).sum(:gold))
    }
    Log.clear

    # Update precomputed SHA1 hashes
    MappackLevel.update_hashes(mappack: self)
    MappackEpisode.update_hashes(mappack: self, pre: true)
    MappackStory.update_hashes(mappack: self, pre: true)

    # Log final results for entire mappack
    if file_errors + map_errors == 0
      succ("Successfully parsed mappack #{name_str}")
      self.update(version: v)
    else
      alert("Parsed mappack #{name_str} with #{file_errors} file errors and #{map_errors} map errors")
    end
    dbg("Soft update: #{changes[:name]} name changes, #{changes[:tiles]} tile changes, #{changes[:objects]} object changes.") if !hard
  rescue => e
    lex(e, "Error reading mappack #{name_str}")
  end

  # Read the author list and write to the db
  def read_authors(v: nil)
    v = version || 1 if !v

    # Integrity checks
    dir = folder(v: v)
    if !dir
      err("Directory for mappack #{verbatim(code)} not found")
      return
    end
    path = File.join(dir, FILENAME_MAPPACK_AUTHORS)
    if !File.file?(path)
      err("Authors file for mappack #{verbatim(code)} not found")
      return
    end

    # Parse authors file
    file = File.binread(path)
    names = file.split("\n").map(&:strip)
    maps = levels.order(:id)
    if maps.size != names.size
      err("Authors file for mappack #{verbatim(code)} has incorrect length (#{names.size} names vs #{maps.size} maps)")
      return
    end

    # Write names
    count = maps.size
    maps.each_with_index{ |m, i|
      dbg("Adding author #{i + 1} / #{count}...", pad: true, newline: false)
      m.update(author: names[i])
    }
    Log.clear
  rescue => e
    lex(e, "Failed to read authors file for mappack #{verbatim(code)}")
  end

  # Check additional requirements for scores submitted to this mappack
  # For instance, w's Duality coop pack requires that the replays for both
  # players be identical
  def check_requirements(demos)
    case self.code
    when 'dua'
      demos.each{ |d|
        # Demo must have even length (coop)
        sz = d.size
        if sz % 2 == 1
          alert("Demo does not satisfy Duality's requirements (odd length)")
          return false
        end

        # Both halves of the demo must be identical
        if d[0...sz / 2] != d[sz / 2..-1]
          alert("Demo does not satisfy Duality's requirements (different inputs)")
          return false
        end
      }
      true
    else
      true
    end
  rescue => e
    lex(e, "Failed to check requirements for demo in '#{code}' mappack")
    false
  end

  # Set some of the mappack's info on command, which isn't parsed from the files
  def set_info(name: nil, author: nil, date: nil, channel: nil, version: nil)
    self.update(name: name) if name
    self.update(authors: author) if author
    self.update(version: version) if version
    self.update(date: Time.strptime(date, '%Y/%m/%d').strftime(DATE_FORMAT_MYSQL)) if date
    channel.each{ |c|
      if is_num(c)
        ch = find_channel(id: c.strip.to_i)
      else
        ch = find_channel(name: c.strip)
      end
      perror("No channel found by the name #{verbatim(c.strip)}.") if !ch
      chn = MappackChannel.find_or_create_by(id: ch.id)
      channels << chn
      chn.update(name: ch.name)
    } if channel
  rescue => e
    lex(e, "Failed to set mappack '#{code}' info")
    nil
  end
end

class MappackData < ActiveRecord::Base
  belongs_to :mappack_level, foreign_key: :highscoreable_id
  alias_method :level, :mappack_level
  alias_method :level=, :mappack_level=
end

module MappackHighscoreable
  include Highscoreable

  def type
    self.class.to_s
  end

  def basetype
    type.remove('Mappack')
  end

  def version
    versions.max
  end

  # Recompute SHA1 hash for all available versions
  # If 'pre', then episodes/stories will not recompute their level hashes
  def update_hashes(pre: false)
    hashes.clear
    versions.each{ |v|
      hashes.create(version: v, sha1_hash: _hash(c: true, v: v, pre: pre))
    }
    hashes.count
  end

  # Return leaderboards, filtering obsolete scores and sorting appropiately
  # depending on the mode (hs / sr).
  def leaderboard(
      m         = 'hs',  # Playing mode (hs, sr, gm)
      score     = false, # Sort by score and date instead of rank (used for computing the rank)
      truncate:   20,    # How many scores to take (0 = all)
      pluck:      true,  # Pluck or keep Rails relation
      aliases:    false, # Use player names or display names
      metanet_id: nil,   # Player making the request if coming from CLE
      page:       0      # Index of page to fetch
    )
    m = 'hs' if !['hs', 'sr', 'gm'].include?(m)
    names = aliases ? 'IF(display_name IS NOT NULL, display_name, name)' : 'name'
    attr_names = %W[id score_#{m} name metanet_id]

    # Check if a manual replay ID has been set, so that we only select that one
    manual = GlobalProperty.find_by(key: 'replay_id').value rescue nil
    use_manual = manual && metanet_id == BOTMASTER_NPP_ID

    # Handle manual board
    if use_manual
      attrs = %W[mappack_scores.id score_#{m} #{names} metanet_id]
      board = scores.where(id: manual)
    end

    # Handle standard boards
    if ['hs', 'sr'].include?(m) && !use_manual
      attrs = %W[mappack_scores.id score_#{m} #{names} metanet_id]
      board = scores.where("rank_#{m} IS NOT NULL")
      if score
        board = board.order("score_#{m} #{m == 'hs' ? 'DESC' : 'ASC'}, date ASC")
      else
        board = board.order("rank_#{m} ASC")
      end
    end

    # Handle gold boards
    if m == 'gm' && !use_manual
      attrs = [
        'MIN(subquery.id) AS id',
        'MIN(score_gm) AS score_gm',
        "MIN(#{names}) AS name",
        'subquery.metanet_id'
      ]
      join = %{
        INNER JOIN (
          SELECT metanet_id, MIN(gold) AS score_gm
          FROM mappack_scores
          WHERE highscoreable_id = #{id} AND highscoreable_type = '#{type}'
          GROUP BY metanet_id
        ) AS opt
        ON mappack_scores.metanet_id = opt.metanet_id AND gold = score_gm
      }.gsub(/\s+/, ' ').strip
      subquery = scores.select(:id, :score_gm, :player_id, :metanet_id).joins(join)
      board = MappackScore.from(subquery).group(:metanet_id).order('score_gm', 'id')
    end

    # Paginate (offset and truncate), fetch player names, and convert to hash
    board = board.offset(20 * page) if page > 0
    board = board.limit(truncate) if truncate > 0
    return board if !pluck
    board.joins("INNER JOIN players ON players.id = player_id")
         .pluck(*attrs).map{ |s| attr_names.zip(s).to_h }
  end

  # Return scores in JSON format expected by N++
  def get_scores(qt = 0, metanet_id = nil)
    # Determine leaderboard type
    page = 0
    case qt
    when 0
      m = 'hs'
    when 1
      m = 'hs'
      #page = 1 if metanet_id == BOTMASTER_NPP_ID
    when 2
      m = 'sr'
    end

    # Fetch scores
    board = leaderboard(m, metanet_id: metanet_id, page: page)

    # Build response
    res = {}

    #score = board.find_by(metanet_id: metanet_id) if !metanet_id.nil?
    #res["userInfo"] = {
    #  "my_score"        => m == 'hs' ? (1000 * score["score_#{m}"].to_i / 60.0).round : 1000 * score["score_#{m}"].to_i,
    #  "my_rank"         => (score["rank_#{m}"].to_i rescue -1),
    #  "my_replay_id"    => score.id.to_i,
    #  "my_display_name" => score.player.name.to_s.remove("\\")
    #} if !score.nil?

    res["scores"] = board.each_with_index.map{ |s, i|
      {
        "score"     => m == 'hs' ? (1000 * s["score_#{m}"].to_i / 60.0).round : 1000 * s["score_#{m}"].to_i,
        "rank"      => 20 * page + i,
        "user_id"   => s['metanet_id'].to_i,
        "user_name" => s['name'].to_s.remove("\\"),
        "replay_id" => s['id'].to_i
      }
    }

    res["query_type"] = qt
    res["#{self.class.to_s.remove("Mappack").downcase}_id"] = self.inner_id

    # Log
    player = Player.find_by(metanet_id: metanet_id)
    if !player.nil? && !player.name.nil?
      text = "#{player.name.to_s} requested #{self.name} leaderboards"
    else
      text = "#{self.name} leaderboards requested"
    end
    dbg(res.to_json) if SOCKET_LOG
    dbg(text)

    # Return leaderboards
    res.to_json
  end

  # Updates the rank and tied_rank fields of a specific mode, necessary when
  # there's a new score (or when one is deleted later).
  # Returns the rank of a specific player, if the player_id is passed
  def update_ranks(mode = 'hs', player_id = nil)
    return -1 if !['hs', 'sr'].include?(mode)
    rank = -1
    board = leaderboard(mode, true, truncate: 0, pluck: false)
    tied_score = board[0]["score_#{mode}"]
    tied_rank = 0
    board.each_with_index{ |s, i|
      rank = i if !player_id.nil? && s.player_id == player_id
      score = mode == 'hs' ? s.score_hs : s.score_sr
      if mode == 'hs' ? score < tied_score : score > tied_score
        tied_rank = i
        tied_score = score
      end
      s.update("rank_#{mode}".to_sym => i, "tied_rank_#{mode}".to_sym => tied_rank)
    }
    rank
  rescue
    -1
  end

  # Delete all the scores that aren't keepies (were never a hs/sr PB),
  # and which no longer have the max/min amount of gold collected.
  # If a player is not specified, do this operation for all players present
  # in this highscoreable.
  def delete_obsoletes(player = nil)
    if player
      ids = [player.id]
    else
      ids = scores.group(:player_id).pluck(:player_id)
    end

    ids.each{ |pid|
      score_list = scores.where(player_id: pid)
      gold_max = score_list.maximum(:gold)
      gold_min = score_list.minimum(:gold)
      pb_hs = nil # Highscore PB
      pb_sr = nil # Speedrun PB
      keepies = []
      score_list.order(:id).each{ |s|
        keepie = false
        if pb_hs.nil? || s.score_hs > pb_hs
          pb_hs = s.score_hs
          keepie = true
        end
        if pb_sr.nil? || s.score_sr < pb_sr
          pb_sr = s.score_sr
          keepie = true
        end
        keepies << s.id if keepie
      }
      score_list.where(rank_hs: nil, rank_sr: nil)
                .where("gold < #{gold_max} AND gold > #{gold_min}")
                .where.not(id: keepies)
                .each(&:wipe)
    }
    true
  rescue => e
    lex(e, 'Failed to delete obsolete scores.')
    false
  end

  # Verifies the integrity of a replay by generating the security hash and
  # comparing it with the submitted one.
  #
  # The format used by N++ is:
  #   Hash = SHA1(MapHash + ScoreString)
  # where:
  #   MapHash = SHA1(Pwd + MapData) [see Map#hash]
  #       Pwd     = Hardcoded password (not present in outte's source code)
  #       MapData = Map's data [see Map#dump_level(hash: true)]
  #   ScoreString = (Score * 1000) rounded as an integer
  #
  # Notes:
  #   - Since this depends on both the score and the map data, a score cannot
  #     be submitted if either have been tampered with.
  #   - The modulo 2 ** 32 is to simulate 4-byte unsigned integer arithmetic,
  #     which is what N++ uses. Negative scores (which sometimes happen erroneously)
  #     then underflow, so we need to replicate this behaviour to match the hashes.
  def _verify_replay(ninja_check, score, c: true, v: nil)
    c_hash = hashes.find_by(version: v)
    map_hash = c && c_hash ? c_hash.sha1_hash : _hash(c: c, v: v)
    return true if !map_hash
    score = ((1000.0 * score / 60.0 + 0.5).floor % 2 ** 32).to_s
    sha1(map_hash + score, c: c) == ninja_check
  end

  def verify_replay(ninja_check, score, all: true)
    (all ? versions : [version]).each{ |v|
      #return true if _verify_replay(ninja_check, score, v: v, c: false)
      return true if _verify_replay(ninja_check, score, v: v, c: true)
    }
    false
  end
end

class MappackLevel < ActiveRecord::Base
  include Map
  include MappackHighscoreable
  include Levelish
  has_many :mappack_scores, as: :highscoreable
  has_many :mappack_hashes, as: :highscoreable, dependent: :delete_all
  belongs_to :mappack
  belongs_to :mappack_episode, foreign_key: :episode_id
  alias_method :scores,   :mappack_scores
  alias_method :episode,  :mappack_episode
  alias_method :episode=, :mappack_episode=
  alias_method :hashes,   :mappack_hashes
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

  def self.mappack
    MappackLevel
  end

  def self.vanilla
    Level
  end

  # Update all mappack level SHA1 hashes (for every version)
  # 'pre' parameter is unused (as we force it to false, since we always want
  # to recompute the level hashes), but is left there for compatibility with the
  # Episode/Story versions of this method
  def self.update_hashes(mappack: nil, pre: false)
    total = 0
    list = self.where(mappack ? "mappack_id = #{mappack.id}" : '')
    count = list.count
    list.find_each.with_index{ |l, i|
      dbg("Updating mappack hashes for level #{i + 1} / #{count}...", progress: true)
      total += l.update_hashes(pre: false)
    }
    Log.clear
    total
  end

  def versions
    MappackData.where(highscoreable_id: id)
               .where("tile_data IS NOT NULL OR object_data IS NOT NULL")
               .distinct
               .order(:version)
               .pluck(:version)
  end

  # Return the tile data, optionally specify a version, otherwise pick last
  # Can also return all available versions as a hash
  def tile_data(version: nil, all: false)
    data = MappackData.where(highscoreable_id: id)
                      .where(version ? "version <= #{version}" : '')
                      .where.not(tile_data: nil)
    return nil if data.empty?

    if all
      data.pluck(:version, :tile_data).to_h
    else
      data.order(version: :desc).first.tile_data
    end
  rescue
    nil
  end

  # Return the object data, optionally specify a version, otherwise pick last
  # Can also return all available versions as a hash
  def object_data(version: nil, all: false)
    data = MappackData.where(highscoreable_id: id)
                      .where(version ? "version <= #{version}" : '')
                      .where.not(object_data: nil)
    return nil if data.empty?

    if all
      data.pluck(:version, :object_data).to_h
    else
      data.order(version: :desc).first.object_data
    end
  rescue
    nil
  end

  # Compare hashes generated by Ruby and STB
  def compare_hashes
    # Prepare map data to hash
    map_data = dump_level(hash: true)
    return true if map_data.nil?
    to_hash = PWD + map_data[0xB8..-1]

    # Hash
    hash_c = sha1(to_hash, c: true)
    hash_ruby = sha1(to_hash, c: false)
    return false if !hash_c || !hash_ruby

    return hash_c == hash_ruby
  end
end

class MappackEpisode < ActiveRecord::Base
  include MappackHighscoreable
  include Episodish
  has_many :mappack_levels, foreign_key: :episode_id
  has_many :mappack_scores, as: :highscoreable
  has_many :mappack_hashes, as: :highscoreable, dependent: :delete_all
  has_many :mappack_scores_tweaks, foreign_key: :episode_id
  belongs_to :mappack
  belongs_to :mappack_story, foreign_key: :story_id
  alias_method :levels, :mappack_levels
  alias_method :scores, :mappack_scores
  alias_method :hashes, :mappack_hashes
  alias_method :story,  :mappack_story
  alias_method :story=, :mappack_story=
  alias_method :tweaks, :mappack_scores_tweaks
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

  def self.mappack
    MappackEpisode
  end

  def self.vanilla
    Episode
  end

  # Update all mappack episode SHA1 hashes (for every version)
  def self.update_hashes(mappack: nil, pre: false)
    total = 0
    list = self.where(mappack ? "mappack_id = #{mappack.id}" : '')
    count = list.count
    list.find_each.with_index{ |e, i|
      dbg("Updating mappack hashes for episode #{i + 1} / #{count}...", progress: true)
      total += e.update_hashes(pre: pre)
    }
    Log.clear
    total
  end

  def versions
    MappackData.where("highscoreable_id DIV 5 = #{id}")
               .where("tile_data IS NOT NULL OR object_data IS NOT NULL")
               .distinct
               .order(:version)
               .pluck(:version)
  end

  # Computes the episode's hash, which the game uses for integrity verifications
  # If 'pre', take the precomputed level hashes, otherwise compute them
  def _hash(c: false, v: nil, pre: false)
    hashes = levels.order(:id).map{ |l|
      stored = l.hashes.where("version <= #{v}").order(:version).last
      c && pre && stored ? stored.sha1_hash : l._hash(c: c, v: v)
    }.compact
    hashes.size < 5 ? nil : hashes.join
  end
end

class MappackStory < ActiveRecord::Base
  include MappackHighscoreable
  include Storyish
  has_many :mappack_episodes, foreign_key: :story_id
  has_many :mappack_scores, as: :highscoreable
  has_many :mappack_hashes, as: :highscoreable, dependent: :delete_all
  belongs_to :mappack
  alias_method :scores,   :mappack_scores
  alias_method :episodes, :mappack_episodes
  alias_method :hashes,   :mappack_hashes
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

  def self.mappack
    MappackStory
  end

  def self.vanilla
    Story
  end

  # Update all mappack story SHA1 hashes (for every version)
  def self.update_hashes(mappack: nil, pre: false)
    total = 0
    list = self.where(mappack ? "mappack_id = #{mappack.id}" : '')
    count = list.count
    list.find_each.with_index{ |s, i|
      dbg("Updating mappack hashes for story #{i + 1} / #{count}...", progress: true)
      total += s.update_hashes(pre: pre)
    }
    Log.clear
    total
  end

  def versions
    MappackData.where("highscoreable_id DIV 25 = #{id}")
               .where("tile_data IS NOT NULL OR object_data IS NOT NULL")
               .distinct
               .order(:version)
               .pluck(:version)
  end

  # Computes the story's hash, which the game uses for integrity verifications
  # If 'pre', take the precomputed level hashes, otherwise compute them
  def _hash(c: false, v: nil, pre: false)
    hashes = levels.order(:id).map{ |l|
      stored = l.hashes.where("version <= #{v}").order(:version).last
      c && pre && stored ? stored.sha1_hash : l._hash(c: c, v: v)
    }.compact
    return nil if hashes.size < 25
    work = 0.chr * 20
    25.times.each{ |i|
      work = sha1(work + hashes[i], c: c)
    }
    work
  end
end

class MappackScore < ActiveRecord::Base
  include Scorish
  has_one :mappack_demo, foreign_key: :id
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  belongs_to :mappack
  alias_method :demo,  :mappack_demo
  alias_method :demo=, :mappack_demo=
  create_enum(:tab, TABS_NEW.map{ |k, v| [k, v[:mode] * 7 + v[:tab]] }.to_h)

  # TODO: Add integrity checks and warnings in Demo.parse

  # Verify, parse and save a submitted run, respond suitably
  def self.add(code, query, req = nil)
    # Parse player ID
    uid = query['user_id'].to_i
    if uid <= 0 || uid >= 10000000
      alert("Invalid player (ID #{uid}) submitted a score")
      return
    end

    # Apply blacklist
    name = "ID:#{uid}"
    if HACKERS.key?(uid) || CHEATERS.key?(uid)
      name = (HACKERS[uid] || CHEATERS[uid]).first
      alert("Blacklisted player #{name} submitted a score", discord: true)
      return
    end

    # Parse type
    type = TYPES.find{ |_, h| query.key?("#{h[:name].downcase}_id") }[1] rescue nil
    if type.nil?
      alert("Score submitted: Type not found")
      return
    end
    id_field = "#{type[:name].downcase}_id"

    # Craft response fields
    res = {
      'better'    => 0,
      'score'     => query['score'].to_i,
      'rank'      => -1,
      'replay_id' => -1,
      'user_id'   => uid,
      'qt'        => query['qt'].to_i,
      id_field    => query[id_field].to_i
    }

    # Find player
    player = Player.find_or_create_by(metanet_id: uid)
    name = !player.name.nil? ? player.name : "ID:#{player.metanet_id}"

    # Find mappack
    mappack = Mappack.find_by(code: code)
    if mappack.nil?
      alert("Score submitted by #{name}: Mappack '#{code}' not found")
      return
    end

    # Find highscoreable
    sid = query[id_field].to_i
    h = "Mappack#{type[:name]}".constantize.find_by(mappack: mappack, inner_id: sid)
    if h.nil?
      # If highscoreable not found, and forwarding is disabled, return nil
      if !CLE_FORWARD
        alert("Score submitted by #{name}: #{type[:name]} ID:#{sid} for mappack '#{code}' not found")
        return
      end

      # If highscoreable not found, but forwarding is enabled, forward to Metanet
      # Also, try to update the corresponding Metanet scores in outte (in parallel)
      res = forward(req)
      _thread(release: true) do
        h = (sid >= MIN_ID ? Userlevel : type[:name].constantize).find_by(id: sid)
        h.update_scores(fast: true) if h
      end if !res.nil?
      return res
    end
    action_inc('http_submit')

    # Parse demos and compute new scores
    demos = Demo.parse(query['replay_data'], type[:name])
    score_hs = (60.0 * query['score'].to_i / 1000.0).round
    score_sr = demos.map(&:size).sum
    score_sr /= 2 if h.mode == 1 # Coop demos contain 2 sets of inputs

    # Tweak level scores submitted within episode runs
    score_hs_orig = score_hs
    if type[:name] == 'Level'
      score_hs = MappackScoresTweak.tweak(score_hs, player, h, Demo.parse_header(query['replay_data']))
      if score_hs.nil?
        alert("Tweaking of score submitted by #{name} to #{h.name} failed", discord: true)
        score_hs = score_hs_orig
      end
    end

    # Compute gold count from hs and sr scores
    goldf = MappackScore.gold_count(type[:name], score_hs, score_sr)
    gold = goldf.round # Save floating value for later

    # Verify replay integrity by checking security hash
    legit = h.verify_replay(query['ninja_check'], score_hs_orig)
    if !legit
      _thread do
        alert("#{name} submitted a score to #{h.name} with an invalid security hash", discord: true)
      end if WARN_INTEGRITY
      return res.to_json if INTEGRITY_CHECKS
    end

    # Verify additional mappack-wise requirements
    return if !mappack.check_requirements(demos)

    # Fetch old PB's
    scores = MappackScore.where(highscoreable: h, player: player)
    score_hs_max = scores.maximum(:score_hs)
    score_sr_min = scores.minimum(:score_sr)
    gold_max = scores.maximum(:gold)
    gold_min = scores.minimum(:gold)

    # Determine if new score is better and has to be saved
    res['better'] = 0
    hs = false
    sr = false
    gp = false
    gm = false
    if score_hs_max.nil? || score_hs > score_hs_max
      scores.update_all(rank_hs: nil, tied_rank_hs: nil)
      res['better'] = 1
      hs = true
    end
    if score_sr_min.nil? || score_sr < score_sr_min
      scores.update_all(rank_sr: nil, tied_rank_sr: nil)
      sr = true
    end
    if gold_max.nil? || gold > gold_max
      gp = true
      gold_max = gold
    end
    if gold_min.nil? || gold < gold_min
      gm = true
      gold_min = gold
    end

    # If score improved in either mode
    id = -1
    if hs || sr || gp || gm
      # Create new score and demo
      score = MappackScore.create(
        rank_hs:       hs ? -1 : nil,
        tied_rank_hs:  hs ? -1 : nil,
        rank_sr:       sr ? -1 : nil,
        tied_rank_sr:  sr ? -1 : nil,
        score_hs:      score_hs,
        score_sr:      score_sr,
        mappack_id:    mappack.id,
        tab:           h.tab,
        player:        player,
        metanet_id:    player.metanet_id,
        highscoreable: h,
        date:          Time.now.strftime(DATE_FORMAT_MYSQL),
        gold:          gold
      )
      id = score.id
      MappackDemo.create(id: id, demo: Demo.encode(demos))

      # Verify hs score integrity by checking calculated gold count
      if (!MappackScore.verify_gold(goldf) && type[:name] != 'Story') || (h.gold && gold > h.gold) || (gold < 0)
        _thread do
          alert("Potentially incorrect hs score submitted by #{name} in #{h.name} (ID #{score.id})", discord: true)
        end
      end

      # Warn if the score submitted failed the map data integrity checks, and save it
      # to analyze it later (and possibly polish the hash algorithm)
      BadHash.find_or_create_by(id: id).update(
        npp_hash: query['ninja_check'],
        score: score_hs_orig
      ) if !legit

      # Warn if mappack version is outdated
      v1 = (req.path.split('/')[1][/\d+$/i] || 1).to_i
      v2 = mappack.version
      if WARN_VERSION && v1 != v2
        _thread do
          alert("#{name} submitted a score to #{h.name} with an incorrect mappack version (#{v1} vs #{v2})", discord: true)
        end
      end
    end

    # Update ranks and completions if necessary
    h.update_ranks('hs') if hs
    h.update_ranks('sr') if sr
    h.update(completions: h.scores.where.not(rank_hs: nil).count) if hs || sr

    # Delete obsolete scores of the player in the highscoreable
    h.delete_obsoletes(player)

    # Fetch player's best scores, to fill remaining response fields
    best_hs = MappackScore.where(highscoreable: h, player: player)
                          .where.not(rank_hs: nil)
                          .order(rank_hs: :asc)
                          .first
    best_sr = MappackScore.where(highscoreable: h, player: player)
                          .where.not(rank_sr: nil)
                          .order(rank_sr: :asc)
                          .first
    rank_hs = best_hs.rank_hs rescue nil
    rank_sr = best_sr.rank_sr rescue nil
    replay_id_hs = best_hs.id rescue nil
    replay_id_sr = best_sr.id rescue nil
    res['rank'] = rank_hs || rank_sr || -1
    res['replay_id'] = replay_id_hs || replay_id_sr || -1

    # Finish
    dbg(res.to_json) if SOCKET_LOG
    dbg("#{name} submitted a score to #{h.name}")
    return res.to_json
  rescue => e
    lex(e, "Failed to add score submitted by #{name} to mappack '#{code}'")
    return
  end

  # Respond to a request for leaderboards
  def self.get_scores(code, query, req = nil)
    name = "?"

    # Parse type
    type = TYPES.find{ |_, h| query.key?("#{h[:name].downcase}_id") }[1] rescue nil
    if type.nil?
      alert("Getting scores: Type not found")
      return
    end
    sid = query["#{type[:name].downcase}_id"].to_i
    name = "ID:#{sid}"

    # Find mappack
    mappack = Mappack.find_by(code: code)
    if mappack.nil?
      alert("Getting scores: Mappack '#{code}' not found")
      return
    end

    # Find highscoreable
    h = "Mappack#{type[:name]}".constantize.find_by(mappack: mappack, inner_id: sid)
    if h.nil?
      return forward(req) if CLE_FORWARD
      alert("Getting scores: #{type[:name]} #{name} for mappack '#{code}' not found")
      return
    end
    name = h.name

    # Get scores
    action_inc('http_scores')
    return h.get_scores(query['qt'].to_i, query['user_id'].to_i)
  rescue => e
    lex(e, "Failed to get scores for #{name} in mappack '#{code}'")
    return
  end

  # Respond to a request for a replay
  def self.get_replay(code, query, req = nil)
    # Integrity checks
    if !query.key?('replay_id')
      alert("Getting replay: Replay ID not provided")
      return
    end

    # Parse type (no type = level)
    type = TYPES.find{ |_, h| query['qt'].to_i == h[:qt] }[1] rescue nil
    if type.nil?
      alert("Getting replay: Type #{query['qt'].to_i} is incorrect")
      return
    end

    # Find mappack
    mappack = Mappack.find_by(code: code)
    if mappack.nil?
      alert("Getting replay: Mappack '#{code}' not found")
      return
    end

    # Find player (for logging purposes only)
    player = Player.find_by(metanet_id: query['user_id'].to_i)
    name = !player.nil? ? player.name : "ID:#{query['user_id']}"

    # Find score and perform integrity checks
    score = MappackScore.find_by(id: query['replay_id'].to_i)
    if score.nil?
      return forward(req) if CLE_FORWARD
      alert("Getting replay: Score with ID #{query['replay_id']} not found")
      return
    end

    if score.highscoreable.mappack.code != code
      return forward(req) if CLE_FORWARD
      alert("Getting replay: Score with ID #{query['replay_id']} is not from mappack '#{code}'")
      return
    end

    if score.highscoreable.basetype != type[:name]
      return forward(req) if CLE_FORWARD
      alert("Getting replay: Score with ID #{query['replay_id']} is not from a #{type[:name].downcase}")
      return
    end

    # Do not return replays for protected boards
    return nil if score.highscoreable.is_protected?

    # Find replay
    demo = score.demo
    if demo.nil? || demo.demo.nil?
      alert("Getting replay: Replay with ID #{query['replay_id']} not found")
      return
    end

    # Return replay
    dbg("#{name} requested replay #{query['replay_id']}")
    action_inc('http_replay')
    score.dump_replay
  rescue => e
    lex(e, "Failed to get replay with ID #{query['replay_id']} from mappack '#{code}'")
    return
  end

  # Manually change a score, given either:
  # - A player and a highscoreable, in which case, his current hs PB will be taken
  # - An ID, in which case that specific score will be chosen
  # It performs score validation via gold check before changing it
  def self.patch_score(id, highscoreable, player, score, silent: false)
    # Find score
    if !id.nil? # If ID has been provided
      s = MappackScore.find_by(id: id)
      silent ? return : perror("Mappack score of ID #{id} not found") if s.nil?
      highscoreable = s.highscoreable
      player = s.player
      scores = MappackScore.where(highscoreable: highscoreable, player: player)
      silent ? return : perror("#{player.name} does not have a score in #{highscoreable.name}") if scores.empty?
    else # If highscoreable and player have been provided
      silent ? return : perror("#{highscoreable.name} does not belong to a mappack") if !highscoreable.is_a?(MappackHighscoreable)
      scores = self.where(highscoreable: highscoreable, player: player)
      silent ? return : perror("#{player.name} does not have a score in #{highscoreable.name}") if scores.empty?
      s = scores.where.not(rank_hs: nil).first
      silent ? return : perror("#{player.name}'s leaderboard score in #{highscoreable.name} not found") if s.nil?
    end

    # Score integrity checks
    if !score
      score = s.ntrace_score
      silent ? return : perror("ntrace failed to compute correct score") if !score
    end
    new_score = (score * 60).round
    gold = MappackScore.gold_count(highscoreable.type, new_score, s.score_sr)
    silent ? return : perror("The inferred gold count is incorrect") if gold.round < 0 || gold.round > highscoreable.gold
    silent ? return : perror("That score is incompatible with the framecount") if !MappackScore.verify_gold(gold) && !highscoreable.type.include?('Story')

    # Change score
    old_score = s.score_hs.to_f / 60.0
    silent ? return : perror("#{player.name}'s score (#{s.id}) in #{highscoreable.name} is already #{'%.3f' % old_score}") if s.score_hs == new_score
    s.update(score_hs: new_score, gold: gold.round)

    # Update player's ranks
    scores.update_all(rank_hs: nil, tied_rank_hs: nil)
    max = scores.where(score_hs: scores.pluck(:score_hs).max).order(:date).first
    max.update(rank_hs: -1, tied_rank_hs: -1) if max

    # Update global ranks
    highscoreable.update_ranks('hs')
    succ("Patched #{player.name}'s score (#{s.id}) in #{highscoreable.name} from #{'%.3f' % old_score} to #{'%.3f' % score}")
  rescue => e
    lex(e, 'Failed to patch score')
  end

  # Calculate gold count from hs and sr scores
  # We return a FLOAT, not an integer. See the next function for details.
  def self.gold_count(type, score_hs, score_sr)
    case type.remove('Mappack')
    when 'Level'
      tweak = 1
    when 'Episode'
      tweak = 5
    when 'Story'
      tweak = 25
    else
      alert("Incorrect type when calculating gold count")
      tweak = 0
    end
    (score_hs + score_sr - 5400 - tweak).to_f / 120
  end

  # Verify if floating point gold count is close enough to an integer.
  #
  # Context: Sometimes the hs score is incorrectly calculated by the game,
  # and we can use this as a test to find incorrect scores, if the calculated
  # gold count is not exactly an integer.
  def self.verify_gold(gold)
    (gold - gold.round).abs < 0.001
  end

  # Perform the gold check (see the 2 methods above) for every score in the
  # database, returning the scores failing the check.
  def self.gold_check(id: MIN_REPLAY_ID, mappack: nil, strict: false)
    self.joins('INNER JOIN mappack_levels ON mappack_levels.id = highscoreable_id')
        .joins('INNER JOIN players on players.id = player_id')
        .where("highscoreable_type = 'MappackLevel' AND mappack_scores.id >= #{id}")
        .where(mappack ? "mappack_scores.mappack_id = #{mappack.id}" : '')
        .where(strict ? "rank_hs < 20 OR rank_sr < 20" : '')
        .having('remainder > 0.001 OR mappack_scores.gold < 0 OR mappack_scores.gold > mappack_levels.gold')
        .order('highscoreable_id', 'mappack_scores.id')
        .pluck(
          'mappack_levels.name',
          'SUBSTRING(players.name, 1, 16)',
          'mappack_scores.id',
          'score_hs / 60.0',
          'rank_hs',
          'rank_sr',
          'gold',
          'mappack_levels.gold',
          'ABS(MOD((score_hs + score_sr - 5401) / 120, 1)) AS remainder'
        ).map{ |row| row[0..-4] + ["#{'%3d' % row[-3]} / #{'%3d' % row[-2]}"] }
  rescue => e
    lex(e, 'Failed to compute gold check.')
    [['Error', 'Error', 'Error', 'Error', 'Error', 'Error', 'Error']]
  end

  # Update the completion count for each mappack highscoreable, should only
  # need to be executed once, or occasionally, to seed them for the first
  # time. From then on, the score submission function updates the figure.
  def self.update_completions(mappack: nil)
    bench(:start) if BENCHMARK
    [MappackLevel, MappackEpisode, MappackStory].each{ |type|
      self.where(highscoreable_type: type).where.not(rank_hs: nil)
          .where(mappack ? "mappack_id = #{mappack.id}" : '')
          .group(:highscoreable_id)
          .order('count(highscoreable_id)', 'highscoreable_id')
          .count(:highscoreable_id)
          .group_by{ |id, count| count }
          .map{ |count, ids| [count, ids.map(&:first)] }
          .each{ |count, ids|
            type.where(id: ids).update_all(completions: count)
          }
    }
    bench(:step) if BENCHMARK
  end

  def archive
    self
  end

  def gold_count
    self.class.gold_count(highscoreable.type, score_hs, score_sr)
  end

  def verify_gold
    self.class.verify_gold(gold_count)
  end

  # Dumps demo data in the format N++ uses for server communications
  def dump_demo
    demos = Demo.decode(demo.demo, true)
    highscoreable.dump_demo(demos)
  rescue => e
    lex(e, "Failed to dump demo with ID #{id}")
    nil
  end

  # Dumps replay data (header + compressed demo data) in format used by N++
  def dump_replay
    type = TYPES[highscoreable.basetype]

    # Build header
    replay = [type[:rt]].pack('L<')               # Replay type (0 lvl/sty, 1 ep)
    replay << [id].pack('L<')                     # Replay ID
    replay << [highscoreable.inner_id].pack('L<') # Level ID
    replay << [player.metanet_id].pack('L<')      # User ID

    # Append replay and return
    inputs = dump_demo
    return if inputs.nil?
    replay << Zlib::Deflate.deflate(inputs, 9)
    replay
  rescue => e
    lex(e, "Failed to dump replay with ID #{id}")
    return
  end

  # Deletes a score, with the necessary cleanup (delete demo, and update ranks if necessary)
  def wipe
    # Save attributes before destroying the object
    hs = rank_hs != nil
    sr = rank_sr != nil
    h = highscoreable
    p = player

    # Destroy demo and score
    demo.destroy
    self.destroy

    # Update rank fields, if the score was actually on the boards
    scores = h.scores.where(player: p) if hs || sr

    if hs
      scores.update_all(rank_hs: nil, tied_rank_hs: nil)
      max = scores.where(score_hs: scores.pluck(:score_hs).max).order(:date).first
      max.update(rank_hs: -1, tied_rank_hs: -1) if max
      h.update_ranks('hs')
    end

    if sr
      scores.update_all(rank_sr: nil, tied_rank_sr: nil)
      min = scores.where(score_sr: scores.pluck(:score_sr).min).order(:date).first
      min.update(rank_sr: -1, tied_rank_sr: -1) if min
      h.update_ranks('sr')
    end

    true
  rescue => e
    lex(e, 'Failed to wipe mappack score.')
    false
  end

  def compare_hashes
    # Prepare map data to hash
    map_data = highscoreable.dump_level(hash: true)
    return true if map_data.nil?
    to_hash = PWD + map_data[0xB8..-1]

    # Hash 1
    hash_c = sha1(to_hash, c: true)
    hash_ruby = sha1(to_hash, c: false)
    return false if !hash_c || !hash_ruby

    # Hash 2
    score = (1000.0 * score_hs.to_i / 60.0).round.to_s
    hash_c = sha1(hash_c + score, c: true)
    hash_ruby = sha1(hash_ruby + score, c: false)
    return false if !hash_c || !hash_ruby

    return hash_c == hash_ruby
  end

  # Calculate the score using ntrace
  def ntrace_score
    return false if !highscoreable || !demo || !demo.demo
    nsim = NSim.new(highscoreable.dump_level, [demo.demo])
    nsim.run
    nsim.score || false
  rescue => e
    lex(e, 'ntrace testing failed')
    nil
  end
end

class MappackDemo < ActiveRecord::Base
  include Demoish
  belongs_to :mappack_score, foreign_key: :id
  alias_method :score,  :mappack_score
  alias_method :score=, :mappack_score=

  # Delete orphaned demos (demos without a corresponding score)
  def self.sanitize
    orphans = joins('LEFT JOIN mappack_scores ON mappack_demos.id = mappack_scores.id')
                .where('mappack_scores.id IS NULL')
    count = orphans.count
    orphans.delete_all
    count
  end
end

# N++ sometimes submits individual level scores incorrectly when submitting
# episode runs. The fix required is to add the sum of the lengths of the
# runs for the previous levels in the episode, until we reach a level whose
# score was correct.

# Since all 5 level scores are not submitted in parallel, but in sequence, this
# table temporarily holds the adjustment, which will be updated and applied with
# each level, until all 5 are done, and then we delete it.
class MappackScoresTweak < ActiveRecord::Base
  belongs_to :player
  belongs_to :mappack_episode, foreign_key: :episode_id
  alias_method :episode, :mappack_episode
  alias_method :episode=, :mappack_episode=

  # Returns the score if success, nil otherwise
  def self.tweak(score, player, level, header)
    # Not in episode, not tweaking
    return score if header.type != 1

    # Create or fetch tweak
    index = level.inner_id % 5
    if index == 0
      tw = self.find_or_create_by(player: player, episode_id: level.episode.id)
      tw.update(tweak: 0, index: 0) # Initialize tweak
    else
      tw = self.find_by(player: player, episode_id: level.episode.id)
      if tw.nil? # Tweak should exist
        alert("Tweak for #{player.name}'s #{level.episode.name} run should exit")
        return nil
      end
    end

    # Ensure tweak corresponds to the right level
    if tw.index != index
      alert("Tweak for #{player.name}'s #{level.episode.name} has index #{tw.index}, should be #{index}")
      return nil
    end

    # Tweak if necessary
    if header.id == level.inner_id # Tweak
      score += tw.tweak
      tw.tweak += header.framecount - 1
      tw.save
    else # Don't tweak, reset tweak for later
      tw.update(tweak: header.framecount - 1)
    end

    # Prepare tweak for next level
    index < 4 ? tw.update(index: index + 1) : tw.destroy

    # Tweaked succesfully
    return score
  rescue => e
    lex(e, 'Failed to tweak score')
    nil
  end
end

# A table to store all the calculated integrity hashes that do not match the
# submitted one. This could mean one of two things:
# 1) The score has been submitted with a different level, or has been cheated.
#    Either way, it needs to be checked.
# 2) Our SHA1 algo doesn't match the one used by N++, so we want to polish that.
#    This is currently happening sometimes (Edit: Not anymore)
class BadHash < ActiveRecord::Base
  # Remove orphaned bad hashes (missing corresponding mappack score)
  def self.sanitize
    orphans = joins('LEFT JOIN mappack_scores ON bad_hashes.id = mappack_scores.id')
                .where('mappack_scores.id IS NULL')
    count = orphans.count
    orphans.delete_all
    count
  end
end

# This table stores the Discord IDs for the channels that are dedicated to each
# mappack, so that decisions (such as default mappack for commands) can be based
# on this information
class MappackChannel < ActiveRecord::Base
  belongs_to :mappack
end

# This table stores all the precomputed SHA1 hashes for all versions of every
# mappack level, episode and story. This is used for replay integrity validation,
# and is actually what takes the most time.
class MappackHash < ActiveRecord::Base
  belongs_to :highscoreable, polymorphic: true

  # Update all hashes for all mappack highscoreables
  def self.seed(mappack: nil, types: [Level, Episode, Story])
    total = 0
    types.each{ |t| total += t.mappack.update_hashes(mappack: mappack, pre: true) }
    total
  end
end
