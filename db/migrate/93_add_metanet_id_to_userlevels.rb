# Incorporate metanet_id to userlevel scores so that we can query them like we
# do for archived vanilla scores.
class AddMetanetIdToUserlevels < ActiveRecord::Migration[5.1]
  def change
    add_column :userlevel_scores, :metanet_id, :integer

    max = UserlevelScore.maximum(:id) + 1
    size = 1000
    suppress_messages do
      0.step(max, size).each{ |offset|
        sql <<~SQL
          UPDATE userlevel_scores
          INNER JOIN userlevel_players ON userlevel_players.id = userlevel_scores.player_id
          SET userlevel_scores.metanet_id = userlevel_players.metanet_id
          WHERE userlevel_scores.id >= #{offset} AND userlevel_scores.id < #{offset + size}
        SQL
        dbg("Updated userlevel scores #{offset} - #{offset + size} (max. #{max})...", progress: true)
      }
    end
  end
end
