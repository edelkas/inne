# This was used to generate the palette image
# It's not a complete TGA parser, just the bare minimum required

require 'chunky_png'
require 'rbconfig'
require 'stringio'

HEADER_SIZE = 18
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

# Find palette directory
PATHS = {
  'windows' => "C:/Program Files (x86)/Steam/steamapps/common/N++/NPP/Palettes",
  'linux'   => "#{Dir.home}/.steam/steam/steamapps/common/N++/NPP/Palettes"
}
SYS = RbConfig::CONFIG['host_os'] =~ /linux/i ? 'linux' : 'windows'
DIR = PATHS[SYS]

# For the final name export
COLUMNS = 4

# Parse palettes and count total colors to define output image
puts "Generating palette image..."
palettes = Dir.entries(DIR).reject{ |f| f == '.' || f == '..' }.sort_by(&:downcase)
colors = FILE_NAMES.inject(0){ |total, name|
  file = File.binread("#{DIR}/#{palettes.first}/#{name}.tga")
  total + file[12, 2].unpack('S<')[0] / 64
}
output = ChunkyPNG::Image.new(colors, palettes.size + 1, ChunkyPNG::Color::WHITE)
puts "Palettes found: #{palettes.size}"
puts "Colors found: #{colors}"

# Parse all colors and fill output image
count = palettes.count
palettes.each_with_index{ |palette, y|
  puts "Parsing palette [#{y + 1} / #{count}] #{palette}"
  x = -1

  FILE_NAMES.each{ |name|
  	# Parse TGA properties
    file = File.binread("#{DIR}/#{palette}/#{name}.tga")
    id_length, colormap_type, image_type = file.unpack('C3')
    cm_origin, cm_length, cm_depth = file[3, 5].unpack('S<2C')
    ox, oy, width, height, depth, desc = file[8, 10].unpack('S<4C2')
    colors = width / 64
    size = depth / 8

    # Sanity checks
    abort("Only RGB images are supported.")        if ![2, 10].include?(image_type)
    abort("Color-mapped images not supported.")    if colormap_type != 0
    abort("Interlaced images not supported.")      if desc[6, 2] > 0
    abort("Pixel depth isn't a multiple of 8.")    if depth % 8 != 0
    abort("Pixel depth cannot hold true color.")   if depth < 24
    abort("Colormap depth isn't a multiple of 8.") if cm_depth % 8 != 0

    # Get raw pixel data
    initial = HEADER_SIZE + id_length + cm_length * cm_depth / 8
    if image_type == 2 # Uncompressed
      pixel_data = file[initial, width * height * size]
    else               # RLE compressed
      buffer = StringIO.new(file[initial..])
      pixel_data = ""
      pixel_count = 0
      loop do
        header = buffer.read(1).unpack1('C')
        packet_size = (header & 0b01111111) + 1
        if header >> 7 == 0   # Raw packet
          pixel_data << buffer.read(packet_size * size)
        else                  # RLE packet
          pixel_data << buffer.read(size) * packet_size
        end
        pixel_count += packet_size
        break if pixel_count >= width * height || buffer.size - buffer.pos < 1
      end
    end
    abort("Corrupt RLE pixel data") if pixel_data.size != width * height * size

    # We sample the "middle" pixel (32, 32) of each 64x64 block
    offset = (32 * size) * (width + 1)
    step = 64 * size
    colors.times.each{ |i|
      color = pixel_data[offset + step * i, 3].reverse.unpack('H*')[0]
      output[x += 1, y] = ChunkyPNG::Color.from_hex(color)
    }
  }
}

# Export master palette image
output.save('palette.png', :fast_rgb)
puts "Exported palette image"

# Print names in Ruby array format
palettes << 'custom'
widths = COLUMNS.times.map{ |n|
  palettes.select.with_index{ |palette, i| i % COLUMNS == n }.map(&:length).max
}
puts <<-ARY
  THEMES = [
#{
  palettes.each_slice(4).map{ |row|
    '    ' + row.map.with_index{ |palette, i| "\"#{palette}\",".ljust(widths[i] + 3, ' ') }.join(' ')
  }.join("\n")[..-2]
}
  ]
ARY
