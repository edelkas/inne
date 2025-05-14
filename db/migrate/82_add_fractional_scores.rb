# Store interpolated fractional scores using NSim
class AddFractionalScores < ActiveRecord::Migration[5.1]
  def change
    add_column :archives,         :fraction, :double, default: nil
    add_column :mappack_scores,   :fraction, :double, default: nil
    add_column :userlevel_scores, :fraction, :double, default: nil
  end
end
