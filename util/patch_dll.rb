TEST  = true
PACK  = 'ctp'
HOST  = "https://dojo.nplusplus.ninja"
IP    = TEST ? '127.0.0.1' : '45.32.150.168'
PORT  = 8126
PROXY = "#{IP}:#{PORT}/#{PACK}".ljust(HOST.length, "\x00")
IN    = 'npp.dll'
OUT   = 'npp.dll'

raise "#{IN} not found in folder" if !File.file?(IN)
file = File.binread(IN)
test = TEST ? ' (test)' : ''
if file.include?(HOST)
  file.gsub!(HOST, PROXY)
  puts "Patched #{PACK.upcase}#{test}"
elsif file.include?(PROXY)
  file.gsub!(PROXY, HOST)
  puts "Unpatched #{PACK.upcase}#{test}"
else
  raise "URL#{test} not found"
end
File.binwrite(OUT, file)