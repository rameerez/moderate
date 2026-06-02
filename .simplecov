# frozen_string_literal: true

# SimpleCov configuration file (auto-loaded before test suite)
# This keeps test_helper.rb clean and follows best practices.
# Coherent with the rest of the gem ecosystem (usage_credits, pricing_plans, …).

SimpleCov.start do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Don't count the test suite itself toward coverage
  add_filter "/test/"

  # Don't count code that ISN'T unit-testable by this suite and would only distort
  # the numbers:
  #   - Generators + their templates: these run via `rails generate moderate:install`
  #     / `moderate:views` in a real host, not in the engine's own unit suite. (The
  #     migration template IS exercised indirectly — the dummy migrates a copy of it —
  #     but the .erb itself is never loaded as Ruby here.)
  #   - version.rb: a single constant; nothing to cover.
  #   - The 0.x compatibility shims (text / text_validator / word_list): legacy
  #     profanity-validator code kept only so `validates :field, moderate: true` from
  #     0.x still loads (see README "Upgrading from 0.x"). They are NOT part of the
  #     1.0 Trust & Safety surface this suite tests, so they shouldn't pull the 1.0
  #     coverage number down.
  add_filter "/lib/generators/"
  add_filter "/lib/moderate/version.rb"
  add_filter "/lib/moderate/text.rb"
  add_filter "/lib/moderate/text_validator.rb"
  add_filter "/lib/moderate/word_list.rb"

  # Track Ruby files in the lib directory (gem source code)
  track_files "lib/**/*.rb"

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # Minimum coverage thresholds to prevent coverage REGRESSION. These reflect what
  # the current shipped suite actually exercises (line ~86%, branch ~65%): the
  # primitives — models, concerns, services, adapters, the facade, the value objects —
  # are thoroughly covered; the lower branch number is driven by the engine's
  # CONTROLLERS (the public DSA notice form + the BYOUI moderation concern) and the
  # async ClassifyJob, whose request/job paths the unit suite doesn't drive. The
  # thresholds sit just under the current floor so the gate catches a real regression
  # without failing on the existing baseline; raise them as request/job coverage grows.
  minimum_coverage line: 80, branch: 60

  # Disambiguate parallel test runs
  command_name "Job #{ENV['TEST_ENV_NUMBER']}" if ENV["TEST_ENV_NUMBER"]
end

# Print coverage summary to terminal after tests complete
SimpleCov.at_exit do
  SimpleCov.result.format!
  puts "\n" + "=" * 60
  puts "COVERAGE SUMMARY"
  puts "=" * 60
  puts "Line Coverage:   #{SimpleCov.result.covered_percent.round(2)}%"
  branch_coverage = SimpleCov.result.coverage_statistics[:branch]&.percent&.round(2) || "N/A"
  puts "Branch Coverage: #{branch_coverage}%"
  puts "=" * 60
end
