class CreateUserlevels < ActiveRecord::Migration[5.1]
  def change
    create_table :userlevels do |t|
      t.integer :author_id, index: true
      t.string  :author
      t.string  :title
      t.integer :favs
      t.string  :date
      t.integer :mode
    end

    create_table :userlevel_data do |t|
      # We limit object data to 1MB to force MySQL to create a MEDIUMBLOB,
      # which can hold up to 16MB, otherwise a BLOB is created, which can only
      # hold 64KB and is thus not sufficient for the theoretical biggest
      # possible maps.
      t.binary :tile_data
      t.binary :object_data, limit: 1024 ** 2
    end
  end
end
