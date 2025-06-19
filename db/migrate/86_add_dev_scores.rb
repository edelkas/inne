# Add fields to store special "Developer Scores" for mappack highscoreables so
# that players have an optional score to aim for.
class AddDevScores < ActiveRecord::Migration[5.1]
  def change
      add_column :mappack_levels,   :dev_hs, :float
      add_column :mappack_episodes, :dev_hs, :float
      add_column :mappack_stories,  :dev_hs, :float
      add_column :mappack_levels,   :dev_sr, :integer
      add_column :mappack_episodes, :dev_sr, :integer
      add_column :mappack_stories,  :dev_sr, :integer
  end
end
