# Downloads all userlevels from Metanet's server so they can be used as an
# initial seed for the database. To use you need to set PAGES correctly.
# TODO: This should be implemented in a dynamic way as a function in outte.
#       I've removed all these files from the repo now.

require 'net/http'
Dir.chdir('../maps')

MODES = ['solo', 'coop', 'race']
PAGES = [150, 20, 20]
$done = (0..2).to_a.map{ |i| [{exists: true, done: false}] * PAGES[i] }

def url(mode, page)
  URI("https://dojo.nplusplus.ninja/prod/steam/query_levels?steam_id=76561198031272062&steam_auth=&qt=10&mode=#{mode}&page=#{page}")
end

def get(mode, page)
  print("Trying page " + page.to_s + "... ")
  response = Net::HTTP.get(url(mode, page))
  if response.size == 48
    $done[mode][page][:exists] = false
    $done[mode][page][:done] = false
    print("doesn't exist.\n")
    return 0
  end
  if response == '-1337'
    print("failed.\n")
    return 0
  end
  if response.include?("502 Bad Gateway")
    print("failed.\n")
    return 0
  end
  $done[mode][page][:exists] = true
  $done[mode][page][:done] = true
  print("done.\n")
  return response
end

MODES.each_with_index{ |mode, i|
  $done[mode].each_with_index{ |page, j|
    file = get(i, j)
    if file != 0 then File.write('#{mode}/' + j.to_s.rjust(PAGES.to_s.size,'0'), file) end
  }
}
