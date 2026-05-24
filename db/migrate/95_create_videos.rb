# After so many years, we're reintroducing videos into outte, this time hopefully
# with a fully automatic method to regularly fetch and parse the spreadsheet.

class CreateVideos < ActiveRecord::Migration[5.1]
  def up
    create_table :videos do |t|
      t.string  :highscoreable_type
      t.integer :highscoreable_id
      t.integer :streamer_id,  index: true
      t.integer :challenge_id, index: true
      t.string  :url
    end

    create_table :streamers do |t|
      t.string  :code
      t.string  :name
      t.integer :player_id
      t.string  :twitch
      t.string  :youtube
    end

    add_index :videos, [:highscoreable_type, :highscoreable_id]
    Video.update
  end

  def down
    drop_table :videos
    drop_table :streamers
  end
end
