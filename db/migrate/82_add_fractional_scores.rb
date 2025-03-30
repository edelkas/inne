# Store interpolated fractional scores using NSim
class AddFractionalScores < ActiveRecord::Migration[7.1]
  def change
    add_column :archives, :fraction, :double, default: nil
  end
end
