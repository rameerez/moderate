# frozen_string_literal: true

# SimpleCov configuration file (auto-loaded before test suite)
# This keeps test_helper.rb clean and follows best practices.
# Coherent with the rest of the gem ecosystem (usage_credits, pricing_plans, …).

SimpleCov.start do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Don't count the test suite itself toward coverage
  add_filter "/test/"

  # Track Ruby files in the lib directory (gem source code)
  track_files "lib/**/*.rb"

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # Minimum coverage thresholds to prevent coverage regression
  minimum_coverage line: 80, branch: 75

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
