require 'byebug'
require 'fileutils'
#require 'tk'
require 'win32/registry'

# Mappack-specific constants
MAPPACK = 'Duality'
AUTHOR  = 'w95559w'
NAME    = 'dua'
FILES   = ['C', 'C2']

# General constants
TEST     = false
HOST     = 'https://dojo.nplusplus.ninja'
PORT     = 8126
PROXY    = '45.32.150.168'
LOCAL    = '127.0.0.1'
TARGET   = "#{TEST ? LOCAL : PROXY}:#{PORT}/#{NAME}".ljust(HOST.length, "\x00")
DIALOG   = true
PAD      = 32
CONTROLS = true

def dialog(title, text)
  print "\a"
  type = title == 'Error!' ? 16 : 0
  File.binwrite('tmp.vbs', %{x=msgbox("#{text.split("\n")[0]}", #{type}, "#{title}")})
  spawn "wscript //nologo tmp.vbs & del tmp.vbs" if DIALOG
end

def log_exception(e, msg)
  str1 = "ERROR! Failed to #{$installed ? 'uninstall' : 'install'} '#{MAPPACK}' N++ mappack :("
  str2 = e.class.to_s == 'RuntimeError' ? e.to_s : "See the console for details"
  print "\n\n#{str1}\n\n"
  puts "#{!msg.empty? ? "#{msg}\n" : ''}Details: #{e}\n\n"
  dialog('Error', "#{str1}\" & vbCrLf & vbCrLf & \"#{str2}") if DIALOG
  exit
end

def find_steam_folders(output = true)
  print "┣━ Finding Steam folder... ".ljust(PAD, ' ') if output
  # Find Steam directory in the registry
  folder = nil
  folder = Win32::Registry::HKEY_LOCAL_MACHINE.open('SOFTWARE\WOW6432Node\Valve\Steam') rescue nil
  folder = (Win32::Registry::HKEY_LOCAL_MACHINE.open('SOFTWARE\Valve\Steam') rescue nil) if folder.nil?
  raise "Steam folder not found in registry" if folder.nil?

  # Find Steam installation path in the registry
  path = folder['InstallPath'] rescue nil
  raise "Steam installation path not found in registry" if path.nil?
  raise "Steam installation not found" if !Dir.exist?(path)

  # Find steamapps folder
  steamapps = File.join(path, 'steamapps')
  raise "Steam folder not found (steamapps folder missing)" if !Dir.exist?(steamapps)
  library = File.read(File.join(steamapps, 'libraryfolders.vdf')) rescue nil
  raise "Steam folder not found (libraryfolders.vdf file missing)" if library.nil?

  # Find alternative Steam installation paths
  folders = library.split("\n").select{ |l| l =~ /"path"/i }.map{ |l| l[/"path".*"(.+)"/, 1].gsub(/\\\\/, '\\') rescue nil }.compact
  folders << path
  folders.uniq!

  puts "OK" if output
  folders
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to find Steam folder")
end

# Find N++ folder in My Documents, where the nprofile and the npp.conf files are located
def find_documents_folder(output = true)
  # Find My Documents
  print "┣━ Finding documents folder... ".ljust(PAD, ' ') if output
  reg = Win32::Registry::HKEY_CURRENT_USER.open('Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders') rescue nil
  raise "Shell folders not found" if reg.nil?
  folder = reg['Personal'] rescue nil
  raise "My Documents folder not found" if folder.nil?

  # Find N++ folder
  dir = File.join(folder, 'Metanet', 'N++')
  raise "N++ documents folder not found" if !Dir.exist?(dir)

  puts "OK" if output
  dir
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to find documents folder")
end

def find_npp_folder(output = true)
  folder = nil
  folders = find_steam_folders(output)
  print "┣━ Finding N++ folder... ".ljust(PAD, ' ') if output
  folders.each{ |f|
    path = File.join(f, 'steamapps', 'common', 'N++')
    folder = path if Dir.exist?(path)
  }
  raise "N++ installation not found" if folder.nil?
  
  puts "OK" if output
  folder
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to find N++ folder.")
end

def find_npp_library(output = true)
  # Read main library file
  folder = find_npp_folder(output)
  print "┣━ Finding npp.dll... ".ljust(PAD, ' ') if output
  fn = File.join(folder, 'npp.dll')
  raise "N++ files not found (npp.dll missing)" if !File.file?(fn)

  puts "OK" if output
  fn
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to find N++ files.")
end

def patch(depatch = false, info = false)
  # Read main library file
  fn = find_npp_library(!info)
  print "┣━ #{depatch ? 'Depatching' : 'Patching'} npp.dll... ".ljust(PAD, ' ') if !info
  file = File.binread(fn)

  # Determine state
  if info
    offset_host = file.index(HOST)
    offset_proxy = file.index(TEST ? LOCAL : PROXY)
    if !offset_host.nil?
      return false
    elsif !offset_proxy.nil?
      mappack = file[offset_proxy ... offset_proxy + HOST.size].split('/').last.strip
      if mappack == NAME
        return true
      else
        raise "Mappack #{mappack.upcase} seems to be installed, please uninstall it first"
      end
    else
      raise "Couldn't find URL in npp.dll to patch"
    end
  end

  # Patch library
  raise "Failed to patch N++ files (incorrect target length)" if TARGET.length != HOST.length
  file = depatch ? file.gsub!(TARGET, HOST) : file.gsub!(HOST, TARGET)
  raise "Failed to patch N++ files (host/target not found). If you have another mappack installed, please uninstall it first." if file.nil?
  File.binwrite(fn, file)

  puts "OK" if !info
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to patch N++ files#{info ? ' for info' : ''}.")
end

def depatch
  patch(true)
end

def change_controls(install = true)
  folder = find_documents_folder
  print "┣━ Changing P2 controls#{install ? '' : ' back'}...".ljust(PAD, ' ')
  # Read controls file
  path = File.join(folder, 'keys.vars')
  file = File.binread(path)
  raise "keys.vars file not found" if file.nil?

  # Parse controls
  controls = file.split("\n").select{ |l| !!l[/=/] }.map{ |l|
    arr = l.split("=")
    [arr[0].strip, arr[1].strip[0..-2]]
  }.to_h

  # Change controls
  controls['input_p2_left_key']  = install ? controls['input_p1_left_key']  : '-1'
  controls['input_p2_right_key'] = install ? controls['input_p1_right_key'] : '-1'
  controls['input_p2_jump_key']  = install ? controls['input_p1_jump_key']  : '-1'
  controls['input_p2_alt2_key']  = install ? controls['input_p1_alt2_key']  : '-1'

  # Export controls
  controls = controls.map{ |k, v| "#{k} = #{v};" }.join("\n")
  File.binwrite(path, controls)

  puts "OK"
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to change level files.")
end

def change_levels(install = true)
  print "┣━ Swapping map files#{install ? '' : ' back'}... ".ljust(PAD, ' ')
  # Find folder
  folder = File.join(find_npp_folder(false), 'NPP', 'Levels')
  raise "N++ levels folder not found" if !Dir.exist?(folder)
  
  # Change files
  tmp = $0[/(.*)\//, 1]
  FILES.each{ |f|
    fn = install ? File.join(tmp, "#{f}.txt") : File.join(tmp, "#{f}_original.txt")
    FileUtils.cp_r(fn, File.join(folder, "#{f}.txt"), remove_destination: true)
  }

  puts "OK"
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to change level files.")
end

def change_text(file, name, value)
  file.sub!(/#{name}\|[^\|]+?\|/, "#{name}|#{value}|")
end

def change_texts(install = true)
  print "┣━ Changing texts#{install ? '' : ' back'}... ".ljust(PAD, ' ')
  # Read file
  fn = File.join(find_npp_folder(false), 'NPP', 'loc.txt')
  file = File.binread(fn) rescue nil
  return if file.nil?

  # Change texts
  change_text(file, 'HIGH_SCORE_PANEL_FRIEND_HIGHSCORES_LONG', install ? 'Speedrun Boards' : 'Friends Highscores')
  change_text(file, 'HIGH_SCORE_PANEL_FRIEND_HIGHSCORES_SHORT', install ? 'Speedrun' : 'Friends')
  change_text(file, 'PLAYER_PRESS_ANY', install ? "#{MAPPACK} by #{AUTHOR}" : 'Press Any Key')

  # Save file
  File.binwrite(fn, file)
  puts "OK"
rescue
  nil
end

def install
  print "\n┏━━━ Installing '#{MAPPACK}' N++ mappack\n┃\n"
  patch
  change_levels(true)
  change_texts(true)
  change_controls(true) if CONTROLS
  puts "┃\n┗━━━ Installed '#{MAPPACK}' successfully!\n\n"
  dialog("N++ Mappack", "Installed '#{MAPPACK}' N++ mappack successfully!")
end

def uninstall
  print "\n┏━━━ Uninstalling '#{MAPPACK}' N++ mappack\n┃\n"
  depatch
  change_levels(false)
  change_texts(false)
  change_controls(false) if CONTROLS
  puts "┃\n┗━━━ Uninstalled '#{MAPPACK}' successfully!\n\n"
  dialog("N++ Mappack", "Uninstalled '#{MAPPACK}' N++ mappack successfully!")
end

str1 = " N++ MAPPACK INSTALLER "
str2 = " '#{MAPPACK}' by #{AUTHOR} "
str3 = "Report technical issues to Eddy"
size = [str1.size, str2.size, str3.size - 2].max
puts
puts "╔#{'═' * size}╗"
puts "║#{str1.center(size)}║"
puts "║#{str2.center(size)}║"
puts "╚#{'═' * size}╝"
puts str3
puts
print "Checking current state... "
$installed = patch(false, true)
puts $installed ? 'installed' : 'uninstalled'
$installed ? uninstall : install
gets if !DIALOG

=begin
# Main window
$root = TkRoot.new(title: "")
w, h = 200, 50
$root.minsize(w, h)
$root.geometry("#{w}x#{h}")
$root.grid_columnconfigure(0, weight: 1)
$root.resizable(0, 0)
screen_width = $root.winfo_screenwidth
screen_height = $root.winfo_screenheight
x = (screen_width - w) / 2
y = (screen_height - h) / 2
$root.geometry("#{$root.width}x#{$root.height}+#{x}+#{y}")
Tk.bell

# Elements
label = TkLabel.new($root, text: "#{MAPPACK} #{$installed ? "uninstalled" : "installed"} successfully!").grid(row: 0, column: 0, sticky: 'news')
button = TkButton.new($root, text: "Ok", command: -> { $root.destroy }).grid(row: 1, column: 0)

# Run GUI
Tk.mainloop
=end