# frozen_string_literal: true

# Test the oldest supported Rails line (the gemspec floor is 8.0.5.1; this resolves to
# the newest 8.0 patch, which is what a maintained 8.0 host runs — the adaptive
# migration must work here).
appraise "rails-8.0" do
  gem "rails", "~> 8.0.5", ">= 8.0.5.1"
  # Rails 8.0's ActiveSupport::JSON still passes `quirks_mode:` to JSON.generate /
  # JSON.parse, which json 3 rejects (ArgumentError on the first JSON column write);
  # 8.1 no longer passes it. A host on 8.0 needs the same pin. Stay on the
  # maintained 2.x line; 2.19.9+ carries the GHSA-x2f5-4prf-w687 fix.
  gem "json", ">= 2.19.9", "< 3"
end

# Test the latest Rails version — this is the default/main Gemfile anyway.
appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end
