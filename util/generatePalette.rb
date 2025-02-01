# This was used to generate the palette image
# It's not a complete TGA parser, just the bare minimum required
require 'chunky_png'

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
DIR = '~/.steam/steam/steamapps/common/N++/NPP/Palettes'

# Parse palettes and count total colors to define output image
puts "Generating palette image..."
palettes = Dir.entries(DIR).reject{ |f| f == '.' || f == '..' }.sort_by(&:downcase)
colors = FILE_NAMES.inject(0){ |total, name|
  file = File.binread("#{DIR}/#{palettes.first}/#{name}.tga")
  total + file[12, 2].unpack('S<')[0] / 64
}
output = ChunkyPNG::Image.new(colors, palettes.size, ChunkyPNG::Color::WHITE)
puts "Palettes found: #{palettes.size}"
puts "Colors found: #{colors}"

# Parse all colors and fill output image
count = palettes.count
palettes.each_with_index{ |palette, y|
  print("Parsing palette [#{y + 1} / #{count}] #{palette}".ljust(80) + "\r")
  x = -1

  FILE_NAMES.each{ |name|
  	# Parse TGA properties
    file = File.binread("#{DIR}/#{palette}/#{name}.tga")
    ox, oy, width, height, depth, desc = file[8, 10].unpack('S<4C2')
    colors = width / 64
    channels = depth / 8

    # We sample the "middle" pixel (32, 32) of each 64x64 block
    initial = HEADER_SIZE + (32 * channels) * (width + 1)
    step = 64 * channels
    colors.times.each{ |i|
      color = file[initial + step * i, 3].reverse.unpack('H*')[0]
      output[x += 1, y] = ChunkyPNG::Color.from_hex(color)
    }
  }
}
puts "Done".ljust(80)

output.save('palette.png', :fast_rgb)
