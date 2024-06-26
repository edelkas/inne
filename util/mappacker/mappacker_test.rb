#require 'byebug'
#require 'fileutils'
#require 'net/http'
#require 'tk'
require 'win32/registry'
require 'zip'

# Mappack-specific constants
MAPPACK   = 'Community Tab Project'
AUTHOR    = 'CTP'
NAME      = 'cla'
FILES     = []#['SI', 'S', 'Scodes', 'SS', 'SScodes']

SPLASH    = MAPPACK # "#{MAPPACK} by #{AUTHOR}"
SIGNATURE = AUTHOR.dup
TITLE     = MAPPACK # "#{MAPPACK} by #{AUTHOR}"

# General constants
TEST      = true
HOST      = 'https://dojo.nplusplus.ninja'
PORT      = 8126
PROXY     = '45.32.150.168'
LOCAL     = '127.0.0.1'
TARGET    = "#{TEST ? LOCAL : PROXY}:#{PORT}/#{NAME}"
METANET   = "Metanet Software"
BY        = SIGNATURE[0...METANET.length].ljust(METANET.length, "\x00")
DIALOG    = true
PAD       = 32
CONTROLS  = false
NPROFILE  = true
$target   = TARGET.ljust(HOST.length, "\x00")

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
      mappack = file[offset_proxy ... offset_proxy + HOST.size].split('/').last.strip[/\D+/i].to_s
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
  raise "Failed to patch N++ files (incorrect target length)" if $target.length != HOST.length
  if !depatch
    file = file.gsub!(HOST, $target)
  else
    offset = file.index(TARGET)
    if offset.nil?
      file = nil
    else
      file[offset ... offset + HOST.length] = HOST
    end
  end
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

def swap_save(new_file, bak_file, nprofile, zip_in: true, zip_out: true)
  # Return if there are duplicates in the specified names
  return false if [new_file, bak_file, nprofile].uniq.size < 3

  # Return if the specified new file doesn't exist
  return false if !File.file?(new_file)

  # Backup the current save
  if File.file?(nprofile)
    if zip_out
      cur = File.binread(nprofile)
      buf = Zip::OutputStream.write_buffer{ |zip|
        zip.put_next_entry('nprofile')
        zip.write(cur)
      }
      File.binwrite(bak_file, buf.string)
    else
      File.rename(nprofile, bak_file)
    end
  end

  # Copy the new save
  if zip_in
    Zip::File.open(new_file){ |zip|
      File.binwrite(nprofile, zip.glob('nprofile').first.get_input_stream.read)
    }
  else
    File.copy(new_file, nprofile)
  end

  return true
rescue
  return false
end

