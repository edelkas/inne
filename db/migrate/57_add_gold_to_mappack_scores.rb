class AddGoldToMappackScores < ActiveRecord::Migration[5.1]
  def change
    change_table :mappack_scores do |t|
      t.integer :gold, index: true, limit: 2
    end

    count = MappackScore.count
    MappackScore.all.each_with_index{ |s, i|
      print("Calculating gold count for score #{i + 1} / #{count}...".ljust(80, ' ') + "\r")
      next if s.id == 131072
      gold = MappackScore.gold_count(s.highscoreable_type, s.score_hs, s.score_sr)
      alert("Potentially incorrect hs score at #{s.id}") if !MappackScore.verify_gold(gold)
      s.update(gold: gold.round)
    }
  end
end
