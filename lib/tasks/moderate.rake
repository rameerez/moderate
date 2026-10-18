# frozen_string_literal: true

# Loaded into the host's `bin/rails -T` by Moderate::Engine (every engine loads
# its lib/tasks/**/*.rake).
namespace :moderate do
  desc "Redact personal data from moderation records decided more than OLDER_THAN_DAYS " \
       "(default 365, at least the 6-month appeal window) ago. DRY_RUN=1 only counts. " \
       "See docs/compliance.md#retention."
  task purge: :environment do
    days = ENV.fetch("OLDER_THAN_DAYS", "365")
    raise ArgumentError, "OLDER_THAN_DAYS must be a whole number of days, got #{days.inspect}" unless days.match?(/\A\d+\z/)

    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)
    counts = Moderate.purge(older_than: days.to_i.days, dry_run: dry_run)
    verb = dry_run ? "would redact" : "redacted"
    held = counts[:held]
    puts "moderate:purge #{verb} #{counts[:reports]} reports, #{counts[:flags]} flags, " \
         "#{counts[:appeals]} appeals decided more than #{days} days ago, " \
         "#{dry_run ? "would delete" : "deleted"} #{counts[:classifications]} classification rows; kept for a legal hold: " \
         "#{held[:reports]} reports, #{held[:flags]} flags, #{held[:appeals]} appeals"
  end
end
