# frozen_string_literal: true

# Test the minimum supported Rails version (matches the gemspec floor and the
# README's "Rails 7.1+ schema" claim — the adaptive migration must work here).
appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
  # Rails 7.1 (EOL) still passes `quirks_mode:` to JSON.generate/parse, which
  # json 3.1 rejects (ArgumentError on the first JSON column write); Rails 7.2+
  # no longer passes it. Stay on the maintained 2.x line; 2.19.9+ carries the
  # GHSA-x2f5-4prf-w687 fix.
  gem "json", ">= 2.19.9", "< 3"
end

appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
end

# Test the latest Rails version — this is the default/main Gemfile anyway.
appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end
