# This file contains the generic Map module, that encapsulates a lot of the
# properties of an N++ map (map data parsing and formatting, screenshot,
# trace and animation generation, etc). Three classes implement this module:
# Level, Userlevel, and MappackLevel.

#require 'chunky_png'
require 'oily_png'    # C wrapper for ChunkyPNG
require 'gifenc'      # Own gem to encode and decode GIFs
require 'matplotlib/pyplot'
require 'zlib'

module Map
  # pref - Drawing preference (for overlaps): lower = more to the front
  # att  - Number of object attributes in the old format
  # old  - ID in the old format, '-1' if it didn't exist
  # pal  - Index at which the colors of the object start in the palette image
  OBJECTS = {
    0x00 => { name: 'ninja',              pref:  4, att: 2, old:  0, pal:  6 },
    0x01 => { name: 'mine',               pref: 22, att: 2, old:  1, pal: 10 },
    0x02 => { name: 'gold',               pref: 21, att: 2, old:  2, pal: 14 },
    0x03 => { name: 'exit',               pref: 25, att: 4, old:  3, pal: 17 },
    0x04 => { name: 'exit switch',        pref: 20, att: 0, old: -1, pal: 25 },
    0x05 => { name: 'regular door',       pref: 19, att: 3, old:  4, pal: 30 },
    0x06 => { name: 'locked door',        pref: 28, att: 5, old:  5, pal: 31 },
    0x07 => { name: 'locked door switch', pref: 27, att: 0, old: -1, pal: 33 },
    0x08 => { name: 'trap door',          pref: 29, att: 5, old:  6, pal: 39 },
    0x09 => { name: 'trap door switch',   pref: 26, att: 0, old: -1, pal: 41 },
    0x0A => { name: 'launch pad',         pref: 18, att: 3, old:  7, pal: 47 },
    0x0B => { name: 'one-way platform',   pref: 24, att: 3, old:  8, pal: 49 },
    0x0C => { name: 'chaingun drone',     pref: 16, att: 4, old:  9, pal: 51 },
    0x0D => { name: 'laser drone',        pref: 17, att: 4, old: 10, pal: 53 },
    0x0E => { name: 'zap drone',          pref: 15, att: 4, old: 11, pal: 57 },
    0x0F => { name: 'chase drone',        pref: 14, att: 4, old: 12, pal: 59 },
    0x10 => { name: 'floor guard',        pref: 13, att: 2, old: 13, pal: 61 },
    0x11 => { name: 'bounce block',       pref:  3, att: 2, old: 14, pal: 63 },
    0x12 => { name: 'rocket',             pref:  8, att: 2, old: 15, pal: 65 },
    0x13 => { name: 'gauss turret',       pref:  9, att: 2, old: 16, pal: 69 },
    0x14 => { name: 'thwump',             pref:  6, att: 3, old: 17, pal: 74 },
    0x15 => { name: 'toggle mine',        pref: 23, att: 2, old: 18, pal: 12 },
    0x16 => { name: 'evil ninja',         pref:  5, att: 2, old: 19, pal: 77 },
    0x17 => { name: 'laser turret',       pref:  7, att: 4, old: 20, pal: 79 },
    0x18 => { name: 'boost pad',          pref:  1, att: 2, old: 21, pal: 81 },
    0x19 => { name: 'deathball',          pref: 10, att: 2, old: 22, pal: 83 },
    0x1A => { name: 'micro drone',        pref: 12, att: 4, old: 23, pal: 57 },
    0x1B => { name: 'alt deathball',      pref: 11, att: 2, old: 24, pal: 86 },
    0x1C => { name: 'shove thwump',       pref:  2, att: 2, old: 25, pal: 88 }
  }
  # Objects that do not admit rotations
  FIXED_OBJECTS = [0, 1, 2, 3, 4, 7, 9, 16, 17, 18, 19, 21, 22, 24, 25, 28]
  # Objects that admit diagonal rotations
  SPECIAL_OBJECTS = [10, 11, 23]
  # Objects that have a different "toggled" sprite
  TOGGLABLE_OBJECTS = [1, 3, 4, 6, 7, 8, 9]
  THEMES = [
    "acid",           "airline",         "argon",         "autumn",
    "BASIC",          "berry",           "birthday cake", "bloodmoon",
    "blueprint",      "bordeaux",        "brink",         "cacao",
    "champagne",      "chemical",        "chococherry",   "classic",
    "clean",          "concrete",        "console",       "cowboy",
    "dagobah",        "debugger",        "delicate",      "desert world",
    "disassembly",    "dorado",          "dusk",          "elephant",
    "epaper",         "epaper invert",   "evening",       "F7200",
    "florist",        "formal",          "galactic",      "gatecrasher",
    "gothmode",       "grapefrukt",      "grappa",        "gunmetal",
    "hazard",         "heirloom",        "holosphere",    "hope",
    "hot",            "hyperspace",      "ice world",     "incorporated",
    "infographic",    "invert",          "jaune",         "juicy",
    "kicks",          "lab",             "lava world",    "lemonade",
    "lichen",         "lightcycle",      "line",          "m",
    "machine",        "metoro",          "midnight",      "minus",
    "mir",            "mono",            "moonbase",      "mustard",
    "mute",           "nemk",            "neptune",       "neutrality",
    "noctis",         "oceanographer",   "okinami",       "orbit",
    "pale",           "papier",          "papier invert", "party",
    "petal",          "PICO-8",          "pinku",         "plus",
    "porphyrous",     "poseidon",        "powder",        "pulse",
    "pumpkin",        "QDUST",           "quench",        "regal",
    "replicant",      "retro",           "rust",          "sakura",
    "shift",          "shock",           "simulator",     "sinister",
    "solarized dark", "solarized light", "starfighter",   "sunset",
    "supernavy",      "synergy",         "talisman",      "toothpaste",
    "toxin",          "TR-808",          "tycho",         "vasquez",
    "vectrex",        "vintage",         "virtual",       "vivid",
    "void",           "waka",            "witchy",        "wizard",
    "wyvern",         "xenon",           "yeti"
  ]
  # Challenge: Figure out what the following constant encodes ;)
  BORDERS = "100FF87E1781E0FC3F03C0FC3F03C0FC3F03C078370388FC7F87C0EC1E01C1FE3F13E"
  DEFAULT_PALETTE = "vasquez"
  PALETTE = ChunkyPNG::Image.from_file(PATH_PALETTES)
  ROWS    = 23
  COLUMNS = 42
  UNITS   = 24               # Game units per tile
  DIM     = 44               # Pixels per tile at 1080p
  PPC     = 11               # Pixels per coordinate (1/4th tile)
  PPU     = DIM.to_f / UNITS # Pixels per unit
  WIDTH   = DIM * (COLUMNS + 2)
  HEIGHT  = DIM * (ROWS + 2)

  # TODO: Perhaps store object data without transposing, hence being able to skip
  #       the decoding when dumping
  # TODO: Or better yet, store the entire map data in a single field, Zlibbed, for
  #       instantaneous dumps
  def self.encode_tiles(data)
    Zlib::Deflate.deflate(data.map{ |a| a.pack('C*') }.join, 9)
  end

  def self.encode_objects(data)
    Zlib::Deflate.deflate(data.transpose.map{ |a| a.pack('C*') }.join, 9)
  end

  def self.decode_tiles(data)
    Zlib::Inflate.inflate(data).bytes.each_slice(42).to_a
  end

  def self.decode_objects(data)
    dec = Zlib::Inflate.inflate(data)
    dec.bytes.each_slice((dec.size / 5).round).to_a.transpose
  end

  # Parse a level in Metanet format
  # This format is only used internally by the game for the campaign levels,
  # and differs from the standard userlevel format
  def self.parse_metanet_map(data, index = nil, file = nil, pack = nil)
    name =  ''
    name += " #{index}"     if !index.nil?
    name += " from #{file}" if !file.nil?
    name += " for #{pack}"  if !pack.nil?
    error = "Failed to parse map#{name}"
    warning = "Abnormality found parsing map#{name}"

    # Ensure format is "$map_name#map_data#", with map data being hex chars
    if data !~ /^\$(.*)\#(\h+)\#$/
      err("#{error}: Incorrect overall format.")
      return
    end
    title, map_data = $1, $2
    size = map_data.length

    # Map data is dumped binary, so length must be even, and long enough to hold
    # header and tile data
    if size % 2 == 1 || size / 2 < 4 + 23 * 42 + 2 * 26 + 4
      err("#{error}: Incorrect map data length (odd length, or too short).")
      return
    end

    # Map header missing
    if !map_data[0...8] == '00000000'
      err("#{error}: Header missing.")
      return
    end

    # Parse tiles. Warning if invalid ones are found
    tiles = [map_data[8...1940]].pack('h*').bytes
    invalid_count = tiles.count{ |t| t > 33 }
    if invalid_count > 0
      warn("#{warning}: #{invalid_count} invalid tiles.")
    end
    tiles = tiles.each_slice(42).to_a

    # Parse objects
    offset = 1940
    objects = []
    gold = 0
    OBJECTS.reject{ |id, o| o[:old] == -1 }.sort_by{ |id, o| o[:old] }.each{ |id, type|
      # Parse object count
      if size < offset + 4
        err("#{error}: Object count for ID #{id} not found.")
        return
      end
      count = map_data[offset...offset + 4].scan(/../m).map(&:reverse).join.to_i(16)
      gold = count if id == 2

      # Parse entities of this type
      if size < offset + 4 + 2 * count * type[:att]
        err("#{error}: Object data incomplete for ID #{id}.")
        return
      end
      map_data[offset + 4...offset + 4 + 2 * count * type[:att]].scan(/.{#{2 * type[:att]}}/m).each{ |o|
        atts = [o].pack('h*').bytes
        if ![3, 6, 8].include?(id)
          objects << [id] + atts.ljust(4, 0)
        else # Doors need special handling
          objects << [id] + atts[0..-3].ljust(4, 0) # Door
          objects << [id + 1] + atts[-2..-1].ljust(4, 0) # Door switch
        end
      }
      offset += 4 + 2 * count * type[:att]
    }

    # Sort objects by ID, but:
    #   1) In a stable way, i.e., maintaining the order of tied elements
    #   2) The pairs 6/7 and 8/9 are not sorted, but maintained staggered
    # Both are important to respect N++'s data format
    objects = objects.stable_sort_by{ |o| o[0] == 7 ? 6 : o[0] == 9 ? 8 : o[0] }

    # Warnings if footer is incorrect
    if size != offset + 8
      warn("#{warning}: Incorrect footer length.")
    elsif map_data[offset..-1] != '00000000'
      warn("#{warning}: Incorrect footer format.")
    end

    # Return map elements
    { title: title, tiles: tiles, objects: objects, gold: gold }
  end

  # Parse a text file containing maps in Metanet format, one per line
  # This is the format used by the game to store the main campaign of levels
  def self.parse_metanet_file(file, limit, pack)
    fn = File.basename(file)
    if !File.file?(file)
      err("File '#{fn}' not found parsing Metanet file")
      return
    end

    maps = File.binread(file).split("\n").take(limit)
    count = maps.count
    maps = maps.each_with_index.map{ |m, i|
      dbg("Parsing map #{"%-3d" % (i + 1)} / #{count} from #{fn} for #{pack}...", progress: true)
      parse_metanet_map(m.strip, i, fn, pack)
    }
    Log.clear
    maps
  rescue => e
    lex(e, "Error parsing Metanet map file #{fn} for #{pack}")
    nil
  end

  def self.object_counts(objects)
    object_counts = [0] * 40
    objects.each{ |o| object_counts[o[0]] += 1 if o[0] < 40 }
    object_counts
  end

  # Return tiles as a matrix of integer
  def tiles(version: nil)
    Map.decode_tiles(tile_data(version: version))
  end

  # Return objects as an array of 5-tuples of ints
  def objects(version: nil)
    Map.decode_objects(object_data(version: version))
  end

  # Return object counts
  def object_counts(version: nil)
    Map.object_counts(objects(version: version))
  end

  # Shortcuts for some object counts
  def gold(version: nil)
    object_counts(version: version)[2]
  end

  def mines(version: nil)
    object_counts(version: version)[1]
  end

  # This is used for computing the hash of a level. It's required due to a
  # misimplementation in N++, which instead of just hashing the map data,
  # overflows and copies object data from the next levels before doing so.
  #   Returns false if we ran out of objects, or true if we completed the data
  # successfully. Userlevels aren't completed (their hashes aren't checked
  # by the server anyways).
  #  Params:
  # - data: Current object data
  # - n:    Count of remaining objects needed to complete data
  def complete_object_data(data, n)
    return true if n == 0 || self.is_a?(Userlevel)
    successor = next_h(tab: false)
    return false if successor == self
    objs = successor.objects.take(n).map{ |o| o.pack('C5') }
    count = objs.count
    data << objs.join
    return true if count == n
    successor.complete_object_data(data, n - count)
  end

  # Generate a file with the usual userlevel format
  #   - query:   The format for userlevel query files is used (shorter header)
  #   - hash:    Recursively fetches object data from next level to compute hash later
  #   - version: Version of the map (for mappacks we may hold multiple edits)
  def dump_level(query: false, hash: false, version: nil)
    # HEADER
    header = ""
    objs = self.objects(version: version)
    if !query
      header << _pack(0, 4)                    # Magic number
      header << _pack(1230 + 5 * objs.size, 4) # Filesize
    end
    mode = self.is_a?(MappackLevel) ? self.mode : Userlevel.modes[self.mode]
    author_id = query ? self.author_id : -1
    title = self.is_a?(MappackLevel) ? self.longname : self.title
    title = to_ascii(title.to_s)[0...127].ljust(128, "\x00")
    header << _pack(-1, 'l<')        # Level ID (unset)
    header << _pack(mode, 4)         # Game mode
    header << _pack(37, 4)           # QT (unset, max is 36)
    header << _pack(author_id, 'l<') # Author ID
    header << _pack(0, 4)            # Fav count (unset)
    header << _pack(0, 10)           # Date SystemTime (unset)
    header << title                  # Title
    header << _pack(0, 16)           # Author name (unset)
    header << _pack(0, 2)            # Padding

    # MAP DATA
    tile_data = Zlib::Inflate.inflate(tile_data(version: version))
    object_counts = Map.object_counts(objs)
    object_counts[7] = 0 unless hash
    object_counts[9] = 0 unless hash
    object_data = objs.map{ |o| o.pack('C5') }.join
    return nil if hash && !complete_object_data(object_data, object_counts[6] + object_counts[8])
    object_counts = object_counts.pack('S<*')

    (header + tile_data + object_counts + object_data).force_encoding("ascii-8bit")
  end

  # Computes the level's hash, which the game uses for integrity verifications
  #   c   - Use the C SHA1 implementation (vs. the default Ruby one)
  #   v   - Map version to hash
  #   pre - Serve precomputed hash stored in BadHash table
  def _hash(c: false, v: nil, pre: false)
    stored = l.hashes.where(v ? "`version` <= #{v}" : '').order(:version).last rescue nil
    return stored if pre && stored
    map_data = dump_level(hash: true, version: v)
    return nil if map_data.nil?
    sha1(PWD + map_data[0xB8..-1], c: c)
  end

  # <-------------------------------------------------------------------------->
  #                           SCREENSHOT GENERATOR
  # <-------------------------------------------------------------------------->

  # Change color 'before' to color 'after' in 'image'.
  # The normal version uses tolerance to change close enough colors, alpha blending...
  # The fast version doesn't do any of this, but is 10x faster
  def self.mask(image, before, after, bg: ChunkyPNG::Color::WHITE, tolerance: 0.5, fast: false)
    if fast
      image.pixels.map!{ |p| p == before ? after : 0 }
      return image
    end

    new_image = ChunkyPNG::Image.new(image.width, image.height, ChunkyPNG::Color::TRANSPARENT)
    image.width.times{ |x|
      image.height.times{ |y|
        distance = ChunkyPNG::Color.euclidean_distance_rgba(image[x, y], before)
        score = distance.to_f / ChunkyPNG::Color::MAX_EUCLIDEAN_DISTANCE_RGBA
        new_image[x, y] = ChunkyPNG::Color.compose(after, bg) if score < tolerance
      }
    }
    new_image
  end

  # Generate the image of an object in the specified palette, by painting and combining each layer.
  # Note: "special" indicates that we take the special version of the layers. In practice,
  # this is used because we can't rotate images 45 degrees with this library, so we have a
  # different image for that, which we call special. Some sprites have 2 versions, a toggled
  # and an untoggled one.
  def self.generate_object(object_id, palette_id, object = true, special = false, toggled = false)
    # Select necessary layers
    path = object ? PATH_OBJECTS : PATH_TILES
    parts = Dir.entries(path).select{ |file|
      bool1 = file[0..1] == object_id.to_s(16).upcase.rjust(2, "0") # Select only sprites for this object
      bool2 = file[-5] == 't' # Select only toggled/untoggled sprites
      bool1 && (!toggled ^ bool2)
    }.sort
    parts_normal = parts.select{ |file| file[2] == "-" }
    parts_special = parts.select{ |file| file[2] == "s" }
    parts = (!special ? parts_normal : (parts_special.empty? ? parts_normal : parts_special))

    # Paint and combine the layers
    masks = parts.map{ |part| [part[toggled ? -6 : -5], ChunkyPNG::Image.from_file(File.join(path, part))] }
    images = masks.map{ |mask| mask(mask[1], ChunkyPNG::Color::BLACK, PALETTE[(object ? OBJECTS[object_id][:pal] : 0) + mask[0].to_i, palette_id], fast: true) }
    dims = [ images.map{ |i| i.width }.max || 1, images.map{ |i| i.height }.max || 1]
    output = ChunkyPNG::Image.new(*dims, ChunkyPNG::Color::TRANSPARENT)
    images.each{ |image| output.compose!(image, 0, 0) }
    output
  rescue => e
    lex(e, "Failed to generate sprite for object #{object_id}.")
    ChunkyPNG::Image.new(1, 1, ChunkyPNG::Color::TRANSPARENT)
  end

  # Given a bounding box (rectangle) in game units, return the range of grid
  # cells intersected by it. The rectangle is given in the form [X, Y, W, H],
  # where [X, Y] are the coordinates of the upper left corner (not the center),
  # and [W, H] are the width and height, respectively.
  #
  # The neighbouring cells may also be optionally included.
  # If the bbox only has 2 components (X and Y), then a single point is checked.
  def self.gather_cells(bbox, neighbours = false)
    bbox << 0 << 0 if bbox.size == 2
    pad = neighbours ? 1 : 0
    x_min = [(bbox[0] / UNITS).floor - pad, 0].max
    y_min = [(bbox[1] / UNITS).floor - pad, 0].max
    x_max = [((bbox[0] + bbox[2]) / UNITS).floor + pad, COLUMNS + 1].min
    y_max = [((bbox[1] + bbox[3]) / UNITS).floor + pad, ROWS    + 1].min
    [x_min, y_min, x_max, y_max]
  end

  # Gather a list of all the objects that intersect a given rectangle and its
  # neighbouring cells. The list is sorted by drawing preference.
  # Notes:
  # - We are ignoring out of bounds objects (frame is included though).
  def self.gather_objects(objects, bbox)
    x_min, y_min, x_max, y_max = gather_cells(bbox, true)
    objs = []
    (x_min .. x_max).each{ |x|
      (y_min .. y_max).each{ |y|
        objs.push(*objects[x][y])
      }
    }
    objs
  end

  # Determine the scale of the screenshot based on the highscoreable type and
  # whether it's an animation or not
  def self.find_scale(h, anim)
    return ANIMATION_SCALE if anim

    case h
    when Episodish
      SCREENSHOT_SCALE_EPISODE
    when Storyish
      SCREENSHOT_SCALE_STORY
    else
      SCREENSHOT_SCALE_LEVEL
    end
  end

  # Find all touched objects in a given frame range by any ninja, and logically
  # collide with them, by either removing or toggling them.
  def self.collide_vs_objects(objects, objs, f, step, ppc)
    # For every frame in the range, find collided objects by any ninja, by matching
    # the log returned by ntrace with the object dictionary
    collided_objects = []
    (0 ... step).each{ |s|
      next unless objs.key?(f + s)
      objs[f + s].each{ |obj|
        # Only include a select few collisions
        next unless [1, 2, 4, 7, 9, 21].include?(obj[0])

        # Gather objects matching the collided one
        x = (obj[1] / 4).floor
        y = (obj[2] / 4).floor
        objects[x][y].each{ |o|
          collided_objects << o if obj[0, 3] == o[0, 3] && o[4] == 0
        }
      }
    }
    collided_objects.uniq!

    # Collide object, by either removing it from object dictionary (so that it
    # won't get rendered again) or toggling it (so the sprite will change in
    # the next redrawing).
    collided_objects.each{ |o|
      list = objects[o[1] / 4][o[2] / 4]

      # Remove or toggle object
      o[0] == 2 ? list.delete(o) : o[4] = 1

      # For switches, toggle / remove door too
      if [4, 7, 9].include?(o[0])
        other_list = objects[o[6] / 4][o[7] / 4]
        door = other_list.find{ |d| d[0] == o[0] - 1 && d[5] == o[5] }
        if door
          o[0] == 7 ? other_list.delete(door) : door[4] = 1
          collided_objects << door
        else
          warn("Door for collided switch not found.")
        end
      end
    }

    collided_objects
  end

  # Parse map(s) data, sanitize it, and return objects and tiles conveniently
  # organized for screenshot generation.
  def self.parse_maps(maps, v = 1)
    # Read objects, remove glitch ones
    objects = maps.map{ |map|
      map.map.objects(version: v).reject{ |o| o[0] > 28 }
    }

    # Perform some additional convenience modifications and sanity checks
    objects.each{ |map|
      map.each{ |o|
        # Remove glitched orientations and non-zero orientations for still objects
        o[3] = 0 if o[3] > 7 || FIXED_OBJECTS.include?(o[0])

        # Use 5th field as "toggled" marker, all objects start untoggled
        o[4] = 0

        # Convert toggle mines and mines to the same object
        o[4] = 1 if o[0] == 1
        o[0] = 1 if o[0] == 21
      }

      # Link each door-switch pair within the object data
      [[3, 4], [6, 7], [8, 9]].each{ |door_id, switch_id|
        door_index = 0
        doors      = map.select{ |o| o[0] == door_id   }
        switches   = map.select{ |o| o[0] == switch_id }
        warn("Unpaired doors/switches found when parsing map data.") if doors.size != switches.size
        switches.each_with_index{ |switch, i|
          break if !doors[i]
          switch << door_index << doors[i][1] << doors[i][2]
          doors[i] << door_index
          door_index += 1
        }
      }
    }

    # Build an object dictionary keyed on row and column, for fast access, akin
    # to GridEntity
    object_dicts = maps.map{
      (COLUMNS + 2).times.map{ |t|
        [t, (ROWS + 2).times.map{ |s| [s, []] }.to_h]
      }.to_h
    }

    objects.each_with_index{ |map, i|
      map.each{ |o|
        x = o[1] / 4
        y = o[2] / 4
        next if x < 0 || x > COLUMNS + 1 || y < 0 || y > ROWS + 1
        object_dicts[i][x][y] << o
      }
    }

    # Parse tiles, add frame, and reject glitch tiles
    tiles = maps.map{ |map|
      tile_list = map.map.tiles(version: v).map(&:dup)
      tile_list.each{ |row| row.unshift(1).push(1) }                   # Add vertical frame
      tile_list.unshift([1] * (COLUMNS + 2)).push([1] * (COLUMNS + 2)) # Add horizontal frame
      tile_list.each{ |row| row.map!{ |t| t > 33 ? 0 : t } }           # Reject glitch tiles
      tile_list
    }

    [object_dicts, tiles]
  end

  # Parse all elements we'll need to screenshot and trace / animate the routes
  def self.parse_trace(nsim, texts, h, ppc: PPC, v: nil)
    # Filter parameters
    n = [nsim.map(&:count).max || 0, MAX_TRACES].min
    names = texts.take(n).map{ |t| t[/\d+:(.*)-/, 1].strip }
    scores = texts.take(n).map{ |t| t[/\d+:(.*)-(.*)/, 2].strip }

    # Parse map data
    maps = h.is_level? ? [h] : h.levels
    objects, tiles = parse_maps(maps, v)

    # Return full context as a hash for easy management
    {
      h:       h,
      n:       n,
      tiles:   tiles,
      objects: objects,
      nsim:    nsim,
      names:   names,
      scores:  scores
    }
  end

  # Create an initial PNG image with the right dimensions and color to hold a screenshot
  def self.init_png(palette_idx, ppc, h)
    cols = h.is_level? ? 1 : 5
    rows = h.is_story? ? 5 : 1
    dim = 4 * ppc
    width = dim * (COLUMNS + 2)
    height = dim * (ROWS + 2)
    full_width = cols * width  + (cols - 1) * dim + (!h.is_level? ? 2 : 0) * dim
    full_height = rows * height + (rows - 1) * dim + (!h.is_level? ? 2 : 0) * dim
    ChunkyPNG::Image.new(full_width, full_height, PALETTE[2, palette_idx])
  end

  # Initialize the object sprites with the given palette and scale
  def self.init_objects(objects, palette_idx, ppc = PPC)
    scale = ppc.to_f / PPC
    atlas = {}
    objects.each{ |map|
      map.each{ |col, hash|
        hash.each{ |row, objs|
          objs.each{ |o|
            # Skip if this object doesn't exist
            next if o[0] >= 29
            atlas[o[0]] = {} if !atlas.key?(o[0])

            (TOGGLABLE_OBJECTS.include?(o[0]) ? [0, 1] : [0]).each{ |state|
              # Skip if this object is already initialized
              atlas[o[0]][state] = {} if !atlas[o[0]].key?(state)
              next if atlas[o[0]][state].key?(o[3])
              sprite_list = atlas[o[0]][state]

              # Initialize base object image
              s = o[3] % 2 == 1 && SPECIAL_OBJECTS.include?(o[0]) # Special variant of sprite (diagonal)
              base = s ? 1 : 0
              if !sprite_list.key?(base)
                sprite_list[base] = generate_object(o[0], palette_idx, true, s, state == 1)
                sprite_list[base].resample_nearest_neighbor!(
                  [(scale * sprite_list[base].width).round, 1].max,
                  [(scale * sprite_list[base].height).round, 1].max,
                ) if ppc != PPC
              end
              next if o[3] <= 1

              # Initialize rotated copies
              case o[3] / 2
              when 1
                sprite_list[o[3]] = sprite_list[base].rotate_right
              when 2
                sprite_list[o[3]] = sprite_list[base].rotate_180
              when 3
                sprite_list[o[3]] = sprite_list[base].rotate_left
              end
            }
          }
        }
      }
    }
    atlas
  end

  # Initialize the tile sprites with the given palette and scale
  def self.init_tiles(tiles, palette_idx, ppc = PPC)
    scale = ppc.to_f / PPC
    atlas = {}
    tiles.each{ |map|
      map.each{ |row|
        row.each{ |t|
          # Skip if this tile is already initialized
          next if atlas.key?(t) || t <= 1 || t >= 34

          # Initialize base tile image
          o = (t - 2) % 4                # Orientation
          base = t - o                   # Base shape
          if !atlas.key?(base)
            atlas[base] = generate_object(base, palette_idx, false)
            atlas[base].resample_nearest_neighbor!(
              (scale * atlas[base].width).round,
              (scale * atlas[base].height).round,
            ) if ppc != PPC
          end
          next if base == t

          # Initialize rotated / flipped copies
          if t >= 2 && t <= 17           # Half tiles and curved slopes
            case o
            when 1
              atlas[t] = atlas[base].rotate_right
            when 2
              atlas[t] = atlas[base].rotate_180
            when 3
              atlas[t] = atlas[base].rotate_left
            end
          elsif t >= 18 && t <= 33       # Small and big straight slopes
            case o
            when 1
              atlas[t] = atlas[base].flip_vertically
            when 2
              atlas[t] = atlas[base].flip_horizontally.flip_vertically
            when 3
              atlas[t] = atlas[base].flip_horizontally
            end
          end
        }
      }
    }
    atlas
  end

  # Convert the PNG sprites to GIF format for animations
  def self.convert_atlases(context_png, context_gif)
    # Tile atlas
    context_gif[:tile_atlas] ||= context_png[:tile_atlas].map{ |id, png|
      png.pixels.map!{ |c| c == 0 ? TRANSPARENT_COLOR : c }
      [id, png2gif(png, context_gif[:palette], TRANSPARENT_COLOR, TRANSPARENT_COLOR)]
    }.to_h

    # Object atlas
    context_gif[:object_atlas] ||= context_png[:object_atlas].map{ |id, states|
      [
        id,
        states.map{ |state, sprites|
          [
            state,
            sprites.map{ |o, png|
              png.pixels.map!{ |c| c == 0 ? TRANSPARENT_COLOR : c }
              [o, png2gif(png, context_gif[:palette], TRANSPARENT_COLOR, TRANSPARENT_COLOR)]
            }.to_h
          ]
        }.to_h
      ]
    }.to_h
  end

  # Render a list of objects onto a base image, optionally only updating a
  # given bounding box (for redraws in animations). Implemented for both PNGs
  # and GIFs.
  def self.render_objects(objects, image, ppc: PPC, atlas: {}, bbox: nil, frame: true)
    # Prepare scale params
    dim = 4 * ppc
    width = dim * (COLUMNS + 2)
    height = dim * (ROWS + 2)
    bbox = [0, 0, UNITS * (COLUMNS + 2), UNITS * (ROWS + 2)] if !bbox
    dest_bbox = bbox.map{ |c| (c * PPU * ppc / PPC).round }
    gif = Gifenc::Image === image

    # Draw objects
    off_x = frame ? dim : 0
    off_y = frame ? dim : 0
    objects.each_with_index do |map, i|
      # Compose images, only for those objects intersecting the bbox
      # We ignore duplicates, and sort by drawing overlap preference
      gather_objects(map, bbox).uniq.sort_by{ |o| -OBJECTS[o[0]][:pref] }.each do |o|
        # Skip objects we don't have in the atlas
        obj = atlas[o[0]][o[4]][o[3]] rescue nil
        next if !obj

        # Draw differently depending on whether we have a PNG or a GIF
        x = off_x + ppc * o[1] - obj.width / 2
        y = off_y + ppc * o[2] - obj.height / 2
        if !gif
          image.compose!(obj, x, y) rescue nil
        else
          image.copy(src: obj, dest: [x, y], trans: true, bbox: dest_bbox) rescue nil
        end
      end

      # Adjust offsets
      off_x += width + dim
      if i % 5 == 4
        off_x = frame ? dim : 0
        off_y += height + dim
      end
    end
  end

  # Render a list of tiles onto a base image, optionally only updating a
  # given bounding box (for redraws in animations). Implemented for both PNGs
  # and GIFs.
  def self.render_tiles(tiles, image, ppc: PPC, atlas: {}, bbox: nil, frame: true, palette: nil, palette_idx: 0)
    # Prepare scale params
    dim = 4 * ppc
    width = dim * (COLUMNS + 2)
    height = dim * (ROWS + 2)
    color = PALETTE[0, palette_idx]
    gif = Gifenc::Image === image
    color = palette[color >> 8] if gif
    bbox = [0, 0, UNITS * (COLUMNS + 2), UNITS * (ROWS + 2)] if !bbox
    dest_bbox = bbox.map{ |c| (c * PPU * ppc / PPC).round }
    x_min, y_min, x_max, y_max = gather_cells(bbox, false)

    # Draw tiles within the given cell range
    off_x = frame ? dim : 0
    off_y = frame ? dim : 0
    tiles.each_with_index do |map, i|
      (y_min .. y_max).each do |row|
        (x_min .. x_max).each do |column|
          t = map[row][column]

          # Empty and full tiles are handled separately
          next if t == 0
          if t == 1
            x = off_x + dim * column
            y = off_y + dim * row
            if !gif
              image.fast_rect(x, y, x + dim - 1, y + dim - 1, nil, color)
            else
              image.rect(x, y, dim, dim, nil, color, bbox: dest_bbox)
            end
            next
          end

          # Compose all other tiles
          next if !atlas.key?(t)
          x = off_x + dim * column
          y = off_y + dim * row
          if !gif
            image.compose!(atlas[t], x, y) rescue nil
          else
            image.copy(src: atlas[t], dest: [x, y], trans: true, bbox: dest_bbox) rescue nil
          end
        end
      end

      # Adjust offsets
      off_x += width + dim
      if i % 5 == 4
        off_x = frame ? dim : 0
        off_y += height + dim
      end
    end
  end

  # Render a list of tile borders onto a base image, optionally only updating a
  # given bounding box (for redraws in animations). Implemented for both PNGs
  # and GIFs.
  def self.render_borders(tiles, image, palette: nil, palette_idx: 0, ppc: PPC, frame: true, bbox: nil)
    # Prepare scale and color params
    dim = 4 * ppc
    width = dim * (COLUMNS + 2)
    height = dim * (ROWS + 2)
    thin = ppc <= 6 ? 0 : 1
    color = PALETTE[1, palette_idx]
    gif = Gifenc::Image === image
    color = palette[color >> 8] if gif
    bbox = [0, 0, UNITS * (COLUMNS + 2), UNITS * (ROWS + 2)] if !bbox
    dest_bbox = bbox.map{ |c| (c * PPU * ppc / PPC).round }
    x_min, y_min, x_max, y_max = gather_cells(bbox, true)

    # Parse borders and color
    borders = BORDERS.to_i(16).to_s(2)[1..-1].chars.map(&:to_i).each_slice(8).to_a

    # Draw borders
    off_x = frame ? dim : 0
    off_y = frame ? dim : 0
    tiles.each_with_index do |m, i|
      #                  Frame surrounding entire level
      if frame && !gif
        image.fast_rect(
          off_x, off_y, off_x + width - 1, off_y + height - 1, color, nil
        )
        image.fast_rect(
          off_x + 1, off_y + 1, off_x + width - 2, off_y + height - 2, color, nil
        )
      end

      #                  Horizontal borders
      (y_min ... y_max).each do |row|
        (2 * x_min ... 2 * (x_max + 1)).each do |col|
          tile_a = m[row][col / 2]
          tile_b = m[row + 1][col / 2]
          next unless (col % 2 == 0 ? (borders[tile_a][3] + borders[tile_b][6]) % 2 : (borders[tile_a][2] + borders[tile_b][7]) % 2) == 1
          x = off_x + dim / 2 * col - thin
          y = off_y + dim * (row + 1) - thin
          w = dim / 2 + 2 * thin
          h = thin + 1
          if !gif
            image.fast_rect(x, y, x + w - 1, y + h - 1, nil, color)
          else
            image.rect(x, y, w, h, nil, color, bbox: dest_bbox)
          end
        end
      end

      #                  Vertical borders
      (2 * y_min ... 2 * (y_max + 1)).each do |row|
        (x_min ... x_max).each do |col|
          tile_a = m[row / 2][col]
          tile_b = m[row / 2][col + 1]
          next unless (row % 2 == 0 ? (borders[tile_a][0] + borders[tile_b][5]) % 2 : (borders[tile_a][1] + borders[tile_b][4]) % 2) == 1
          x = off_x + dim * (col + 1) - thin
          y = off_y + dim / 2 * row - thin
          w = thin + 1
          h = dim / 2 + 2 * thin
          if !gif
            image.fast_rect(x, y, x + w - 1, y + h - 1, nil, color)
          else
            image.rect(x, y, w, h, nil, color, bbox: dest_bbox)
          end
        end
      end

      # Adjust offsets
      off_x += width + dim
      if i % 5 == 4
        off_x = frame ? dim : 0
        off_y += height + dim
      end
    end
  end

  # Redraw only a rectangular region of the screenshot. This is used for updating
  # the background during animations, so that we can have some features, such as
  # gold collecting or toggles toggling. Redrawing must be done in the same order
  # as usual (bg -> objects -> tiles -> borders -> traces), and restricted to the
  # box, otherwise we could mess other parts up.
  def self.redraw_bbox(image, bbox, objects, tiles, object_atlas, tile_atlas, palette, palette_idx = 0, ppc = PPC, frame = true)
    pixel_bbox = bbox.map{ |c| (c * PPU * ppc / PPC).round }
    image.rect(*pixel_bbox, nil, palette[PALETTE[2, palette_idx] >> 8])
    render_objects(objects, image, ppc: ppc, atlas: object_atlas, bbox: bbox, frame: frame)
    render_tiles(tiles, image, ppc: ppc, atlas: tile_atlas, bbox: bbox, frame: frame, palette: palette, palette_idx: palette_idx)
    render_borders(tiles, image, palette: palette, palette_idx: palette_idx, bbox: bbox, ppc: ppc, frame: frame)
  end

  # Given a list of objects that have changed on this frame (collected gold,
  # toggled mines, etc), redraw each of their corresponding bounding boxes onto
  # the background.
  def self.redraw_changes(image, changes, objects, tiles, object_atlas, tile_atlas, palette, palette_idx = 0, ppc = PPC, frame = true)
    changes.each{ |o|
      # Skip objects we don't have in the atlas
      next if !object_atlas.key?(o[0])

      # Find max size of sprites corresponding to this object and orientation
      width = object_atlas[o[0]].map{ |_, list| list[o[3]].width rescue nil }.compact.max
      height = object_atlas[o[0]].map{ |_, list| list[o[3]].height rescue nil }.compact.max
      next if !width || !height

      # Redraw bounding box
      x = ppc * o[1] - width / 2
      y = ppc * o[2] - height / 2
      bbox = [x, y, width, height].map{ |c| c * PPC / ppc.to_f / PPU }
      redraw_bbox(image, bbox, objects, tiles, object_atlas, tile_atlas, palette, palette_idx, ppc, frame)
    }
  end

  # Render the timbars with names and scores on top of animated GIFs
  def self.render_timebars(image, update, colors, gif: nil, info: nil)
    dim = 4 * gif[:ppc]
    n = info[:names].length

    n.times.each{ |i|
      # Only render timebar if it has changed. In practice, this only happens
      # twice: at the start, and when the ninja finishes.
      j = n - 1 - i
      next unless update[j]

      # Compute coordinates relative to the image (which need not fill the screen)
      dx = (COLUMNS - 2) * dim / 4.0
      pos_x = (dim * 1.25 + i * (dim / 2.0 + dx)).round
      pos_y = 1
      p = Gifenc::Geometry::Point.parse([pos_x, pos_y])
      p = Gifenc::Geometry.transform([p], image.bbox)[0]

      # Rectangle
      image.rect(p.x, p.y, dx.round, dim, colors[:fg][j], colors[:bg][j], weight: 2, anchor: 0)

      # Vertical bar
      image.line(
        p1: [p.x + dx - dim / 2 - strlen(info[:scores][j], gif[:font]), p.y],
        p2: [p.x + dx - dim / 2 - strlen(info[:scores][j], gif[:font]), p.y + dim - 1],
        color: colors[:fg][j]
      ) if colors[:fg][j]

      # Name
      txt2gif(
        info[:names][j],
        image,
        gif[:font],
        p.x + dim / 4,
        p.y + dim - 1 - 2 - 3,
        colors[:text][j],
        max_width: (dx - dim - strlen(info[:scores][j], gif[:font])).round
      ) if colors[:text][j]

      # Score
      txt2gif(
        info[:scores][j],
        image,
        gif[:font],
        p.x + dx - dim / 4,
        p.y + dim - 1 - 2 - 3,
        colors[:text][j],
        align: :right
      ) if colors[:text][j]
    }
  end

  # Find the bounding box of a specific ninja marker. The marker is the circle
  # that represents the ninja in an animation, and also includes the wedges for
  # the input display.
  def self.find_marker_bbox(coords, demos, ninja, frame, step)
    # Marker coords
    f = [frame + step - 1, coords[ninja].size - 1].min
    x, y = coords[ninja][f]
    j, r, l = 0, 0, 0

    # Extend bbox with input display, if available
    if demos && demos[ninja] && f > 0 && (input = demos[ninja][f - 1])
      h = ANIMATION_WEDGE_HEIGHT - 1
      s = ANIMATION_WEDGE_SEP
      t = ANIMATION_WEDGE_WEIGHT
      add = h + s + (t + 1) / 2
      j = add     if input[0]
      r = add + 1 if input[1] # For some reason, it's not centered horizontally
      l = add     if input[2]
    end

    # Compute required points, center will also be useful
    rad = ANIMATION_RADIUS
    {
      points: [[x - rad - l, y - rad - j], [x + rad + r, y + rad]],
      center: [x, y],
      input:  input
    }
  end

  # Determine whether the ninja finished the run exactly on this GIF frame
  def self.ninja_just_finished?(coords, f, step, trace)
    coords.size.between?(f + 1 + (trace ? 1 : 0), f + step + (trace ? 1 : 0))
  end

  # Determine whether the ninja has already finished by this GIF frame
  def self.ninja_finished?(coords, f, trace)
    coords.size < f + 1 + (trace ? 1 : 0)
  end

  # For a given frame, find the minimum region (bounding box) of the image that
  # needs to be redrawn. This region must contain all points that are subject to
  # change on this frame (trace bits, ninja markers, collected objects,
  # timebars, input display...), and must be rectangular.
  def self.find_frame_bbox(f, coords, step, markers, demos, objects, atlas, trace: false, ppc: PPC)
    dim = 4 * ppc
    endpoints = []

    coords.each_with_index{ |c_list, i|
      next if ninja_finished?(c_list, f, trace)
      if trace # Trace chunks
        _step = [step, c_list.size - (f + 1)].min
        (0 .. _step).each{ |s|
          endpoints << [c_list[f + s][0], c_list[f + s][1]]
        }
      else     # Ninja markers and input display
        endpoints.push(*find_marker_bbox(coords, demos, i, f, step)[:points])
      end

      # Timebars
      if ninja_just_finished?(c_list, f, step, trace)
        j = coords.length - 1 - i
        dx = (COLUMNS - 2) * dim / 4.0
        x = (dim * 1.25 + j * (dim / 2.0 + dx)).round
        endpoints << [x, 1]
        endpoints << [x + dx.round - 1, dim]
      end
    }

    # Collected objects
    objects.each{ |o|
      # Skip objects we don't have in the atlas
      next if !atlas.key?(o[0])

      # Find max size of sprites corresponding to this object and orientation
      width = atlas[o[0]].map{ |_, list| list[o[3]].width rescue nil }.compact.max
      height = atlas[o[0]].map{ |_, list| list[o[3]].height rescue nil }.compact.max
      next if !width || !height

      # Get bounding box of sprites
      x = ppc * o[1] - width / 2
      y = ppc * o[2] - height / 2
      endpoints << [x, y]
      endpoints << [x + width - 1, y + height - 1]
    } if objects

    # Also add points from the previous frame's markers (to erase them)
    endpoints.push(*markers.flatten(1))

    # Nothing to plot, animation has finished
    return if endpoints.empty?

    # Construct minimum bounding box containing all points
    Gifenc::Geometry.bbox(endpoints, 1)
  end

  # Redraw the background over the last frame to erase or change the
  # elements that have been updated
  def self.restore_background(image, background, markers, objects, atlas, ppc = PPC)
    bbox = image.bbox

    # Remove ninja markers and input display from previous frame
    markers.each{ |p1, p2|
      image.copy(
        src:    background,
        offset: p1,
        dim:    [p2[0] - p1[0] + 1, p2[1] - p1[1] + 1],
        dest:   Gifenc::Geometry.transform([p1], bbox)[0]
      )
    }

    # Update changed elements (collected gold, toggled mines, ...)
    objects.each{ |o|
      # Skip objects we don't have in the atlas
      next if !atlas.key?(o[0])

      # Find max size of sprites corresponding to this object and orientation
      width = atlas[o[0]].map{ |_, list| list[o[3]].width rescue nil }.compact.max
      height = atlas[o[0]].map{ |_, list| list[o[3]].height rescue nil }.compact.max
      next if !width || !height

      # Copy background region
      x = ppc * o[1] - width / 2
      y = ppc * o[2] - height / 2
      image.copy(
        src:    background,
        offset: [x, y],
        dim:    [width, height],
        dest:   Gifenc::Geometry.transform([[x, y]], bbox)[0]
      )
    }
  end

  # Draw a single frame of an animated GIF. We have two modes:
  # - Tracing the routes by plotting the lines.
  # - Animating the ninjas by drawing moving circles.
  def self.draw_frame_gif(image, coords, demos, f, step, trace, colors)
    bbox = image.bbox

    # Trace route bits for this frame _range_
    if trace
      colors = colors.reverse
      (0 ... step).each{ |s|
        coords.reverse.each_with_index{ |c_list, i|
          next if ninja_finished?(c_list, f + s, trace)
          p1 = [c_list[f + s][0], c_list[f + s][1]]
          p2 = [c_list[f + s + 1][0], c_list[f + s + 1][1]]
          p1, p2 = Gifenc::Geometry.transform([p1, p2], bbox)
          image.line(p1: p1, p2: p2, color: colors[i], weight: 2)
        }
      }
      return []
    end

    # Render ninja markers for this _single_ frame
    rad = ANIMATION_RADIUS
    e1 = Gifenc::Geometry::E1
    e2 = Gifenc::Geometry::E2
    markers = []
    coords.each_with_index{ |c_list, i|
      next if ninja_finished?(c_list, f, trace)

      # Save bbox to clear marker next frame
      marker_bbox = find_marker_bbox(coords, demos, i, f, step)
      markers << marker_bbox[:points]

      # Draw marker
      p = Gifenc::Geometry.transform([marker_bbox[:center]], bbox)[0]
      image.circle(p, rad, nil, colors[i])

      # Draw input display (inputs are offset by 1 frame)
      next if !(input = marker_bbox[:input])
      w = ANIMATION_WEDGE_WIDTH
      h = ANIMATION_WEDGE_HEIGHT - 1
      s = ANIMATION_WEDGE_SEP
      t = ANIMATION_WEDGE_WEIGHT
      image.polygonal([p - e2 * (rad + s)     - e1 * w, p - e2 * (rad + s + h),     p - e2 * (rad + s)     + e1 * w], line_color: colors[i], line_weight: t) if input[0] == 1 # Jump
      image.polygonal([p + e1 * (rad + s + 1) - e2 * w, p + e1 * (rad + s + h + 1), p + e1 * (rad + s + 1) + e2 * w], line_color: colors[i], line_weight: t) if input[1] == 1 # Right
      image.polygonal([p - e1 * (rad + s)     - e2 * w, p - e1 * (rad + s + h),     p - e1 * (rad + s)     + e2 * w], line_color: colors[i], line_weight: t) if input[2] == 1 # Left
    }

    markers
  end

  # Draw a single frame and export to PNG. They will later be joined into an
  # MP4 using FFmpeg.
  def self.draw_frame_vid(image, coords, f, colors)
    coords.each_with_index{ |c_list, i|
      image.line(
        c_list[f][0],
        c_list[f][1],
        c_list[f + 1][0],
        c_list[f + 1][1],
        colors[i],
        false,
        weight: 2,
        antialiasing: false
      ) if coords[i].size >= f + 2
    }
    image.save("frames/#{'%04d' % f}.png", :fast_rgb)
    #`ffmpeg -framerate 60 -pattern_type glob -i 'frames/*.png' 'frames/anim.mp4' > /dev/null 2>&1`
    #res = File.binread('frames/anim.mp4')
    #FileUtils.rm(Dir.glob('frames/*'))
  end

  # Render a PNG screenshot of a highscoreable
  def self.render_screenshot(info, palette_idx, ppc, i: nil)
    # Prepare highscoreable and map data
    h = info[:h]
    h = h.levels[i] if i
    tiles   = i ? [info[:tiles][i]]   : info[:tiles]
    objects = i ? [info[:objects][i]] : info[:objects]

    # Initialize image and sprites
    image = init_png(palette_idx, ppc, h)
    tile_atlas = init_tiles(tiles, palette_idx, ppc)
    object_atlas = init_objects(objects, palette_idx, ppc)

    # Compose image
    unless info[:blank]
      frame = !h.is_level?
      render_objects(objects, image, ppc: ppc, frame: frame, atlas: object_atlas)
      render_tiles(  tiles  , image, ppc: ppc, frame: frame, palette_idx: palette_idx, atlas: tile_atlas)
      render_borders(tiles  , image, ppc: ppc, frame: frame, palette_idx: palette_idx)
    end

    # Return the whole context
    {
      image:        image,
      tile_atlas:   tile_atlas,
      object_atlas: object_atlas,
      palette_idx:  palette_idx,
      ppc:          ppc
    }
  end

  # Build a Global Color Table (a GIF palette) containing all colors from a given
  # N++ palette. This is no problem, since a GIF palette can hold 256 colors,
  # which is more than an N++ palette.
  def self.init_gct(palette_idx)
    # Include all of the palette's colors
    palette = PALETTE.row(palette_idx).map{ |c| c >> 8 }
    table = Gifenc::ColorTable.new(palette.uniq)

    # Add the inverted ninja colors, and a rare color to use for transparency
    inverted = palette[OBJECTS[0][:pal], 4].map{ |c| c ^ 0xFFFFFF }
    table.add(*inverted)
    table.add(TRANSPARENT_COLOR >> 8)

    # Remove duplicates and empty slots from table
    table.simplify
  end

  # Initialize the GIF object and its associated palette
  def self.init_gif(png, info, filename, anim, delay)
    # Initialize GIF palette
    gct = init_gct(png[:palette_idx])
    palette = gct.colors.compact.each_with_index.to_h
    ninja_colors = info[:n].times.map{ |i|
      PALETTE[OBJECTS[0][:pal] + info[:n] - 1 - i, png[:palette_idx]]
    }

    # Initialize GIF
    gif = Gifenc::Gif.new(png[:image].width, png[:image].height, gct: gct)
    if anim
      gif.loops = -1
      gif.open(filename)
    end

    # Build full context
    {
      gif:          gif,
      palette:      palette,
      delay:        delay,
      font:         parse_bmfont(FONT_TIMEBAR),
      colors: {
        ninja:      ninja_colors.map{ |c| palette[c >> 8] },
        inv:        ninja_colors.map{ |c| palette[(c >> 8) ^ 0xFFFFFF] },
        trans:      palette[TRANSPARENT_COLOR >> 8]
      },
      palette_idx:  png[:palette_idx],
      ppc:          png[:ppc]
    }
  end

  # Render the full initial background of the GIF
  def self.render_gif(png, gif, info, anim: false, blank: false)
    gif[:background].destroy if gif[:background]

    # Convert PNG screenshot to GIF with specified palette
    bg_color = PALETTE[2, png[:palette_idx]]
    background = png2gif(png[:image], gif[:palette], bg_color)

    # Add timebars and legend
    colors = {
      fg:   gif[:colors][:ninja],
      bg:   [gif[:palette][bg_color >> 8]] * info[:n],
      text: gif[:colors][:ninja]
    }
    render_timebars(background, [true] * info[:n], colors, gif: gif, info: info) unless blank || !anim && !info[:h].is_level?

    # No trace -> Write first frame to disk
    if anim
      gif[:background] = background
      gif[:gif].add(background)
      return
    end

    # Trace -> Draw whole trace and return encoded (static) GIF
    dim = 4 * gif[:ppc]
    off_x = !info[:h].is_level? ? dim : 0
    off_y = off_x
    info[:coords].each{ |level|
      level.each_with_index{ |c_list, i|
        (0 ... c_list.size - 1).each{ |f|
          p1 = [off_x + c_list[f][0],     off_y + c_list[f][1]    ]
          p2 = [off_x + c_list[f + 1][0], off_y + c_list[f + 1][1]]
          background.line(p1: p1, p2: p2, color: gif[:colors][:ninja][i], weight: info[:h].is_level? ? 2 : 1)
        }
      }
      off_x += dim * (COLUMNS + 3)
    }
    gif[:gif].images << background
    gif[:gif].write
  end

  # Render one frame of an animation, by redrawing the parts of the background
  # that have changed (due to e.g. collecting objects), erasing the ninja
  # markers from the previous frame, and drawing the elements for the new frame.
  # This involves first finding the smallest bounding box containing all the
  # elements that must be redrawn, to minimize the redrawn area. Returns nil
  # when there's nothing else to redraw, meaning the run has finished.
  def self.render_frame(f, step, gif, info, i, markers)
    # Find collected gold
    collided = !info[:trace] ? collide_vs_objects(info[:objects][i], info[:collisions][i], f, step, gif[:ppc]) : []

    # Find bounding box for this frame
    bbox = find_frame_bbox(f, info[:coords][i], step, markers, info[:demos][i], collided, gif[:object_atlas], trace: info[:trace], ppc: gif[:ppc])
    return if !bbox
    done = info[:coords][i].map{ |c_list|
      next false if !info[:h].is_level? && i < 4
      ninja_just_finished?(c_list, f, step, info[:trace])
    }

    # Write previous frame to disk and create new frame
    image = Gifenc::Image.new(
      bbox:        bbox,
      color:       gif[:palette][TRANSPARENT_COLOR >> 8],
      delay:       gif[:delay],
      trans_color: gif[:palette][TRANSPARENT_COLOR >> 8]
    )

    # Redraw background regions to erase markers from previous frame and
    # change any objects that have been collected / toggled this frame.
    if !info[:trace]
      redraw_changes(gif[:background], collided, [info[:objects][i]], [info[:tiles][i]], gif[:object_atlas], gif[:tile_atlas], gif[:palette], gif[:palette_idx], gif[:ppc], false) unless info[:blank]
      restore_background(image, gif[:background], markers, collided, gif[:object_atlas], gif[:ppc])
    end

    # Draw new elements for this frame (trace, markers, inputs...), and save
    # markers to we can delete them on the next frame
    markers.pop(markers.size)
    markers.push(*draw_frame_gif(image, info[:coords][i], info[:demos][i], f, step, info[:trace], gif[:colors][:ninja]))

    # Other elements
    colors = {
      fg:   [nil] * info[:n],
      bg:   gif[:colors][:ninja],
      text: gif[:colors][:inv]
    }
    render_timebars(image, done, colors, gif: gif, info: info) unless info[:blank]

    image
  end

  # Animate all frames in the GIF, return last frame
  def self.animate_gif(gif, info, i, step, memory, last)
    sizes = info[:coords][i].map(&:size)
    frames = sizes.max
    markers = []
    image = nil
    (0 .. frames + step).step(step) do |f|
      dbg("Generating frame #{'%4d' % [f + 1]} / #{frames - 1}", newline: false) if BENCH_IMAGES
      frame = render_frame(f, step, gif, info, i, markers)
      memory << getmem if BENCH_IMAGES
      GC.start if ANIM_GC && (f / step + 1) % ANIM_GC_STEP == 0
      break if !frame
      gif[:gif].add(image) if image
      image = frame
    end

    if image
      image.delay = last ? ANIMATION_EXHIBIT : ANIMATION_EXHIBIT_INTER
      gif[:gif].add(image)
    end
  end

  # Convert a PNG image from ChunkyPNG to a GIF from Gifenc
  # This assumes we've already created a palette holding all the PNG's colors.
  def self.png2gif(png, palette, bg, trans = nil)
    # Create GIF frame with same dimensions and the specified background color
    bg = palette[bg >> 8]
    gif = Gifenc::Image.new(png.width, png.height, color: bg)
    gif.trans_color = palette[trans >> 8] if trans

    # Transform color values to color indices in the palette
    gif.replace(png.pixels.map{ |c| palette[c >> 8] || bg }.pack('C*'))

    gif
  end

  # Generate a PNG screenshot of a level in the chosen palette.
  # Optionally, plot / animate routes and export to GIF. There are 2 modes:
  #   - Trace mode will plot the routes as lines. Can be static or dynamic.
  #   - Animation mode will draw moving circles as the ninjas.
  #
  # Note: This function is forked to a new process to immediately free up all
  # the used memory.
  def self.screenshot(
      theme =     DEFAULT_PALETTE,        # Palette to generate screenshot in
      nsim:       [],                     # NSim objects (simulation results)
      file:       false,                  # Whether to export to a file or return the raw data
      inputs:     false,                  # Add input display to animation
      blank:      false,                  # Only draw background
      h:          nil,                    # Highscoreable to screenshot
      anim:       false,                  # Whether to animate plotted coords or not
      trace:      false,                  # Whether the animation should be a trace or a moving object
      step:       ANIMATION_STEP_NORMAL,  # How many frames per frame to trace
      delay:      ANIMATION_DELAY_NORMAL, # Time between frames, in 1/100ths sec
      texts:      [],                     # Texts for the legend
      spoiler:    false,                  # Whether the screenshot should be spoilered in Discord
      v:          nil                     # Version of the map data to use (nil = latest)
    )

    return nil if h.nil?
    bench(:start) if BENCHMARK

    anim = false if !FEATURE_ANIMATE
    gif = !nsim.empty?
    filename =  "#{spoiler ? 'SPOILER_' : ''}#{sanitize_filename(h.name)}.#{gif ? 'gif' : 'png'}"
    memory = [] if BENCH_IMAGES
    $time = 0

    res = _fork do
      if BENCH_IMAGES
        bench(:start)
        memory << getmem
      end

      # Parse palette and scale
      themes = THEMES.map(&:downcase)
      palette_idx = themes.index(theme.downcase) || themes.index(DEFAULT_PALETTE.downcase)
      ppc = find_scale(h, anim)

      # We will encapsulate all necessary info in a few context hashes, for easy management
      context_png  = nil
      context_gif  = nil
      context_info = parse_trace(nsim, texts, h, ppc: ppc, v: v).merge(inputs: inputs, trace: trace, blank: blank)
      res = nil

      # Render each highscoreable
      multi = h.is_episode? && gif && anim
      h_list = multi ? h.levels : [h]
      h_list.each_with_index{ |h, i|
        # Generate PNG screenshot
        context_png = render_screenshot(context_info, palette_idx, ppc, i: multi ? i : nil)
        if BENCH_IMAGES
          bench(:step, 'Screenshot', pad_str: 12, pad_num: 9)
          memory << getmem
        end

        # No routes to trace -> Done
        if !gif
          res = context_png[:image].to_blob(:fast_rgb)
          bench(:step, 'Blobify', pad_str: 12, pad_num: 9) if BENCH_IMAGES
          break
        end

        # Routes to trace -> Convert to GIF
        context_gif = init_gif(context_png, context_info, filename, anim, delay) if !context_gif
        res = render_gif(context_png, context_gif, context_info, anim: anim, blank: blank)
        convert_atlases(context_png, context_gif) if anim
        if BENCH_IMAGES
          bench(:step, 'GIF init', pad_str: 12, pad_num: 9)
          memory << getmem if BENCH_IMAGES
        end

        # No animation -> Done
        break if !anim

        # Animation -> Render frames
        animate_gif(context_gif, context_info, i, step, memory, i == h_list.size - 1)
        bench(:step, 'Routes', pad_str: 12, pad_num: 9) if BENCH_IMAGES
      }

      # If animated GIF, close file
      if gif && anim
        context_gif[:gif].close
        res = File.binread(filename)
        FileUtils.rm([filename])
      end

      # Finish benchmark
      if BENCH_IMAGES
        dbg('Image size: ' + res.size.to_s)
        mem_per_frame = memory.size > 3 ? (memory[3..-1].max - memory[3..-1].min) / (memory.size - 3) : 0.0
        dbg("Memory: max #{'%.3f' % memory.max}, avg #{'%.3f' % [memory.sum / memory.size]}, per frame #{'%.3f' % mem_per_frame}")
        dbg("Time: %.3fms" % [$time * 1000])
      end

      # Return binary data for PNG / GIF
      res
    end

    bench(:step) if BENCHMARK

    return nil if !res
    file ? tmp_file(res, filename, binary: true) : res
  rescue => e
    lex(e, "Failed to generate screenshot")
    nil
  end

  def screenshot(theme, **kwargs)
    Map.screenshot(theme, h: self, **kwargs)
  end

  # Plot routes and legend on top of an image (typically a screenshot)
  # [Depends on Matplotlib using Pycall, a Python wrapper]
  #
  # Note: This function is forked to a new process to immediately free up all
  # the used memory.
  def self.mpl_trace(
      theme:   DEFAULT_PALETTE, # Palette to generate screenshot in
      bg:      nil,             # Background image (screenshot) file object
      animate: false,           # Animate trace instead of still image
      nsim:    nil,              # NSim objects (simulation results)
      texts:   [],              # Names for the legend
      markers: { jump: true, left: false, right: false} # Mark changes in replays
    )
    return if !nsim

    _fork do
      # Parse palette
      bench(:start) if BENCH_IMAGES
      themes = THEMES.map(&:downcase)
      theme = theme.to_s.downcase
      theme = DEFAULT_PALETTE.downcase if !themes.include?(theme)
      palette_idx = themes.index(theme)

      # Setup parameters and Matplotlib
      n = [nsim.count, MAX_TRACES].min
      texts = texts.take(n)
      colors = n.times.map{ |i| ChunkyPNG::Color.to_hex(PALETTE[OBJECTS[0][:pal] + i, palette_idx]) }
      Matplotlib.use('agg')
      mpl = Matplotlib::Pyplot
      mpl.ioff

      # Prepare custom font (Sys)
      font = "#{DIR_UTILS}/sys.ttf"
      fm = PyCall.import_module('matplotlib.font_manager')
      fm.fontManager.addfont(font)
      mpl.rcParams['font.family'] = 'sans-serif'
      mpl.rcParams['font.sans-serif'] = fm.FontProperties.new(fname: font).get_name
      bench(:step, 'Trace setup', pad_str: 11) if BENCH_IMAGES

      # Configure axis
      dx = (COLUMNS + 2) * UNITS
      dy = (ROWS + 2) * UNITS
      mpl.axis([0, dx, dy, 0])
      mpl.axis('off')
      ax = mpl.gca
      ax.set_aspect('equal', adjustable: 'box')

      # Load background image (screenshot)
      img = mpl.imread(bg)
      ax.imshow(img, extent: [0, dx, dy, 0])
      bench(:step, 'Trace image', pad_str: 11) if BENCH_IMAGES

      # Plot inputs
      n.times.each{ |i|
        break if markers.values.count(true) == 0
        last_coord = nil
        i = n - 1 - i
        nsim.length.times.each{ |j|
          f = nsim.inputs(i, j)
          next if !f

          if !nsim.ninja(i, j)
            mpl.plot(last_coord[0], last_coord[1], color: colors[i], marker: 'x', markersize: 2) if last_coord
            break
          else
            last_coord = nsim.ninja(i, j)
          end

          if markers[:jump] && f[0] == 1 && (j == 0 || nsim.inputs(i, j - 1)[0] == 0)
            mpl.plot(last_coord[0], last_coord[1], color: colors[i], marker: '.', markersize: 1)
          end
          if markers[:right] && f[1] == 1 && (j == 0 || nsim.inputs(i, j - 1)[1] == 0)
            mpl.plot(last_coord[0], last_coord[1], color: colors[i], marker: '>', markersize: 1)
          end
          if markers[:left] && f[2] == 1 && (j == 0 || nsim.inputs(i, j - 1)[2] == 0)
            mpl.plot(last_coord[0], last_coord[1], color: colors[i], marker: '<', markersize: 1)
          end
        }
      }
      bench(:step, 'Trace input', pad_str: 11) if BENCH_IMAGES

      # Plot legend
      n.times.each{ |i|
        break if texts[i].nil?
        name, score = texts[i].match(/(.*)-(.*)/).captures.map(&:strip)
        dx = UNITS * COLUMNS / 4.0
        ddx = UNITS / 2
        bx = UNITS / 4
        c = 8
        m = dx / 2.9
        dm = 4
        x, y = UNITS + dx * i, UNITS - 5
        vert_x = [x + bx, x + bx, x + bx + c, x + dx - m - dm, x + dx - m, x + dx - m + dm, x + dx - bx - c, x + dx - bx, x + dx - bx]
        vert_y = [2, UNITS - c - 2, UNITS - 2, UNITS - 2, UNITS - dm - 2, UNITS - 2, UNITS - 2, UNITS - c - 2, 2]
        color_bg = ChunkyPNG::Color.to_hex(PALETTE[2, palette_idx])
        color_bd = colors[i]
        mpl.fill(vert_x, vert_y, facecolor: color_bg, edgecolor: color_bd, linewidth: 0.5)
        mpl.text(x + ddx, y, name, ha: 'left', va: 'baseline', color: colors[i], size: 'x-small')
        mpl.text(x + dx - ddx, y, score, ha: 'right', va: 'baseline', color: colors[i], size: 'x-small')
      }
      bench(:step, 'Trace texts', pad_str: 11) if BENCH_IMAGES

      # Plot traces
      n.times.each{ |i|
        mpl.plot(
          nsim.coords_raw[0][n - 1 - i].map(&:first),
          nsim.coords_raw[0][n - 1 - i].map(&:last),
          colors[n - 1 - i],
          linewidth: 0.5
        )
      }
      bench(:step, 'Trace plot', pad_str: 11) if BENCH_IMAGES

      # Save result
      fn = tmp_filename("#{name}_aux.png")
      mpl.savefig(fn, bbox_inches: 'tight', pad_inches: 0, dpi: 390, pil_kwargs: { compress_level: 1 })
      image = File.binread(fn)
      bench(:step, 'Trace save', pad_str: 11) if BENCH_IMAGES

      # Perform cleanup
      mpl.cla
      mpl.clf
      mpl.close('all')

      # Return
      image
    end
  rescue
    nil
  end

  def self.trace(event, anim: false, h: nil)
    # Parse message parameters
    TmpMsg.init(event)
    t = Time.now
    h = parse_highscoreable(event, mappack: true) if !h
    perror("Failed to parse highscoreable.") if !h
    perror("Columns can't be traced.") if h.is_story?
    perror("This trace is disabled, figure it out yourself!") if h.is_protected?
    msg = parse_message(event)
    hash = parse_palette(event)
    msg, palette, error = hash[:msg], hash[:palette], hash[:error]
    h = h.vanilla if h.is_mappack? && h.mappack.id == 0
    perror("Error finding Metanet board.") if !h
    userlevel = h.is_a?(Userlevel)
    board = parse_board(msg, 'hs')
    perror("Non-highscore modes (e.g. speedrun) are only available for mappacks.") if !h.is_mappack? && board != 'hs'
    perror("Traces are only available for either highscore or speedrun mode.") if !['hs', 'sr'].include?(board)
    if userlevel
      TmpMsg.update("Updating scores and downloading replays...")
      h.update_scores(fast: true)
    end
    leaderboard = h.leaderboard(board, pluck: false)
    ranks = parse_ranks(msg, leaderboard.size).take(MAX_TRACES)
    scores = ranks.map{ |r| leaderboard[r] }.compact
    perror("No scores found in this board.") if scores.empty?
    blank = !!msg[/\bblank\b/i]
    markers = { jump: false, left: false, right: false } if !!msg[/\bplain\b/i]
    markers = { jump: true,  left: true,  right: true  } if !!msg[/\binputs\b/i]
    markers = { jump: true,  left: false, right: false } if markers.nil?
    if !!msg[/very\s+slow/i]
      delay = ANIMATION_DELAY_VSLOW
    elsif !!msg[/slow/i]
      delay = ANIMATION_DELAY_SLOW
    else
      delay = ANIMATION_DELAY_NORMAL
    end
    if !!msg[/very\s+fast/i]
      step = ANIMATION_STEP_VFAST
    elsif !!msg[/fast/i]
      step = ANIMATION_STEP_FAST
    else
      step = ANIMATION_STEP_NORMAL
    end
    debug = !!msg[/\bdebug\b/i] && check_permission(event, 'ntracer')
    gif = anim || !h.is_level?

    # Prepare demos
    demos = scores.map{ |score|
      if userlevel
        [Demo.encode(score.demo)]
      else
        Demo.decode(score.demo.demo, true).map{ |d| Demo.encode(d) }
      end
    }.transpose

    # Execute simulation and parse result
    TmpMsg.update('Running simulation...')
    levels = h.is_level? ? [h] : h.levels
    res = levels.each_with_index.map{ |l, i| NSim.new(l.map.dump_level, demos[i]) }
    res.each{ |nsim|
      nsim.run
      bench(:step, 'Simulation', pad_str: 12, pad_num: 9) if BENCH_IMAGES
    }

    # Check simulation success
    all_success = res.all?(&:success)
    all_correct = res.all?(&:correct)
    all_valid   = res.all?(&:valid)
    if !all_success || !all_correct
      if !all_success
        str = "Simulation failed, contact the botmaster for details. "
      else
        str = "Failed to parse simulation result, contact the botmaster for details. "
      end
      res.each{ |l| str << l.debug(event) } if debug
      perror(str)
    end

    # Prepare output message
    names = scores.map{ |s| s.player.print_name }
    valids = res.map{ |l| l.valid_flags }.transpose.map{ |s| s.all?(true) }
    wrong_names = names.each_with_index.select{ |_, i| !valids[i] }.map(&:first)
    event << error.strip if !error.empty?
    header = "Replay #{format_board(board)} #{'trace'.pluralize(names.count)}"
    header << " for #{names.to_sentence}"
    header << " in #{userlevel ? "userlevel #{verbatim(h.name)} by #{verbatim(h.author.name)}" : h.name}"
    header << " using palette #{verbatim(palette)}:"
    event << header
    texts = h.format_scores(np: gif ? 0 : 11, mode: board, ranks: ranks, join: false, cools: false, stars: false)
    if !all_valid
      warning = "(**Warning**: #{'Trace'.pluralize(wrong_names.count)}"
      warning << " for #{wrong_names.to_sentence}"
      warning << " #{wrong_names.count == 1 ? 'is' : 'are'} likely incorrect)."
      event << warning
    end

    # Render trace or animation
    TmpMsg.update('Generating screenshot...')
    if gif
      trace = screenshot(
        palette,
        h:      h,
        trace:  !!msg[/trace/i],
        nsim:   res,
        texts:  texts,
        anim:   anim,
        blank:  blank,
        inputs: ANIMATION_DEFAULT_INPUT || !!msg[/\binputs?\b/i],
        step:   step,
        delay:  delay
      )
      perror('Failed to generate screenshot') if trace.nil?
    else
      screenshot = h.map.screenshot(palette, file: true, blank: blank)
      perror('Failed to generate screenshot') if screenshot.nil?
      TmpMsg.update('Plotting routes...')
      $trace_context = {
        theme:   palette,
        bg:      screenshot,
        nsim:    res.first,
        markers: markers,
        texts:   !blank ? texts : []
      }
      trace = QueuedCmd.new(:trace).enqueue
      screenshot.close
      perror('Failed to trace replays') if trace.nil?
    end

    # Send image file
    ext = gif ? 'gif' : 'png'
    send_file(event, trace, "#{sanitize_filename(name)}_#{ranks.map(&:to_s).join('-')}_trace.#{ext}", true)

    # Output debug info
    event << res.map{ |l| l.debug(event) }.join("\n\n") if debug
    dbg("FINAL: #{"%8.3f" % [1000 * (Time.now - t)]}") if BENCH_IMAGES
  rescue => e
    lex(e, 'Failed to trace replays', event: event)
  end

  # Tests whether ntrace is working with this level or not
  def test_ntrace(ranks: [0], board: 'hs')
    leaderboard = vanilla.leaderboard(board, pluck: false)
    scores = ranks.map{ |r| leaderboard[r] }.compact
    return :other if scores.empty?
    demos = scores.map{ |s| s.demo.demo }
    return :other if demos.count(nil) > 0

    res = ntrace(dump_level, demos, silent: true)
    return :error if !res[:success]
    return res[:valid].count(false) == 0 ? :good : :bad
  rescue => e
    lex(e, 'ntrace testing failed')
    nil
  end
end
