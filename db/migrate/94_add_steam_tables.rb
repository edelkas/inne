# Additional tables to store Steam data obtained via Steamworks API, mainly
# to monitor changes to N++'s app. We could use SteamDB but it doesn't provide
# an API and is less powerful than SteamKit anyway.
class AddSteamTables < ActiveRecord::Migration[5.1]
  def change
    create_table :steam_apps do |t|
      t.integer   :changenum
      t.string    :name
      t.binary    :sha, limit: 20
      t.timestamp :date
      t.string    :url
      t.string    :developer
      t.boolean   :free
      t.boolean   :os_win
      t.boolean   :os_linux
      t.boolean   :os_mac
    end

    create_table :steam_branches do |t|
      t.integer   :app_id
      t.string    :name
      t.text      :description
      t.integer   :build_id
      t.timestamp :updated
      t.boolean   :private
      t.boolean   :exists
    end

    create_table :steam_depots do |t|
      t.string  :name
      t.integer :app_id
      t.integer :max_size, limit: 8
      t.boolean :shared
      t.boolean :system
      t.boolean :os_win
      t.boolean :os_linux
      t.boolean :os_mac
      t.boolean :exists
    end

    create_table :steam_manifests do |t|
      t.integer   :depot_id
      t.string    :name
      t.integer   :count
      t.integer   :size_raw,        limit: 8
      t.integer   :size_compressed, limit: 8
      t.boolean   :compressed
      t.timestamp :date
    end

    create_table :steam_builds do |t|
      t.integer   :app_id
      t.string    :branch_name
      t.timestamp :date
    end

    create_table :steam_versions do |t|
      t.integer   :build_id
      t.integer   :depot_id
      t.integer   :manifest_id, limit: 8
      t.timestamp :date
    end

    create_table :steam_achievements do |t|
      t.integer :app_id
      t.string  :name
      t.string  :display
      t.text    :description
      t.boolean :hidden
      t.float   :ratio
    end
  end
end
