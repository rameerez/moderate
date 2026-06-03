# frozen_string_literal: true

require_relative "boot"

# Pull in ONLY the Rails frameworks the gem's test suite actually exercises,
# rather than `require "rails/all"`. A leaner boot is faster and makes the
# dependency surface explicit:
#   - active_record  : the four moderation models + the host User/Comment models
#   - active_storage  : the image-field (avatar) filtering tests attach a blob
#   - action_controller : the engine's public DSA notice form + the controller concern
#   - action_view     : renders the notice form view
#   - action_mailer   : the suite asserts on deliveries via ActionMailer::TestHelper
#   - active_job      : the async (:flag) classify path enqueues Moderate::ClassifyJob
# We deliberately SKIP action_cable / action_mailbox / action_text — nothing in the
# gem touches them, and loading them only slows the suite and widens the matrix's
# version surface.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"

# Load the gem under test. `Bundler.require` would also work, but requiring the
# entry point explicitly keeps the dummy honest about what it depends on and means
# the engine is loaded the same way a real host loads it.
require "moderate"

module Dummy
  # The minimal host application the engine mounts into. Everything here is the
  # smallest config that lets the suite boot across the Rails 7.1 / 7.2 / 8.1
  # matrix (see .github/workflows/test.yml) and across the sqlite/postgres/mysql
  # database matrix (see config/database.yml).
  class Application < Rails::Application
    # PIN THE APP ROOT EXPLICITLY to this dummy directory (test/dummy), not whatever
    # Rails guesses. Rails infers an application's root by walking up for markers like
    # a Gemfile/Rakefile/config.ru; from `rake test` (run at the GEM root) it would
    # otherwise guess the gem root, so `config/database.yml` resolves to
    # `<gem>/config/database.yml` (which doesn't exist) instead of
    # `test/dummy/config/database.yml`. That misfires the moment eager_load touches an
    # ActiveRecord model and the AR railtie reads the DB config — i.e. exactly when
    # `config.eager_load = true` (below) loads the gem's own models. Anchoring the
    # root here makes the suite pass regardless of the working directory it's run from.
    config.root = File.expand_path("..", __dir__)

    # Pin the framework defaults to the gemspec floor (Rails 7.1). The dummy must
    # boot identically on every Rails in the matrix, so we anchor to the LOWEST
    # supported version's defaults — newer Rails happily loads older defaults, and
    # this avoids a higher default silently enabling behavior 7.1 hosts won't have.
    config.load_defaults 7.1

    # The engine lives OUTSIDE the dummy's own app/ tree, so its app/ files are
    # autoloaded via the engine's own load paths (config.eager_load_paths in
    # Moderate::Engine). Nothing extra needed here — listing it documents intent.

    # Eager load in test so the whole gem (every model, service, controller,
    # adapter) is loaded up front: it surfaces autoload/NameError problems as a
    # boot failure instead of a mysterious mid-test error, and it's what CI's
    # eager-load pass would catch anyway.
    config.eager_load = true

    # Quiet, deterministic test output.
    config.consider_all_requests_local = true
    config.action_controller.perform_caching = false
    config.active_support.deprecation = :stderr

    # Don't dump schema.rb after migrating. CI drives the test DB with
    # `db:migrate:reset` (migrations, not schema.rb) precisely because a dumped
    # schema.rb carries SQLite-specific JSON/default quirks that fail to load on
    # PostgreSQL/MySQL (see .github/workflows/test.yml). Disabling the dump keeps the
    # migration the single source of truth for the schema across the DB matrix.
    config.active_record.dump_schema_after_migration = false

    # Run jobs inline so the async (:flag) classify path and any deliver_later in
    # the suite complete synchronously and are assertable without draining a queue.
    # (Tests that specifically want to assert enqueuing wrap blocks in
    # `perform_enqueued_jobs`/`assert_enqueued_with`, which still work with :test;
    # :test is the right adapter so both styles are available — switch per-test.)
    config.active_job.queue_adapter = :test

    # Active Storage uses the :test service (a tmp dir, see config/storage.yml) so
    # the avatar/image-field filtering tests can attach a blob without S3/network.
    config.active_storage.service = :test

    # A real cache store (not :null_store) so the notice controller's per-IP rate
    # limit can actually count in the rate-limit tests; :memory_store is process-
    # local and reset between runs, which is exactly what a test wants.
    config.cache_store = :memory_store

    # Host the engine's mailer assets/URLs deterministically for URL generation in
    # mailers and the notice receipt.
    config.action_mailer.default_url_options = { host: "example.com" }
    config.action_mailer.delivery_method = :test

    # Secret base for cookies / signed GlobalIDs (the appeal & confirm-notice
    # signed links). A fixed value keeps signed tokens stable within a run.
    config.secret_key_base = "moderate_dummy_secret_key_base_for_tests_only"
  end
end
