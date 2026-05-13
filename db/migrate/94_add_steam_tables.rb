# Additional tables to store Steam data obtained via Steamworks API, mainly
# to monitor changes to N++'s app. We could use SteamDB but it doesn't provide
# an API and is less powerful than SteamKit anyway. We use it for seeding the
# inintial data though.

require "./#{DIR_SOURCE}/api.rb"
require 'zlib'

class AddSteamTables < ActiveRecord::Migration[5.1]
  def up
    create_table :steam_apps do |t|
      t.integer   :changenum
      t.string    :name
      t.binary    :sha, limit: 20
      t.timestamp :date
      t.string    :url
      t.string    :developer
      t.boolean   :free
      t.boolean   :os_win,   default: false
      t.boolean   :os_linux, default: false
      t.boolean   :os_mac,   default: false
    end

    create_table :steam_branches do |t|
      t.integer   :app_id
      t.string    :name
      t.text      :description
      t.integer   :official_id
      t.timestamp :created
      t.timestamp :updated
      t.timestamp :deleted
      t.boolean   :private, default: false
    end

    create_table :steam_depots do |t|
      t.string    :name
      t.integer   :app_id
      t.integer   :max_size, limit: 8
      t.boolean   :shared,   default: false
      t.boolean   :system,   default: false
      t.boolean   :os_win,   default: false
      t.boolean   :os_linux, default: false
      t.boolean   :os_mac,   default: false
      t.timestamp :added
      t.timestamp :removed
    end

    create_table :steam_manifests do |t|
      t.integer   :gid,             limit: 8  # For public manifests
      t.binary    :encrypted_gid,   limit: 16 # For private manifests
      t.integer   :depot_id
      t.string    :name
      t.integer   :count
      t.integer   :size_raw,        limit: 8
      t.integer   :size_compressed, limit: 8
      t.timestamp :date
    end

    create_table :steam_builds do |t|
      t.integer   :app_id
      t.binary    :md5
    end

    create_table :steam_build_contents do |t|
      t.integer :build_id
      t.integer :depot_id
      t.integer :manifest_id
    end

    create_table :steam_branch_versions do |t|
      t.integer   :branch_id
      t.integer   :build_id
      t.integer   :official_id
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

    # Seed initial data from SteamDB's history page. The rest will be fetched and kept up to date later.
    SteamApp.create(id: APP_ID)
    SteamDB.seed_updates(Zlib.inflate(File.read('db/steamdb_history.deflate')))
  end

  def down
    drop_table :steam_apps
    drop_table :steam_branches
    drop_table :steam_depots
    drop_table :steam_manifests
    drop_table :steam_builds
    drop_table :steam_build_contents
    drop_table :steam_branch_versions
    drop_table :steam_achievements
  end
end
