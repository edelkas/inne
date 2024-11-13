source 'https://rubygems.org' do
  gem 'ascii_charts'
  gem 'discordrb', github: 'shardlab/discordrb', branch: 'main'
  gem 'activerecord'
  gem 'yaml_db'
  gem 'rails'
  gem 'mysql2'
  gem 'damerau-levenshtein'
  gem 'rubyzip'
  gem 'unicode-emoji'
  gem 'webrick'

  group :imaging do
    gem 'rmagick'
    gem 'gruff'
    gem 'chunky_png'
    gem 'oily_png', github: 'edelkas/oily_png', branch: 'dev'
    gem 'gifenc', github: 'edelkas/gifenc', branch: 'master'
    gem 'matplotlib'
    gem 'rexml'
    gem 'svg-graph'
  end

  group :development do
#    gem 'sorbet'
#    gem 'sorbet-runtime'
#    gem 'tapioca'
  end

  group :development, :debug do
    gem 'pry-byebug'
    gem 'memory_profiler'
  end

  group :development, :test do
    gem 'test-unit'
    gem 'mocha'
    gem 'database_cleaner'
    gem 'factory_bot'
  end
end
