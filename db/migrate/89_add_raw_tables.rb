# Additional tables to mirror the entire Metanet db as closely as possible,
# they are intended for archival only, and they are separate so the
# queries for highscoring stats are still performed on much smaller tables.
class AddRawTables < ActiveRecord::Migration[5.1]
  def change
    create_table :raw_players, id: :integer do |t|
      t.string :name
    end

    create_table :raw_scores, id: :integer do |t|
      t.integer :replay_id,          index: true
      t.integer :player_id,          index: true
      t.integer :rank,               index: true
      t.integer :tied_rank,          index: true
      t.integer :highscoreable_type, limit: 1
      t.integer :highscoreable_id
      t.integer :score
    end

    create_table :raw_demos, id: :integer do |t|
      t.binary :demo
    end

    add_index :raw_scores, [:highscoreable_type, :highscoreable_id]
  end
end
