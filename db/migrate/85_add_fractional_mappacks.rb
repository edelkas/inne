class AddFractionalMappacks < ActiveRecord::Migration[5.1]
  def change
      add_column :mappacks, :fractional, :boolean, default: false
  end
end
