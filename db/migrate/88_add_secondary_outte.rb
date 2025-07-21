class AddSecondaryOutte < ActiveRecord::Migration[5.1]
  def change
    Player.find_or_create_by(metanet_id: OUTTE2_ID).update(
      name:     'outte++2',
      steam_id: OUTTE2_STEAM_ID
    )
  end
end