def change_nprofile(install = true)
  folder = find_documents_folder
  print "┣━ Changing nprofile#{install ? '' : ' back'}...".ljust(PAD, ' ')

  # Copy nprofile file (from the nprofile folder, or the temp folder if we provided it)
  tmp = $0[/(.*)\//, 1]
  nprofile = File.join(folder, 'nprofile')
  og = File.join(folder, 'nprofile_original.zip')
  if install
    res = swap_save(File.join(folder, "nprofile_#{NAME}.zip"), og, nprofile)
    res = swap_save(File.join(tmp,    'nprofile.zip'        ), og, nprofile) if !res
    return puts "NOT DONE" if !res
  else
    res = swap_save(og, File.join(folder, "nprofile_#{NAME}.zip"), nprofile)
    return puts "NOT DONE" if !res
  end
  
  puts "OK"
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to swap nprofile.")
end

def change_levels_online(install)
  print "┣━ Downloading levels... ".ljust(PAD, ' ')

  # Fetch mappack list from Github
  res = Net::HTTP.get_response(URI.parse(
    "https://raw.githubusercontent.com/edelkas/inne/master/db/mappacks/digest"
  ))
  if res.code.to_i != 200 || res.body.empty?
    puts 'NO1'
    return nil
  end

  # Parse mappack list and find this one
  list = res.body.split("\n").map{ |m|
    fields = m.split(' ')
    {
      id:      fields[0].to_i,
      code:    fields[1],
      version: fields[2].to_i
    }
  }
  mappack = list.find{ |m| m[:code] == (install ? NAME : 'met') }
  if mappack.nil?
    puts 'NO2'
    return nil
  end

  # Fetch mappack level files from Github
  files = FILES.map{ |f|
    res = Net::HTTP.get_response(URI.parse(
      "https://raw.githubusercontent.com/edelkas/inne/master/db/mappacks/#{"%03d" % [mappack[:id]]}_#{mappack[:code]}/#{f}.txt"
    ))
    if res.code.to_i != 200 || res.body.empty?
      puts 'NO3'
      return nil
    end
    [f, res.body]
  }.to_h

  puts 'OK'
  $target = ($target.strip + mappack[:version].to_s).ljust(HOST.length, "\x00")
  files
rescue => e
  puts 'NO'
  return nil
end

def change_levels_locally(install)
  print "┣━ Swapping levels locally... ".ljust(PAD, ' ')

  # Fetch mappack level files from temp folder
  tmp = $0[/(.*)\//, 1]
  files = FILES.map{ |f|
    fn = install ? File.join(tmp, "#{f}.txt") : File.join(tmp, "#{f}_original.txt")
    [f, File.binread(fn)]
  }.to_h
  puts 'OK'
  files
rescue
  puts 'NO'
  return nil
end

def change_levels(install = true)
  # Find folder
  folder = File.join(find_npp_folder(false), 'NPP', 'Levels')
  raise "N++ levels folder not found" if !Dir.exist?(folder)
  
  # Change files
  files = nil
  files = change_levels_online(install) if false #install
  files = change_levels_locally(install) if files.nil?
  raise "Couldn't inject levels" if files.nil?
  FILES.each{ |f|
    File.write(File.join(folder, "#{f}.txt"), files[f])
  }
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
  change_text(file, 'PLAYER_PRESS_ANY', install ? SPLASH : 'Press Any Key')

  # Save file
  File.binwrite(fn, file)
  puts "OK"
rescue
  puts "NOT DONE"
  nil
end

def change_author(install = true)
  print "┣━ Changing author#{!install ? ' back' : ''}... ".ljust(PAD, ' ')

  # Read main library file
  fn = find_npp_library(false)
  file = File.binread(fn)

  # Change author name
  res = install ? file.gsub!(METANET, BY) : file.gsub!(BY, METANET)

  # Save file
  File.binwrite(fn, file)
  puts !res.nil? ? "OK" : 'NOT DONE'
rescue RuntimeError => e
  log_exception(e, '')
rescue => e
  log_exception(e, "Failed to patch N++ files#{info ? ' for info' : ''}.")
end

def install
  print "\n┏━━━ Installing '#{MAPPACK}' N++ mappack\n┃\n"
  change_levels(true)
  patch
  change_texts(true)
  change_controls(true) if CONTROLS
  change_nprofile(true) if NPROFILE
  change_author(true)
  puts "┃\n┗━━━ Installed '#{MAPPACK}' successfully!\n\n"
  dialog("N++ Mappack", "Installed '#{MAPPACK}' N++ mappack successfully!")
end

def uninstall
  print "\n┏━━━ Uninstalling '#{MAPPACK}' N++ mappack\n┃\n"
  change_levels(false)
  depatch
  change_texts(false)
  change_controls(false) if CONTROLS
  change_nprofile(false) if NPROFILE
  change_author(false)
  puts "┃\n┗━━━ Uninstalled '#{MAPPACK}' successfully!\n\n"
  dialog("N++ Mappack", "Uninstalled '#{MAPPACK}' N++ mappack successfully!")
end

str1 = "N++ MAPPACK INSTALLER"
str2 = TITLE
str3 = "Report technical issues to Eddy"
size = [str1.size, str2.size, str3.size].max
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
