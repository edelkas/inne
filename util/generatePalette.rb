# This was used to generate the palette image
# It's not a complete TGA parser, just the bare minimum required

$boot_time = Time.now

require 'chunky_png'
require 'rbconfig'
require 'stringio'

# TGA properties
TGA_HEADER_SIZE = 18
TGA_HEADER_FORMAT = 'C3S<2CS<4C2'
TGAHeader = Struct.new(
  :id_length, :colormap_type, :image_type, # (3 bytes)
  :cm_origin, :cm_length, :cm_depth, # Color map specification (5 bytes)
  :origin_x, :origin_y, :width, :height, :depth, :desc # Image specification (10 bytes)
)

FILE_NAMES = [
  # Main map colors used for screenshots
  "background",        "ninja",                "entityMine",           "entityGold",
  "entityDoorExit",    "entityDoorExitSwitch", "entityDoorRegular",    "entityDoorLocked",
  "entityDoorTrap",    "entityLaunchPad",      "entityOneWayPlatform", "entityDroneChaingun",
  "entityDroneLaser",  "entityDroneZap",       "entityDroneChaser",    "entityFloorGuard",
  "entityBounceBlock", "entityRocket",         "entityTurret",         "entityThwomp",
  "entityEvilNinja",   "entityDualLaser",      "entityBoostPad",       "entityBat",
  "entityEyeBat",      "entityShoveThwomp",

  # Colors for other parts of the gameplay
  "headbands",         "explosions",           "timeBar",              "timeBarRace",
  "fxNinja",           "fxDroneZap",           "fxFloorguardZap",

  # Interface colors
  "menu",              "editor"
]

# The 129 official palette names. The order of the first 123 is important, they
# are baked in the game's files and this can be regarded as their ID, useful
# for indexing into the nprofile. The last 6 are the TEN++ ones, they were added
# as regular custom palettes so their index is irrelevant. The first 62 come from
# Pre-UE, and the next 61 from UE, thus why each half is alphabetically sorted.
PALETTE_NAMES = [
  'BASIC',           'F7200',       'acid',          'airline',
  'birthday cake',   'blueprint',   'bordeaux',      'chemical',
  'chococherry',     'classic',     'clean',         'console',
  'disassembly',     'dorado',      'dusk',          'epaper',
  'epaper invert',   'evening',     'galactic',      'gothmode',
  'holosphere',      'hot',         'infographic',   'invert',
  'kicks',           'lightcycle',  'm',             'metoro',
  'midnight',        'minus',       'mir',           'mono',
  'moonbase',        'neptune',     'oceanographer', 'okinami',
  'orbit',           'pale',        'papier',        'papier invert',
  'party',           'pinku',       'plus',          'poseidon',
  'pulse',           'quench',      'replicant',     'retro',
  'shift',           'shock',       'simulator',     'solarized dark',
  'solarized light', 'supernavy',   'toxin',         'vasquez',
  'virtual',         'vivid',       'wizard',        'yeti',
  'pumpkin',         'witchy',      'argon',         'autumn',
  'berry',           'bloodmoon',   'brink',         'cacao',
  'champagne',       'concrete',    'cowboy',        'dagobah',
  'debugger',        'delicate',    'desert world',  'elephant',
  'florist',         'formal',      'gatecrasher',   'grapefrukt',
  'grappa',          'gunmetal',    'hazard',        'heirloom',
  'hope',            'hyperspace',  'ice world',     'incorporated',
  'jaune',           'juicy',       'lab',           'lava world',
  'lemonade',        'lichen',      'line',          'machine',
  'mustard',         'mute',        'nemk',          'neutrality',
  'noctis',          'petal',       'PICO-8',        'porphyrous',
  'QDUST',           'regal',       'rust',          'sakura',
  'sinister',        'starfighter', 'sunset',        'synergy',
  'talisman',        'toothpaste',  'TR-808',        'tycho',
  'vectrex',         'vintage',     'void',          'waka',
  'wyvern',          'xenon',       'powder',        'anniversary',
  'burple',          'classy',      'SNKRX',         'ten',
  'tropical'
]

# Find palette directory
PATHS = {
  'windows' => "C:/Program Files (x86)/Steam/steamapps/common/N++/NPP/Palettes",
  'linux'   => "#{Dir.home}/.steam/steam/steamapps/common/N++/NPP/Palettes"
}
SYS = RbConfig::CONFIG['host_os'] =~ /linux/i ? 'linux' : 'windows'
DIR = PATHS[SYS]

# For the final name export
COLUMNS = 4

