# Some vanilla levels were changed after release and had gold added or removed,
# resulting in the old scores being off by a multiple of 2. We apply these
# corrections when downloading the scores, but so far we were storing them in
# the source, when we should really do it in the database.
#   For mappack levels, they instead reflect changes that were done from their
# corresponding userlevel counterparts, whenever that applies.

class AddScoreCorrections < ActiveRecord::Migration[5.1]
  def change
    create_table :score_corrections do |t|
      t.integer :highscoreable_id
      t.string  :highscoreable_type
      t.integer :gold
      t.integer :replay_id
    end
  end
end
