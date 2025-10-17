# Add the new levels and challenges introduced in the TEN++ update to celebrate
# the game's release 10th anniversary. As usual, we only include Solo here, the
# other stuff has been added to the mappack folder though, so a simple update
# will fetch those in too. The new solo levels are visually split in 2 tabs,
# but internally they're a single tab (index 6, codenamed "DLC"), so that's
# what we do here as well, to prevent breaking compatibility.
class AddTenpp < ActiveRecord::Migration[5.1]
  def change
    dir = Mappack.find(0).folder(v: 2)
    tab = TABS_NEW[:ST]
    tab_id = tab[:mode] * 7 + tab[:tab]
    letters = ('A'..'Z').to_a.reject{ |letter| letter == 'N' }

    # Parse level data
    level_id = tab[:start]
    tab[:files].each{ |filename, count|
      code = filename == 'SSS' ? '?!' : '!?'
      path = File.join(dir, filename  + '.txt')
      File.read(path).scan(/\$(.+?)#/).map(&:first).each_with_index{ |title, i|
        Level.find_or_create_by(id: level_id).update(
          name:        code + '-' + letters[i],
          completed:   false,
          longname:    title.strip,
          tab:         tab_id,
          completions: 0,
          mode:        tab[:mode]
        )
        level_id += 1
      }
    }

    # Parse challenge data
    level_id = tab[:start]
    tab[:files].each{ |filename, count|
      path = File.join(DIR_CHALLENGES, filename + 'codes.txt')
      maps = File.read(path).split("\n")
      maps.each_with_index{ |map, i|
        print("Parsing #{filename} challenges: #{i + 1} / #{maps.size}...".ljust(80, " ") + "\r")
        map.squish.split(" ").each_with_index{ |c, j|
          objs = { "G" => 0, "T" => 0, "O" => 0, "C" => 0, "E" => 0 }
          c.scan(/../).each{ |o|
            objs[o[1]] = o[0] == "A" ? 1 : o[0] == "N" ? -1 : 2
          }
          Challenge.find_or_create_by(
            level_id: level_id,
            index:    j,
            g:        objs["G"],
            t:        objs["T"],
            o:        objs["O"],
            c:        objs["C"],
            e:        objs["E"]
          )
        }
        level_id += 1
      }
    }
  end
end
