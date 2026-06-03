# frozen_string_literal: true

# SimpleCov must be loaded before any application code
require "simplecov"

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require File.expand_path("dummy/config/environment.rb", __dir__)
ActiveRecord::Migrator.migrations_paths = [
  File.expand_path("dummy/db/migrate", __dir__),
  File.expand_path("../db/migrate", __dir__)
]
require "rails/test_help"
require "minitest/mock"
require "mocha/minitest"

# Filter out Minitest backtrace while allowing backtrace from other libraries
# to be shown.
Minitest.backtrace_filter = Minitest::BacktraceFilter.new

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths << File.expand_path("fixtures", __dir__)
  ActionDispatch::IntegrationTest.fixture_paths << File.expand_path("fixtures", __dir__)
elsif ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_path = File.expand_path("fixtures", __dir__)
  ActionDispatch::IntegrationTest.fixture_path = ActiveSupport::TestCase.fixture_path
end

ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures/files", __dir__)
ActiveSupport::TestCase.fixtures :all

class ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  setup do
    # Start every test from a known configuration so hook/callback state
    # (audit, notify, on_block, ban_handler) never leaks between tests.
    Moderate.reset!
    Moderate.configure do |config|
      config.user_class = "User"
    end
  end

  teardown do
    Moderate.reset!
  end

  # Quickly file a report for assertions.
  def report!(reporter, content, category: :harassment, **opts)
    reporter.report!(content, category: category, **opts)
  end

  # Quickly create a block edge for assertions.
  def block!(blocker, blocked)
    blocker.block!(blocked)
  end
end
