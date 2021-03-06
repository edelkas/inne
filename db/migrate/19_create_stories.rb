# Internally we use the same tabs as Solo mode because, in essence, they're the same
# However, it makes no sense to use the same names, since the evo
def tab(prefix)
  {
    'SI' => :SI,
    'S' => :S,
    'SL' => :SL,
    'SU' => :SU
  }[prefix]
end

def ids(tab, offset, n)
  ret = (0..n - 1).to_a.map{ |s|
    tab + "-" + s.to_s.rjust(2,"0")
  }.each_with_index.map{ |l, i| [offset + i, l] }.to_h
end

class CreateStories < ActiveRecord::Migration[5.1]
  def change
    create_table :stories do |t|
      t.string :name
      t.boolean :completed
      t.integer :tab, index: true
    end

    # Seed stories
    ActiveRecord::Base.transaction do
      [['SI', 0, 5], ['S', 24, 20], ['SL', 48, 20], ['SU', 96, 20]].each{ |s|
        ids(s[0],s[1],s[2]).each{ |story|
          Story.find_or_create_by(id: story[0]).update(
            #completed: false, # commented because we use nil instead
            name: story[1],
            tab: tab(story[1].split('-')[0])
          )
        }
      }
      GlobalProperty.find_or_create_by(key: 'next_story_update').update(value: (Time.now + 86400).to_s)
      GlobalProperty.find_or_create_by(key: 'current_story').update(value: 'S-15')
      GlobalProperty.find_or_create_by(key: 'saved_story_scores').update(value: [])
    end
  end
end
