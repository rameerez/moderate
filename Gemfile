# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are specified in moderate.gemspec
gemspec

# Build & release tools
gem "rake", "~> 13.0"

group :development do
  gem "appraisal"
  gem "web-console"

  # Code quality
  gem "standard"
  gem "rubocop", "~> 1.0"
  gem "rubocop-minitest", "~> 0.35"
  gem "rubocop-performance", "~> 1.0"
end

group :test do
  gem "minitest", "~> 5.0"
  gem "mocha"
  gem "simplecov", require: false

  # Database adapters (for multi-database testing)
  gem "sqlite3"
  gem "pg"
  gem "mysql2"

  # Dummy Rails app
  gem "bootsnap", require: false
  gem "puma"
  gem "importmap-rails"
  gem "sprockets-rails"
  gem "stimulus-rails"
  gem "turbo-rails"

  # Fix RDoc version conflict (Ruby 3.4+ ships with 7.0.3)
  gem "rdoc", ">= 7.0"
end
