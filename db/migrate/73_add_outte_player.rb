class AddOuttePlayer < ActiveRecord::Migration[5.1]
  def change
    Player.find_or_create_by(metanet_id: OUTTE_ID).update(
      name:     'outte++',
      steam_id: OUTTE_STEAM_ID.to_s
    )
  end
end
