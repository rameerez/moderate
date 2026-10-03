# frozen_string_literal: true

# Test the minimum supported Rails version (matches the gemspec floor and the
# README's "Rails 7.1+ schema" claim — the adaptive migration must work here).
appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
  gem "json", "< 3" # json 3 dropped `quirks_mode:`, which ActiveRecord 7.1.6 still passes: "unknown keyword: quirks_mode" in db:migrate
end

appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
end

# Test the latest Rails version — this is the default/main Gemfile anyway.
appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end