def log(str, ln = true) = print "\e[2K\r[%.3f] %s%s" % [Time.now - $boot_time, str, ln ? "\n" : '']

# Parse palettes and count total colors to define output image
log "Generating palette image..."
current = Dir.entries(DIR).to_set
missing = PALETTE_NAMES.select{ |palette| !current.include?(palette) }
abort("Missing palettes: #{missing.join(', ')}") if missing.size > 0
colors = FILE_NAMES.inject(0){ |total, name|
  file = File.binread("#{DIR}/#{PALETTE_NAMES.first}/#{name}.tga")
  total + file[12, 2].unpack('S<')[0] / 64
}
output = ChunkyPNG::Image.new(colors, PALETTE_NAMES.size + 1, ChunkyPNG::Color::WHITE)
log "Palettes found: #{PALETTE_NAMES.size}"
log "Colors found: #{colors}"

# Parse all colors and fill output image
count = PALETTE_NAMES.count
PALETTE_NAMES.each_with_index{ |palette, y|
  log "Parsing palette [#{y + 1} / #{count}] #{palette}", false
  x = -1

  FILE_NAMES.each{ |name|
    file = File.open("#{DIR}/#{palette}/#{name}.tga", 'rb')

    # Parse TGA properties
    tga = TGAHeader.new(*file.read(TGA_HEADER_SIZE).unpack(TGA_HEADER_FORMAT))
    total_pixels = tga.width * tga.height
    colors, pixel_size = tga.width / 64, tga.depth / 8
    flip_x, flip_y, interlace = tga.desc[4] == 1, tga.desc[5] == 0, tga.desc[6, 2]

    # Sanity checks
    abort("Only RGB images are supported.")        if ![2, 10].include?(tga.image_type)
    abort("Color-mapped images not supported.")    if tga.colormap_type != 0
    abort("Interlaced images not supported.")      if interlace > 0
    abort("Pixel depth isn't a multiple of 8.")    if tga.depth % 8 != 0
    abort("Pixel depth cannot hold true color.")   if tga.depth < 24
    abort("Colormap depth isn't a multiple of 8.") if tga.cm_depth % 8 != 0

    # Read pixel data
    file.seek(tga.id_length + tga.cm_length * tga.cm_depth / 8, IO::SEEK_CUR)
    pixel_data = file.read(total_pixels * pixel_size)
    file.close

    # Decode RLE
    if tga.image_type == 10
      buffer = StringIO.new(pixel_data)
      pixels = ''.b
      pixel_count = 0
      loop do
        header_byte = buffer.read(1)
        break unless header_byte
        packet_header = header_byte.unpack1('C')
        packet_size = (packet_header & 0x7F) + 1
        if (packet_header & 0x80) == 0   # Raw packet
          pixels << buffer.read(packet_size * pixel_size)
        else                             # RLE packet
          pixels << buffer.read(pixel_size) * packet_size
        end
        pixel_count += packet_size
        break if pixel_count >= total_pixels || buffer.eof?
      end
      pixel_data = pixels
    end
    abort("Corrupt pixel data") if pixel_data.size != total_pixels * pixel_size

    # Pixel data may be flipped
    if flip_x
      pixel_data = pixel_data.unpack("a#{pixel_size}" * total_pixels).each_slice(tga.width).map{ |row| row.reverse.join }
      pixel_data.reverse! if flip_y
      pixel_data = pixel_data.join
    elsif flip_y
      pixel_data = pixel_data.unpack("a#{pixel_size * tga.width}" * tga.height).reverse.join
    end

    # The game samples the "middle" pixel (32, 31) of each 64x64 block, ignores alpha layer
    offset = 31 * pixel_size * tga.width + 32 * pixel_size
    step = 64 * pixel_size
    colors.times.each{ |i|
      b, g, r = pixel_data.unpack("C3", offset: offset + step * i)
      output[x += 1, y] = ChunkyPNG::Color.rgb(r, g, b)
    }
  }
}
puts

# Export master palette image
output.save('palette.png', :fast_rgb)
log "Exported palette image"

# Print names in Ruby array format
PALETTE_NAMES << 'custom'
widths = COLUMNS.times.map{ |n|
  PALETTE_NAMES.select.with_index{ |palette, i| i % COLUMNS == n }.map(&:length).max
}
puts <<-ARY
  THEMES = [
#{
  PALETTE_NAMES.each_slice(COLUMNS).map{ |row|
    '    ' + row.map.with_index{ |palette, i| "'#{palette}',".ljust(widths[i] + 3, ' ') }.join(' ')
  }.join("\n")[..-2]
}
  ]
ARY
