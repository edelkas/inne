source 'https://rubygems.org' do

  # Gems required to connect to Discord
  group :bot do
    gem 'discordrb', github: 'shardlab/discordrb', branch: 'main'
  end

  # Gems required to run the servers and connect to the database
  group :server do
    gem 'activerecord'
    gem 'mysql2'
    gem 'puma'
    gem 'rails'
    gem 'yaml_db'
  end

  # Gems for parsing or converting different formats
  group :data do
    gem 'damerau-levenshtein'
    gem 'html-to-markdown'
    gem 'nokogiri'
    gem 'rss'
    gem 'rubyzip'
    gem 'unicode-emoji'
  end

  # Gems for image manipulation
  group :imaging do
    gem 'chunky_png'
    gem 'gifenc', github: 'edelkas/gifenc', branch: 'master'
    gem 'gruff'
    gem 'matplotlib'
    gem 'octicons'
    gem 'oily_png', github: 'edelkas/oily_png', branch: 'dev'
    gem 'rexml'
    gem 'rmagick'
    gem 'svg-graph'
  end

  # Gems for providing "intellisense"
  group :development do
#    gem 'sorbet'
#    gem 'sorbet-runtime'
#    gem 'tapioca'
  end

  # Gems for debugging the code
  group :development, :debug do
    gem 'memory_profiler'
    gem 'pry-byebug'
  end

  # Gems for testing the code
  group :development, :test do
    gem 'database_cleaner'
    gem 'factory_bot'
    gem 'mocha'
    gem 'test-unit'
  end
end
