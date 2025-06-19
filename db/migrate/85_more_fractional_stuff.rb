class MoreFractionalStuff < ActiveRecord::Migration[5.1]
  def change
      add_column :mappacks,         :fractional, :boolean, default: false
      add_column :archives,         :simulated,  :boolean, default: false
      add_column :mappack_scores,   :simulated,  :boolean, default: false
      add_column :userlevel_scores, :simulated,  :boolean, default: false
      Player.find_or_create_by(name: DEV_PLAYER_NAME)
      [Archive, MappackScore, UserlevelScore].each do |klass|
        klass.where.not(fraction: 1).update_all(simulated: true)
      end
  end
end
