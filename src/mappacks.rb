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

  # Read the score list and write to the db
  def read_scores(v: nil)
    v = version || 1 if !v

    # Integrity checks
    dir = folder(v: v)
    if !dir
      err("Directory for mappack #{verbatim(code)} not found")
      return
    end
    path = File.join(dir, FILENAME_MAPPACK_SCORES)
    if !File.file?(path)
      err("Scores file for mappack #{verbatim(code)} not found")
      return
    end

    # Parse scores file
    file = File.binread(path)
    scores = file.split("\n").map{ |l| round_score(l.strip.to_f) }
    maps = levels.order(:id)
    if maps.size != scores.size
      err("Scores file for mappack #{verbatim(code)} has incorrect length (#{scores.size} scores vs #{maps.size} maps)")
      return
    end

    # Write level scores (framecount assumes no gold)
    count = maps.size
    maps.each_with_index{ |m, i|
      dbg("Adding level score #{i + 1} / #{count}...", pad: true, newline: false)
      framecount = 90 * 60 - (scores[i] * 60.0).round + 1
      m.update(dev_hs: scores[i], dev_sr: framecount)
    }

    # Write episode scores
    count = episodes.size
    episodes.each_with_index{ |m, i|
      dbg("Adding episode score #{i + 1} / #{count}...", pad: true, newline: false)
      framecount = m.levels.sum(:dev_sr)
      score = [round_score(90 - (framecount - 5) / 60.0), 0].max
      m.update(dev_hs: score, dev_sr: framecount)
    }

    # Write story scores
    count = stories.size
    stories.each_with_index{ |m, i|
      dbg("Adding story score #{i + 1} / #{count}...", pad: true, newline: false)
      framecount = m.levels.sum(:dev_sr)
      score = [round_score(90 - (framecount - 25) / 60.0), 0].max
      m.update(dev_hs: score, dev_sr: framecount)
    }

    Log.clear
  rescue => e
    lex(e, "Failed to read scores file for mappack #{verbatim(code)}")
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
  def set_info(name: nil, author: nil, date: nil, channel: nil, version: nil, enabled: false, public: false, fractional: false)
    self.update(name:       name)        if name
    self.update(authors:    author)      if author
    self.update(version:    version)     if version
    self.update(enabled:    enabled)     if !enabled.nil?
    self.update(public:     public)      if !public.nil?
    self.update(fractional: fractional)  if !fractional.nil?
    self.update(date:    Time.strptime(date, '%Y/%m/%d').strftime(DATE_FORMAT_MYSQL)) if date
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

  # Stored SHA1 hash computed using STB's C implementation
  def saved_hash(v: nil)
    hashes.where(v ? "`version` <= #{v}" : '').order(:version).last&.sha1_hash
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
  # depending on the mode (hs / sr). Only scores with non-null rank field
  # are returned. Gold boards work differently.
  def leaderboard(
      m         = 'hs',  # Playing mode (hs, sr, gm)
      truncate:   20,    # How many scores to take (0 = all)
      pluck:      true,  # Pluck or keep Rails relation
      aliases:    false, # Use player names or display names
      metanet_id: nil,   # Player making the request if coming from CLE
      offset:     0,     # Starting rank of the board
      frac:       false, # Include fractional field
      obsolete:   false, # Include obsolete runs (null rank)
      date:       nil,   # Maximum date threshold (when no obsoletes, only works well when plucking)
      cheated:    false  # Include cheated runs, only for compatibility with Metanet ones
    )
    m = 'hs' if !['hs', 'sr', 'gm'].include?(m)
    names = aliases ? 'IF(display_name IS NOT NULL, display_name, name)' : 'name'
    attr_names = %W[id score_#{m} name metanet_id player_id]

    # Check if a manual replay ID has been set, so that we only select that one
    manual = GlobalProperty.find_by(key: 'replay_id').value rescue nil
    use_manual = manual && metanet_id == BOTMASTER_NPP_ID

    # Handle manual board
    if use_manual
      attrs = %W[mappack_scores.id score_#{m} #{names} metanet_id player_id]
      board = scores.where(id: manual)
    else
      case m
      when 'hs', 'sr' # Handle standard boards
        attrs = %W[mappack_scores.id score_#{m} #{names} metanet_id player_id]
        attr_names << 'fraction' if frac
        attrs      << 'fraction' if frac
        board = scores.where(!obsolete && !date ? "rank_#{m} IS NOT NULL" : '')
                      .where(date ? "UNIX_TIMESTAMP(`date`) <= #{date.to_i}" : '')
        sfield = "`score_#{m}`"
        sfield += (m == 'hs' ? ' - ' : ' + ') + '`fraction`' if frac
        order = m == 'hs' ? 'DESC' : 'ASC'
        board = board.order("#{sfield} #{order}", '`date` ASC')
        #board = board.order("rank_#{m} ASC")
      when 'gm'       # Handle gold boards
        attrs = [
          'MIN(subquery.id) AS id',
          'MIN(score_gm) AS score_gm',
          "MIN(#{names}) AS name",
          'subquery.metanet_id',
          'MIN(player_id) AS player_id'
        ]
        join = <<~SQL
          INNER JOIN (
            SELECT metanet_id, MIN(gold) AS score_gm
            FROM mappack_scores
            WHERE highscoreable_id = #{id} AND highscoreable_type = '#{type}'
            GROUP BY metanet_id
          ) AS opt
          ON mappack_scores.metanet_id = opt.metanet_id AND gold = score_gm
        SQL
        subquery = scores.select(:id, :score_gm, :player_id, :metanet_id).joins(join)
        board = MappackScore.from(subquery).group(:metanet_id).order('score_gm', 'id')
      end
    end

    # Paginate (offset and truncate), fetch player names, and convert to hash
    board = board.offset(offset) if offset > 0
    board = board.limit(truncate) if truncate > 0 && !pluck
    return board if !pluck
    board = board.joins("INNER JOIN `players` ON `players`.`id` = `player_id`")
                 .pluck(*attrs).map{ |s| attr_names.zip(s).to_h }
    board.uniq!{ |s| s['metanet_id'] } if !obsolete && date
    board = board.take(truncate) if truncate > 0
    board
  end

  # Return a list of all dates where the top20 changed
  def changes(board = 'hs')
    hs = board == 'hs'
    dates = []
    top20 = {}
    scores.order(:date).pluck(:metanet_id, :score_hs, :score_sr, :date)
                       .each{ |metanet_id, score_hs, score_sr, date|
      # Only PB's can produce a visible change
      old = top20[metanet_id]
      cur = hs ? score_hs : score_sr
      pb = !old || (hs ? cur > old[:score] : cur < old[:score])
      next if !pb

      # Only changes in the top20 are visible
      bottom = top20.max_by{ |id, h| [hs ? -h[:score] : h[:score], h[:date]] }
      outside = top20.size >= 20 && (hs ? cur <= bottom[1][:score] : cur >= bottom[1][:score])
      next if outside

      # Save date and update top20
      dates << date
      top20[metanet_id] = { score: cur, date: date }
      top20.delete(bottom[0]) if top20.size > 20
    }
    dates
  end

  # Return scores in JSON format expected by N++
  def get_scores(qt = 0, metanet_id = nil, frac: false)
    # Compute offset
    m = qt == 2 ? 'sr' : 'hs'
    offset = 0
    if qt == 1 && metanet_id
      s = scores.where(metanet_id: metanet_id).where.not("rank_#{m}" => nil).first
      r = s ? s["rank_#{m}"] : nil
      n = completions
      offset = [0, [r - 10, n - 20].min].max if r && n && r < n
    end

    # Fetch leaderboard
    dev_score = m == 'hs' ? dev_hs : dev_sr
    count = dev_score ? 19 : 20
    board = leaderboard(m, truncate: count, metanet_id: metanet_id, offset: offset, frac: frac)
    res = {}

    # Adjust scores
    board.each_with_index.map{ |s, i|
      s['score_hs'] -= s['fraction'] if frac && m == 'hs'
      s['score_sr'] += s['fraction'] if frac && m == 'sr'
      s['score_hs'] /= 60.0 if m == 'hs'
    }

    # Inject DEV score
    if dev_score
      index = board.index{ |s|
        m == 'hs' ? s['score_hs'] <= dev_score : s['score_sr'] >= dev_score
      }
      score = { "score_#{m}" => dev_score, 'name' => DEV_PLAYER_NAME, 'id' => -1, 'metanet_id' => -1 }
      board.insert(index || -1, score)
    end

    # Format response
    # Note:
    #   In the replay ID field we use the lower bits to encode the real ID, and the
    #   the higher bits to encode the rank.  That way scores with a lower rank will
    #   also have a lower replay ID, so when the game re-sorts ties by replay ID in
    #   the Global  boards, they will actually be sorted properly  according to the
    #   full precision of the frac scores, as opposed to just the milliseconds.  We
    #   can later recover the correct ID in get_replay with basic bit manipulation.
    res["scores"] = board.take(20).each_with_index.map{ |s, i|
      {
        "score"     => (1000 * s["score_#{m}"]).round,
        "rank"      => offset + i,
        "user_id"   => s['metanet_id'].to_i,
        "user_name" => s['name'].to_s.remove("\\"),
        "replay_id" => pack_replay_id(i, s['id'].to_i)
      }
    }

    # ID fields
    res["query_type"] = qt
    res["#{self.class.to_s.remove("Mappack").downcase}_id"] = self.inner_id

    # Log
    player = Player.find_by(metanet_id: metanet_id)
    if !!player&.name
      text = "#{player.name.to_s} requested #{self.name} leaderboards"
    else
      text = "#{self.name} leaderboards requested"
    end
    dbg(text)

    # Return leaderboards
    res.to_json
  end

  # Updates the rank and tied_rank fields of a specific mode, necessary when
  # there's a new score (or when one is deleted later).
  def update_ranks(board, frac: false)
    # Fetch leaderboard sorted by score and date
    return false if !['hs', 'sr'].include?(board)
    list = leaderboard(board, truncate: 0, pluck: false, frac: frac)
    sfield = "`score_#{board}`"
    sfield += (board == 'hs' ? ' - ' : ' + ') + '`fraction`' if frac
    list = list.pluck(:id, sfield)
    return true if list.empty?

    # Compute ranks and tied ranks
    tied_score = list[0][1]
    tied_rank = 0
    list.each_with_index{ |s, i|
      if board == 'hs' ? s[1] < tied_score : s[1] > tied_score
        tied_rank = i
        tied_score = s[1]
      end
      s << i << tied_rank
    }

    # Update all rank and tied rank fields in a single SQL query
    ranks = list.map{ |s| "WHEN #{s[0]} THEN #{s[2]}" }.join(' ')
    ties = list.map{ |s| "WHEN #{s[0]} THEN #{s[3]}" }.join(' ')
    sql = <<~SQL
      UPDATE `mappack_scores`
      SET `rank_#{board}` = CASE id #{ranks} END,
          `tied_rank_#{board}` = CASE id #{ties} END
      WHERE id IN (#{list.map(&:first).join(", ")})
    SQL
    sql(sql)

    true
  rescue => e
    lex(e, "Failed to update ranks for #{self.class} #{id}")
    false
  end

  # Delete non-essential scores from the db:
  # - They were never a hs / sr PB.
  # - They aren't G++ / G-- PBs.
  # If a player is not specified, do this operation for all players present
  # in this highscoreable.
  def delete_obsoletes(player = nil, frac: false)
    # Fetch players to clean
    if player
      ids = [player.id]
    else
      ids = scores.group(:player_id).pluck(:player_id)
    end

    # Delete non-essential scores for each player
    deleted = ids.inject(0){ |sum, pid|
    # Fetch player scores
      query = scores.where(player_id: pid).order(:id)
      score_hs = frac ? '`score_hs` - `fraction`' : :score_hs
      score_sr = frac ? '`score_sr` + `fraction`' : :score_sr
      list = query.pluck(:id, score_hs, score_sr, :gold)

      # Find gold PBs
      gold_max = list.max_by(&:last).last
      gold_min = list.min_by(&:last).last

      # Find scores which were once a hs / sr PB
      pb_hs = -1
      pb_sr = 2 ** 16
      keepies = []
      list.each{ |id, score_hs, score_sr, gold|
        keepies << id if score_hs > pb_hs || score_sr < pb_sr
        pb_hs = score_hs if score_hs > pb_hs
        pb_sr = score_sr if score_sr < pb_sr
      }

      # Delete scores
      query = query.where(rank_hs: nil, rank_sr: nil)
                   .where("gold < #{gold_max} AND gold > #{gold_min}")
                   .where.not(id: keepies.uniq)
                   .each(&:destroy)
      sum + query.size
    }
    deleted
  rescue => e
    lex(e, 'Failed to delete obsolete scores.')
    -1
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
    map_hash = _hash(c: c, v: v, pre: true)
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
    if pre && c
      stored = saved_hash(v: v)
      return stored if stored
    end
    hashes = levels.order(:id).map{ |l| l._hash(c: c, v: v, pre: pre) }.compact
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
    if pre && c
      stored = saved_hash(v: v)
      return stored if stored
    end
    hashes = levels.order(:id).map{ |l| l._hash(c: c, v: v, pre: pre) }.compact
    return nil if hashes.size < 25
    hashes.inject(0.chr * 20){ |working, hash| sha1(working + hash, c: c) }
  end
end

class MappackScore < ActiveRecord::Base
  include Scorish
  has_one :mappack_demo, foreign_key: :id, dependent: :destroy
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  belongs_to :mappack
  after_destroy :cleanup
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
    frac = mappack.fractional

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
    frac &&= h.is_level?
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

    # Verify score integrity by performing gold check
    corrupt = type[:name] != 'Story' && !MappackScore.verify_gold(goldf)
    corrupt ||= h.gold && gold > h.gold || gold < 0

    # Verify additional mappack-wise requirements
    return if !mappack.check_requirements(demos)

    # Conmpute fractional score using NSim
    patched = false
    if frac
      sim_res = NSim.run(h.dump_level, [Demo.encode(demos)]){ |nsim|
        { score: nsim.score, frac: nsim.frac }
      }
      fraction = sim_res[:frac] || 1

      # If the sent hs score is corrupt, might as well see if we can patch it now
      if corrupt && sim_res[:score]
        new_hs = (60.0 * sim_res[:score]).round
        new_goldf = MappackScore.gold_count('Level', new_hs, score_sr)
        if MappackScore.verify_gold(new_goldf)
          score_hs = new_hs
          gold = new_goldf.round
          patched = true
        end
      end

      # Modify response
      res['score'] = (1000.0 * (score_hs - fraction) / 60.0).round
    end

    # Fetch old PB's
    scores = MappackScore.where(highscoreable: h, player: player)
    score_hs_max = scores.maximum(frac ? '`score_hs` - `fraction`' : :score_hs)
    score_sr_min = scores.minimum(frac ? '`score_sr` + `fraction`' : :score_sr)
    gold_max = scores.maximum(:gold)
    gold_min = scores.minimum(:gold)

    # Determine if new score is better and has to be saved
    hs = !score_hs_max || (frac ? score_hs - fraction : score_hs) > score_hs_max
    sr = !score_sr_min || (frac ? score_sr + fraction : score_sr) < score_sr_min
    gp = !gold_max || gold > gold_max
    gm = !gold_min || gold < gold_min
    scores.update_all(rank_hs: nil, tied_rank_hs: nil) if hs
    scores.update_all(rank_sr: nil, tied_rank_sr: nil) if sr
    res['better'] = hs || sr ? 1 : 0

    # If score improved in either mode
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
        gold:          gold,
        fraction:      frac ? fraction : 1,
        simulated:     frac
      )
      MappackDemo.create(id: score.id, demo: Demo.encode(demos))

      # Verify hs score integrity by checking calculated gold count
      if corrupt
        _thread do
          alert("#{patched ? 'Auto-patched p' : 'P'}otentially incorrect hs score submitted by #{name} in #{h.name} (ID #{score.id})", discord: true)
        end
      end

      # Warn if the score submitted failed the map data integrity checks, and save it
      # to analyze it later (and possibly polish the hash algorithm)
      BadHash.find_or_create_by(id: score.id).update(
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
    h.update_ranks('hs', frac: frac) if hs
    h.update_ranks('sr', frac: frac) if sr
    h.update(completions: h.scores.distinct.count(:player_id)) if hs || sr || gp || gm

    # Delete obsolete scores of the player in the highscoreable
    h.delete_obsoletes(player, frac: frac)

    # Fetch player's best scores, to fill remaining response fields
    best_hs = player.find_pb(h, 'hs', frac: frac)
    best_sr = player.find_pb(h, 'sr', frac: frac)
    rank_hs = best_hs.rank_hs rescue nil
    rank_sr = best_sr.rank_sr rescue nil
    replay_id_hs = best_hs.id rescue nil
    replay_id_sr = best_sr.id rescue nil
    res['rank'] = frac ? (1000000.0 * fraction / 60.0).round : rank_hs || rank_sr || -1
    res['replay_id'] = replay_id_hs || replay_id_sr || -1

    # Finish
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
    frac = mappack.fractional && h.is_level?
    name = h.name

    # Get scores
    action_inc('http_scores')
    return h.get_scores(query['qt'].to_i, query['user_id'].to_i, frac: frac)
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
    rank, replay_id = unpack_replay_id(query['replay_id'].to_i)

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
    score = MappackScore.find_by(id: replay_id)
    if score.nil?
      return forward(req) if CLE_FORWARD
      alert("Getting replay: Score with ID #{replay_id} not found")
      return
    end

    if score.highscoreable.mappack.code != code
      return forward(req) if CLE_FORWARD
      alert("Getting replay: Score with ID #{replay_id} is not from mappack '#{code}'")
      return
    end

    if score.highscoreable.basetype != type[:name]
      return forward(req) if CLE_FORWARD
      alert("Getting replay: Score with ID #{replay_id} is not from a #{type[:name].downcase}")
      return
    end

    # Do not return replays for protected boards
    return nil if score.highscoreable.is_protected?

    # Find replay
    demo = score.demo
    if demo.nil? || demo.demo.nil?
      alert("Getting replay: Replay with ID #{replay_id} not found")
      return
    end

    # Return replay
    dbg("#{name} requested replay #{replay_id} (#{query['replay_id'].to_i})")
    action_inc('http_replay')
    score.dump_replay(rank)
  rescue => e
    lex(e, "Failed to get replay with ID #{replay_id} from mappack '#{code}'")
    return
  end

  # Manually change a score, given either:
  # - A player and a highscoreable, in which case, his current hs PB will be taken
  # - An ID, in which case that specific score will be chosen
  # It performs score validation via gold check before changing it
  def self.patch_score(id, highscoreable, player, score, silent: false, frac: false)
    # Find score
    if !id.nil? # If ID has been provided
      s = MappackScore.find_by(id: id)
      perror("Mappack score of ID #{id} not found") if !s
      highscoreable = s.highscoreable
      player = s.player
      scores = MappackScore.where(highscoreable: highscoreable, player: player)
    else # If highscoreable and player have been provided
      perror("#{highscoreable.name} does not belong to a mappack") if !highscoreable.is_mappack?
      scores = MappackScore.where(highscoreable: highscoreable, player: player)
      perror("#{player.name} does not have a score in #{highscoreable.name}") if scores.empty?
      s = scores.where.not(rank_hs: nil).first
      perror("#{player.name}'s leaderboard score in #{highscoreable.name} not found") if !s
    end

    # Compute score and frac with NSim if not specified
    if !score
      perror("Mappack score #{s.id} has no associated demo.") if !s.demo&.demo
      res = NSim.run(highscoreable.dump_level, [s.demo.demo]){ |nsim| { score: nsim.score, frac: nsim.frac } }
      perror("ntrace failed to compute correct score") if !res[:score] || !res[:frac]
      s.update(fraction: res[:frac], simulated: true)
      score = res[:score]
    end

    # Score integrity checks
    new_score = (score * 60).round
    gold = MappackScore.gold_count(highscoreable.type, new_score, s.score_sr)
    perror("The inferred gold count is incorrect") if gold.round < 0 || gold.round > highscoreable.gold
    perror("That score is incompatible with the framecount") if !MappackScore.verify_gold(gold) && !highscoreable.type.include?('Story')

    # Change score and new computed gold count
    old_score = s.score_hs.to_f / 60.0
    perror("#{player.name}'s score (#{s.id}) in #{highscoreable.name} is already #{'%.3f' % old_score}") if s.score_hs == new_score
    s.update(score_hs: new_score, gold: gold.round)

    # Update ranks and remove obsolete scores potentially derived from the change
    player.update_rank(highscoreable, 'hs', frac: frac)
    highscoreable.delete_obsoletes(player, frac: frac)

    # Log
    succ("Patched #{player.name}'s score (#{s.id}) in #{highscoreable.name} from #{'%.3f' % old_score} to #{'%.3f' % score}")
  rescue => e
    lex(e, 'Failed to patch score')
  rescue OutteError
    raise unless silent
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
      type.where(mappack ? "mappack_id = #{mappack.id}" : '')
          .update_all(completions: 0)
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
      bench(:step) if BENCHMARK
    }
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
  def dump_replay(rank = 0)
    type = TYPES[highscoreable.basetype]
    replay_id = pack_replay_id(rank, id)

    # Build header
    replay = [type[:rt]].pack('L<')               # Replay type (0 lvl/sty, 1 ep)
    replay << [replay_id].pack('L<')              # Replay ID
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

  # Perform cleanup after destroying a score (delete demo, and update ranks if necessary)
  def cleanup
    # Demo is deleted automatically by the :dependent option
    return if !rank_hs && !rank_sr
    h = highscoreable_type.constantize.find(highscoreable_id)
    p = Player.find(player_id)
    frac = h.mappack.fractional && h.is_level?
    p.update_rank(h, 'hs', frac: frac) if !!rank_hs
    p.update_rank(h, 'sr', frac: frac) if !!rank_sr
  rescue => e
    lex(e, "Destroy cleanup for mappack score #{id} failed")
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

  # Return the score adjusted with the fractional part, if it exists
  def frac(board)
    return nil if !['hs', 'sr'].include?(board) || fraction == 1
    board == 'hs' ? score_hs - fraction : score_sr + fraction
  end

  # Calculate the interpolated fractional frame using Sim's tool
  def seed_fraction
    # Map or demo not available, cannot compute
    if !highscoreable || !demo&.demo
      update(fraction: 1)
      return :lost
    end

    frac = NSim.run(highscoreable.dump_level, [demo.demo]){ |nsim| nsim.frac }
    update(fraction: frac || 1, simulated: true)
    return frac ? :good : :bad
  rescue => e
    lex(e, "Fraction computation failed for mappack score #{id}")
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
