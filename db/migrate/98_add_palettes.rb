# Incorporate palettes directly into the database
require "./#{DIR_SOURCE}/maps.rb"
require "./#{DIR_SOURCE}/mappacks.rb"

class AddPalettes < ActiveRecord::Migration[5.1]
  def up
    create_table :palettes do |t|
      t.string    :name
      t.string    :author
      t.integer   :user_id
      t.integer   :mappack_id
      t.timestamp :date
      t.binary    :colors, limit: 1024
    end

    add_index :palettes, :mappack_id
    add_index :palettes, :user_id
    Palette.seed_metanet_palettes
  end

  def down
    drop_table :palettes
  end
end
