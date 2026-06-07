# Add fields to map mappack levels to their corresponding userlevels for when
# mappacks contain already published levels and we might want to forward
# the scores instead of storing them locally.

class MapLevelsToUserlevels < ActiveRecord::Migration[5.1]
  def change
    add_column :mappack_levels, :userlevel_id, :integer
    add_column :mappack_levels, :forward,      :boolean, default: false
  end
end
