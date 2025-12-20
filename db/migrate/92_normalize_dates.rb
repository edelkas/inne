# Assign all initial archives the same exact date, for sorting purposes
# Also, some scores were archived long after they were done (e.g. Mishu), so we
# find the closest date by replay ID and assign it.
class NormalizeDates < ActiveRecord::Migration[5.1]
  def change
    # Normalize all pre-epoch dates
    puts "Normalizing pre-epoch archive dates..."
    Archive.where('date < ?', Archive::EPOCH).update_all(date: Archive::EPOCH)

    # Normalize late archival dates
    mishu_id = CHEATERS.find{ |k, v| v.include?("Mishu") }.first
    list = Archive.where(metanet_id: mishu_id)
    count = list.count

    list.each_with_index do |ar, i|
      # Find surrounding archived scores
      prv = Archive.where(highscoreable_type: ar.highscoreable_type)
                   .where.not(metanet_id: mishu_id)
                   .where('replay_id < ?', ar.replay_id)
                   .order(replay_id: :desc)
                   .first
      nxt = Archive.where(highscoreable_type: ar.highscoreable_type)
                   .where('replay_id > ?', ar.replay_id)
                   .order(replay_id: :asc)
                   .first

      # Compute new date
      next ar.update(date: Time.now) if !nxt
      next ar.update(date: Archive::EPOCH) if !prv
      m = (ar.replay_id - prv.replay_id).to_f / (nxt.replay_id - prv.replay_id)
      new_date = (prv.date + m * (nxt.date - prv.date)).round
      print("Normalized late archival timestamp #{i + 1} / #{count}...".ljust(80, ' ') + "\r")
      ar.update(date: new_date)
    end
  end
end
