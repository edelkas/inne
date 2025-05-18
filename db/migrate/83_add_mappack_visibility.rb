# Store interpolated fractional scores using NSim
class AddMappackVisibility < ActiveRecord::Migration[5.1]
  def change
    add_column :mappacks, :enabled, :boolean, default: true
    add_column :mappacks, :public,  :boolean, default: true
  end
end
