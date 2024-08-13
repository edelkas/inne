# Store cheated runs in the db for archival and reference, appropriately flagged
class ArchiveCheatedScores < ActiveRecord::Migration[7.1]
  def change
    add_column :archives, :cheated, :boolean, default: false
  end
end
