# New table to store Steam session authentication tickets. These tickets are
# generated using Steamwork's API and are linked to a user/app pair, and once
# validated by Steam they can be used to prove ownership of the app as well as
# authenticate. If we send it to N++'s server we enable requests for that account
# (i.e. we activate the Steam ID) for an hour. See the SteamTicket class for more info.
class AddSteamTickets < ActiveRecord::Migration[5.1]
  def change
    create_table :steam_tickets, id: :integer do |t|
      t.integer   :app_id
      t.integer   :steam_id, limit: 8
      t.binary    :ticket
      t.timestamp :date
    end
  end
end
