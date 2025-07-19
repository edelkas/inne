# Track dates for the last speedruns notified in Discord
class AddSpeedrunTracking < ActiveRecord::Migration[5.1]
  def change
    ['new', 'verified', 'rejected'].each{ |status|
      Speedrun::GAMES.each{ |id, name|
        GlobalProperty.find_or_create_by(key: "last_#{status}_#{id}_speedrun")
                      .update(value: Time.now.to_s)
      }
    }
  end
end
