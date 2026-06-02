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

  # Rails frameworks the dummy app boots that are NOT runtime dependencies of the
  # gem itself. The gemspec only depends on the pieces moderate actually needs at
  # runtime (activerecord/activesupport/railties/globalid); ActiveJob (the async
  # :flag classify path), ActionMailer (the suite asserts on deliveries), and
  # ActiveStorage (the image-field/avatar filtering tests attach a blob) are
  # OPTIONAL integrations the host wires through hooks — so they belong in the test
  # bundle, not the gemspec. railties pulls in actionpack/actionview (the engine's
  # notice form + controller concern), but these three frameworks are standalone
  # gems Bundler won't install transitively, so the dummy can't `require` their
  # railties without them being declared here.
  gem "activejob"
  gem "actionmailer"
  gem "activestorage"

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
