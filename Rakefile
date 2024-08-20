require 'active_record'
require 'database_cleaner'
require 'factory_bot'
require 'rails'
require 'yaml'
require 'yaml_db'

require_relative 'src/constants.rb'
require_relative 'src/models.rb'
require_relative 'src/messages.rb'
require_relative 'src/utils.rb'

# Supress warnings, too spammy in migrations!
$VERBOSE = nil

module Rails
  def Rails.env
    DATABASE_ENV
  end
end

namespace :db do
  desc "Sets database environment and migrations directory"
  task :environment do
    DATABASE_ENV = ENV['DATABASE_ENV'] || DATABASE
    MIGRATIONS_DIR = ENV['MIGRATIONS_DIR'] || DIR_MIGRATION
  end

  desc "Loads database connection configuration from YAML file"
  task :configuration => :environment do
    @config = YAML.load_file(CONFIG)[DATABASE_ENV]
  end

  desc "Establish connection with database using YAML configuration"
  task :configure_connection => :configuration do
    ActiveRecord::Base.establish_connection(@config)
  end

  desc "Alias for 'configure_connection'"
  task :create => :configure_connection do
    ActiveRecord::Base.establish_connection(@config)
  end

  desc "Deletes the database"
  task :drop => :configure_connection do
    ActiveRecord::Base.connection.drop_database(@config['database'])
  end

  desc "Execute new migrations"
  task :migrate => :configure_connection do
    require_relative "#{DIR_SOURCE}/models.rb"
    version = ENV['MIGRATION_VERSION'] ? ENV['MIGRATION_VERSION'].to_i : ENV['VERSION'] ? ENV['VERSION'].to_i : nil
    if rails_at_most('5.2.0')
      ActiveRecord::Migrator.migrate(MIGRATIONS_DIR, version)
    else
      ActiveRecord::MigrationContext.new(MIGRATIONS_DIR).migrate(version)
    end
  end

  desc "Rollback latest migration, or a fixed number of them"
  task :rollback => :configure_connection do
    if rails_at_most('5.2.0')
      ActiveRecord::Migrator.rollback(MIGRATIONS_DIR, (ENV['STEP'] || 1).to_i)
    else
      ActiveRecord::MigrationContext.new(MIGRATIONS_DIR).rollback((ENV['STEP'] || 1).to_i)
    end
  end

  desc "Seed database with initial records stored in seeds.rb"
  task :seed => :configure_connection do
    require_relative "#{DIR_SOURCE}/models.rb"
    require_relative "#{DIR_DB}/seeds.rb"
  end

  desc "Run tests"
  task :test => :configure_connection do
    require "#{DIR_TEST}/unit"
    require "#{DIR_TEST}/unit/ui/console/testrunner"
    require 'mocha/test_unit'

    class Test::Unit::TestCase
      include FactoryBot::Syntax::Methods
    end

    FactoryBot.find_definitions

    require_relative "#{DIR_TEST}/test_models.rb"
    require_relative "#{DIR_TEST}/test_messages.rb"

    DatabaseCleaner.strategy = :transaction

    [TestScores, TestRankings, TestMessages].each do |suite|
      Test::Unit::UI::Console::TestRunner.run(suite)
    end
  end

  desc "Dump schema and data to db/schema.rb and db/data.yml"
  task(:dump => [ "db:schema:dump", "db:data:dump" ])

  desc "Load schema and data from db/schema.rb and db/data.yml"
  task(:load => [ "db:schema:load", "db:data:load" ])

  namespace :data do
    desc "Dump contents of database to db/data.extension (defaults to yaml)"
    task :dump => :environment do
      YamlDb::RakeTasks.data_dump_task
    end

    desc "Dump contents of database to curr_dir_name/tablename.extension (defaults to yaml)"
    task :dump_dir => :environment do
      YamlDb::RakeTasks.data_dump_dir_task
    end

    desc "Load contents of db/data.extension (defaults to yaml) into database"
    task :load => [:environment, :configure_connection] do
      YamlDb::RakeTasks.data_load_task
    end

    desc "Load contents of db/data_dir into database"
    task :load_dir  => :environment do
      YamlDb::RakeTasks.data_load_dir_task
    end
  end

  namespace :schema do
    desc "Creates a db/schema.rb file that is portable against any DB supported by Active Record"
    task dump: [:environment, :configure_connection] do
      require "active_record/schema_dumper"
      filename = ENV["SCHEMA"] || File.join(ActiveRecord::Tasks::DatabaseTasks.db_dir, "schema.rb")
      File.open(filename, "w:utf-8") do |file|
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, file)
      end
      # db_namespace["schema:dump"].reenable
    end

    desc "Loads a schema.rb file into the database"
    task load: [:environment, :configure_connection] do
      ActiveRecord::Tasks::DatabaseTasks.load_schema_current(:ruby, ENV["SCHEMA"])
    end
  end
end
