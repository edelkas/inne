class CreateArchives < ActiveRecord::Migration[5.1]

  def change
    # This will be a differential table holding all the current and new scores.
    create_table :archives do |t|
      t.integer    :replay_id               # ID of score in Metanet's db
      t.integer    :metanet_id, index: true # ID of player in Metanet's db
      t.references :player, index: true
      t.references :highscoreable, polymorphic: true, index: true
      t.integer    :score
      t.timestamp  :date
    end

    # This will store all the replay demos of the scores stored in 'archives',
    # sharing the same ID.
    create_table :demos do |t|
      t.integer :replay_id
      t.integer :htype, limit: 1
      t.binary  :demo
      t.boolean :expired
    end
    # Make sure "htype" is a tinyint(4) in MySQL, because tinyint(1) are
    # interpreted as booleans by default and we don't want to override that.

    # Demos will be downloaded in parallel, we give them their own timer.
    ActiveRecord::Base.transaction do
      GlobalProperty.find_or_create_by(key: 'next_demo_update').update(value: (Time.now + 86400).to_s)
    end
  end
end
