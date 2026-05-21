# After so many years, we're reintroducing videos into outte, this time hopefully
# with a fully automatic method to regularly fetch and parse the spreadsheet.

class CreateVideos < ActiveRecord::Migration
  def up
    create_table :videos do |t|
      t.string  :highscoreable_type
      t.integer :highscoreable_id
      t.integer :player_id,    index: true
      t.integer :challenge_id, index: true
      t.string  :url
    end
    add_index :videos, [:highscoreable_type, :highscoreable_id]
    add_column :players, :code, :string
    Video.update
  end

  def down
    drop_table :videos
    remove_column :players, :code
  end
end
