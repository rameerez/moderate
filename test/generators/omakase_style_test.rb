# frozen_string_literal: true

require "test_helper"
require "generators/moderate/install_generator"

module Moderate
  # The migrations an app receives — written by `rails generate moderate:install`, or
  # copied by `bin/rails moderate:install:migrations` (Rails' own copy) — pass RuboCop
  # with rubocop-rails-omakase, the style a new Rails app enforces, so a host needs no
  # exclude for them. The generated initializer too.
  class OmakaseStyleTest < Rails::Generators::TestCase
    tests Moderate::Generators::InstallGenerator
    destination Rails.root.join("tmp/omakase")
    setup :prepare_destination

    setup do
      require "rubocop"
    rescue LoadError
      skip "rubocop isn't in this bundle"
    end

    test "the install generator's migrations and initializer pass omakase" do
      run_generator

      assert_omakase Dir[File.join(destination_root, "{db/migrate,config/initializers}/*.rb")]
    end

    test "the copies bin/rails moderate:install:migrations writes pass omakase" do
      dir = File.join(destination_root, "copied")
      FileUtils.mkdir_p(dir)
      ActiveRecord::Migration.copy(dir, { "moderate" => Moderate::Engine.root.join("db/migrate").to_s })

      assert_omakase Dir[File.join(dir, "*.rb")]
    end

    private

    def assert_omakase(files)
      assert_not_empty files
      config = File.join(destination_root, ".rubocop.yml")
      File.write(config, "inherit_gem:\n  rubocop-rails-omakase: rubocop.yml\n")
      output, = capture_io do
        @status = RuboCop::CLI.new.run(["--config", config, "--cache", "false", "--format", "simple", *files])
      end

      assert_equal 0, @status, output
    end
  end
end
