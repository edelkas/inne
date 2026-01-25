# Script to generate a showcase image of all palettes as a grid of tiles
require 'rmagick'
include Magick

# Paths
FONT_PATH   = "fonts/sys/Sys.otf"
INPUT_PATH  = "../img/palette.png"
OUTPUT_PATH = "palette_grid.png"

# Palette info
THEMES = [
  "acid",           "airline",         "anniversary",  "argon",
  "autumn",         "BASIC",           "berry",        "birthday cake",
  "bloodmoon",      "blueprint",       "bordeaux",     "brink",
  "burple",         "cacao",           "champagne",    "chemical",
  "chococherry",    "classic",         "classy",       "clean",
  "concrete",       "console",         "cowboy",       "dagobah",
  "debugger",       "delicate",        "desert world", "disassembly",
  "dorado",         "dusk",            "elephant",     "epaper",
  "epaper invert",  "evening",         "F7200",        "florist",
  "formal",         "galactic",        "gatecrasher",  "gothmode",
  "grapefrukt",     "grappa",          "gunmetal",     "hazard",
  "heirloom",       "holosphere",      "hope",         "hot",
  "hyperspace",     "ice world",       "incorporated", "infographic",
  "invert",         "jaune",           "juicy",        "kicks",
  "lab",            "lava world",      "lemonade",     "lichen",
  "lightcycle",     "line",            "m",            "machine",
  "metoro",         "midnight",        "minus",        "mir",
  "mono",           "moonbase",        "mustard",      "mute",
  "nemk",           "neptune",         "neutrality",   "noctis",
  "oceanographer",  "okinami",         "orbit",        "pale",
  "papier",         "papier invert",   "party",        "petal",
  "PICO-8",         "pinku",           "plus",         "porphyrous",
  "poseidon",       "powder",          "pulse",        "pumpkin",
  "QDUST",          "quench",          "regal",        "replicant",
  "retro",          "rust",            "sakura",       "shift",
  "shock",          "simulator",       "sinister",     "SNKRX",
  "solarized dark", "solarized light", "starfighter",  "sunset",
  "supernavy",      "synergy",         "talisman",     "ten",
  "toothpaste",     "toxin",           "TR-808",       "tropical",
  "tycho",          "vasquez",         "vectrex",      "vintage",
  "virtual",        "vivid",           "void",         "waka",
  "witchy",         "wizard",          "wyvern",       "xenon",
  "yeti"
]
BG_COLOR_INDEX      = 2
TEXT_COLOR_INDEX    = 1
OUTLINE_COLOR_INDEX = 1

# Grid geometry
TILE_WIDTH   = 250
TILE_HEIGHT  = 50
TILE_SPACING = 10
COLS         = 5
ROWS         = (THEMES.size.to_f / COLS).ceil

# Font
POINT_SIZE    = 36 # Use 0 for automatic scaling (takes much longer)
FONT_WEIGHT   = BoldWeight
MAX_POINTSIZE = 36
MIN_POINTSIZE = 10
STROKE_WIDTH  = 0
PADDING       = 20

# Decor
BORDER_WIDTH         = 2
BORDER_COLOR         = 'black'
BORDER_RADIUS        = 16
SWATCH_SIZE          = 8
SWATCH_COLOR_INDICES = [6, 7, 8, 9]

palettes_img = Image.read(INPUT_PATH).first

# Generate tiles
tiles = THEMES.map.with_index do |name, i|
  # Create base tile
  print("Generating tile %3d / %3d: %-*s\r" % [i + 1, THEMES.size, THEMES.map(&:size).max, name])
  bg_pixel      = palettes_img.pixel_color(BG_COLOR_INDEX, i)
  text_pixel    = palettes_img.pixel_color(TEXT_COLOR_INDEX, i)
  outline_pixel = palettes_img.pixel_color(OUTLINE_COLOR_INDEX, i)
  swatch_pixels = SWATCH_COLOR_INDICES.map{ |idx|  palettes_img.pixel_color(idx, i) }
  tile = Image.new(TILE_WIDTH, TILE_HEIGHT) { |opts| opts.background_color = 'transparent' }

  # Render rectangle
  draw_bg = Draw.new
  draw_bg.fill = bg_pixel.to_color
  draw_bg.stroke = BORDER_COLOR
  draw_bg.stroke_width = BORDER_WIDTH
  draw_bg.roundrectangle(
    BORDER_WIDTH,
    BORDER_WIDTH,
    TILE_WIDTH - BORDER_WIDTH,
    TILE_HEIGHT - BORDER_WIDTH,
    BORDER_RADIUS,
    BORDER_RADIUS
  )
  draw_bg.draw(tile)

  # Render swatch
  base_x = TILE_WIDTH  - 2 * SWATCH_SIZE - 8
  base_y = TILE_HEIGHT / 2 - SWATCH_SIZE
  swatch_pixels.each_with_index do |pix, k|
    x = base_x + (k % 2) * (SWATCH_SIZE + 2)
    y = base_y + (k / 2) * (SWATCH_SIZE + 2)
    swatch_draw = Draw.new
    swatch_draw.stroke = 'none'
    swatch_draw.stroke_width = 1
    swatch_draw.fill = pix.to_color
    swatch_draw.rectangle(x, y, x + SWATCH_SIZE, y + SWATCH_SIZE)
    swatch_draw.draw(tile)
  end

  # Configure text
  draw_txt = Draw.new
  draw_txt.font = FONT_PATH
  draw_txt.font_weight = FONT_WEIGHT
  draw_txt.fill = text_pixel.to_color
  draw_txt.stroke = outline_pixel.to_color if STROKE_WIDTH > 0
  draw_txt.stroke_width = STROKE_WIDTH if STROKE_WIDTH > 0
  draw_txt.gravity = CenterGravity

  # Compute optimal point size
  if POINT_SIZE > 0
    draw_txt.pointsize = POINT_SIZE
  else
    pointsize = MAX_POINTSIZE
    metrics = nil
    loop do
      draw_txt.pointsize = pointsize
      metrics = draw_txt.get_type_metrics(tile, name)
      break if (metrics.width <= TILE_WIDTH - PADDING) && (metrics.height <= TILE_HEIGHT - PADDING)
      pointsize -= 1
      break if pointsize < MIN_POINTSIZE
    end
  end

  # Render text
  draw_txt.annotate(tile, 0, 0, 0, 0, name)
  tile
end

# Assemble grid
final = Image.new(
  COLS * TILE_WIDTH +  (COLS + 0.5) * TILE_SPACING,
  ROWS * TILE_HEIGHT + (ROWS + 0.5) * TILE_SPACING
) { |opts| opts.background_color = 'transparent' }
tiles.each_with_index do |tile, idx|
  x = (idx % COLS) * TILE_WIDTH  + (idx % COLS + 0.5) * TILE_SPACING
  y = (idx / COLS) * TILE_HEIGHT + (idx / COLS + 0.5) * TILE_SPACING
  final.composite!(tile, x, y, OverCompositeOp)
end

# Export image
final.write(OUTPUT_PATH)
puts "\nGenerated #{OUTPUT_PATH}"
