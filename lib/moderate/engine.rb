# frozen_string_literal: true

require "rails/engine"
require_relative "text_validator" # `validates :field, moderate: true` (0.x)

module Moderate
  # The Rails engine that wires `moderate` into a host app.
  #
  # It's an ISOLATED engine (`isolate_namespace Moderate`) for the same reason
  # Devise's is: the gem ships a mountable public DSA notice form
  # (`mount Moderate::Engine => "/legal"`, see docs/dsa-notice-form.md) with its
  # own controllers, views, helpers, and `moderate_`-prefixed tables. Isolation
  # keeps every one of those from colliding with the host app's namespace, and
  # gives the host the `moderate.` URL-helper proxy for the mounted routes.
  #
  # NOTE: the engine is intentionally thin. The host can use the whole gem
  # (reporting, blocking, filtering, the queue) WITHOUT mounting anything — the
  # mount is only needed for the public Art. 16 notice form. Everything here is
  # plumbing that runs whether or not the engine is mounted.
  class Engine < ::Rails::Engine
    isolate_namespace Moderate

    # The autoloadable code that needs the host's ActiveRecord/ApplicationRecord and
    # the host's `config.user_class` to exist before it loads — the four AR models,
    # the three model concerns, the async classify job, the filter adapters, and the
    # service objects — lives under `lib/moderate/{models,jobs,filters,services}`,
    # NOT under the engine's `app/` tree. That's a deliberate gem-packaging choice
    # (everything ships under `lib/`), but it means we have to teach the host's
    # Zeitwerk loader about that subtree ourselves, with three corrections:
    #
    #   1. NAMESPACE. A bare `eager_load_paths << ".../lib/moderate"` would map the
    #      directory to the TOP-LEVEL namespace, so Zeitwerk would expect
    #      `lib/moderate/configuration.rb` to define `::Configuration` (not
    #      `Moderate::Configuration`) and blow up with "uninitialized constant
    #      Configuration" during eager load. We push the dir mapped to the `Moderate`
    #      module instead, so `lib/moderate/models/report.rb` → `Moderate::Report`.
    #      (Zeitwerk's `push_dir(path, namespace:)` is exactly for this — see
    #      https://github.com/fxn/zeitwerk#custom-root-namespaces.)
    #
    #   2. COLLAPSED DIRECTORIES. `models/`, `models/concerns/`, and `jobs/` are
    #      organizational, not namespace, segments — `report.rb` must be
    #      `Moderate::Report`, NOT `Moderate::Models::Report`; `actor.rb` must be
    #      `Moderate::Actor`, not `Moderate::Models::Concerns::Actor`. We `collapse`
    #      them so they contribute no namespace. (`services/` and `filters/` are
    #      KEPT, because the code intentionally namespaces `Moderate::Services::*`
    #      and `Moderate::Filters::*`.)
    #
    #   3. IGNORED FILES. The gem's SPINE (`version`, `errors`, `label`, `result`,
    #      `event`, `configuration`, `engine`, `macros`) is `require_relative`'d from
    #      `lib/moderate.rb` so the value objects work in a plain-Ruby context with
    #      no Rails — those files MUST NOT also be managed by Zeitwerk (a constant
    #      can't be both manually required and autoloaded). The 0.x validator
    #      (`text_validator`) is ignored too: it reopens `ActiveModel::Validations`,
    #      not a `Moderate::*` constant, and this file requires it.
    #
    # We do this on the host's MAIN autoloader (`Rails.autoloaders.main`) inside an
    # initializer scheduled BEFORE `:set_autoload_paths`, the same point Rails wires
    # up its own roots — so our `push_dir`/`collapse`/`ignore` are in place before
    # Zeitwerk's `setup`/`eager_load` ever run.
    LIB_ROOT = File.expand_path("..", __dir__) # => .../lib
    MODERATE_LIB = File.expand_path("moderate", LIB_ROOT) # => .../lib/moderate

    # Spine files and the 0.x validator: Zeitwerk must NOT manage them (they're
    # require_relative'd, and the validator defines a non-Moderate constant).
    ZEITWERK_IGNORED = %w[
      version.rb errors.rb label.rb result.rb event.rb
      configuration.rb engine.rb macros.rb text_validator.rb
    ].freeze
    private_constant :LIB_ROOT, :MODERATE_LIB, :ZEITWERK_IGNORED

    initializer "moderate.autoload", before: :set_autoload_paths do
      loader = Rails.autoloaders.main

      # Files the spine already requires (or that define top-level constants) — tell
      # Zeitwerk to leave them alone so it doesn't try to (re)manage their constants.
      ZEITWERK_IGNORED.each do |file|
        path = File.join(MODERATE_LIB, file)
        loader.ignore(path) if File.exist?(path)
      end

      # `models`, `models/concerns`, and `jobs` are organizational dirs that must not
      # appear in the constant path (Moderate::Report, not Moderate::Models::Report).
      %w[models models/concerns jobs].each do |dir|
        path = File.join(MODERATE_LIB, dir)
        loader.collapse(path) if File.directory?(path)
      end

      # Push lib/moderate as an autoload root mapped to the Moderate namespace, so
      # lib/moderate/foo.rb → Moderate::Foo (and, with the collapses above,
      # lib/moderate/models/report.rb → Moderate::Report).
      loader.push_dir(MODERATE_LIB, namespace: Moderate)
    end

    # Eager-load the same subtree in production (and in the test suite, which sets
    # `config.eager_load = true`) so autoload/NameError problems surface as a boot
    # failure rather than a mid-request error. `push_dir` above already makes it
    # autoloadable; adding it to eager_load_paths makes the boot-time pass cover it.
    config.eager_load_paths << MODERATE_LIB

    # The gem's own migrations (db/migrate, e.g. beta4's pending_key) and how an app
    # gets them. The tables come from `rails generate moderate:install`, which writes
    # the adaptive create migration and then COPIES the gem's migrations after it
    # (*.moderate.rb), so a fresh app runs both, in order. An app installed before it
    # copied them (beta3) holds no copies: this appends the gem's db/migrate to its
    # migration paths, so it runs only what it lacks.
    #
    # Not appended when the same migrations would then be found twice (Active Record
    # raises DuplicateMigrationNameError):
    #   - under the gem's own Rakefile (ENGINE_ROOT is this engine), where Rails' engine
    #     tasks already add the engine's db/migrate;
    #   - when the app holds copies (*.moderate.rb, from moderate:install or
    #     `bin/rails moderate:install:migrations`): the copies run instead, and a later
    #     release's migrations arrive with `bin/rails moderate:install:migrations`.
    initializer "moderate.migrations" do |app|
      next if app.root.to_s == root.to_s
      next if defined?(ENGINE_ROOT) && ENGINE_ROOT.to_s == root.to_s

      Engine.migration_paths_for(app.config.paths["db/migrate"].expanded).each do |path|
        app.config.paths["db/migrate"] << path
      end
    end

    # The gem's migration directories an app with `host_dirs` as its own should add.
    def self.migration_paths_for(host_dirs)
      return [] if host_dirs.any? { |dir| Dir.glob(File.join(dir, "*.moderate.rb")).any? }

      config.paths["db/migrate"].expanded - host_dirs
    end

    # An app that holds copies of the gem's migrations runs only those (see above), so
    # a copy missed after an upgrade would never run, silently. At boot, compare the
    # copies with the gem's migrations by name; when one is missing, raise (or log,
    # per `config.migration_copies_check`), naming it and the command that copies it.
    config.after_initialize do |app|
      next if app.root.to_s == Engine.root.to_s

      Engine.check_migration_copies!(app.config.paths["db/migrate"].expanded)
    end

    # The gem's migrations (by name) an app holding copies has no copy of; [] for an
    # app without copies, which gets the gem's own path instead.
    def self.missing_migration_copies(host_dirs)
      copies = host_dirs.flat_map { |dir| Dir.glob(File.join(dir, "*.moderate.rb")) }
      return [] if copies.empty?

      copied = copies.map { |file| File.basename(file, ".moderate.rb").split("_", 2).last }
      gem_migrations = Dir[root.join("db/migrate/[0-9]*_*.rb").to_s].map { |file| File.basename(file, ".rb").split("_", 2).last }
      gem_migrations - copied
    end

    def self.check_migration_copies!(host_dirs, mode: Moderate.config.migration_copies_check)
      return if mode == :off

      missing = missing_migration_copies(host_dirs)
      return if missing.empty?

      message = "moderate: your app holds copies of moderate's migrations (*.moderate.rb) but none of " \
                "#{missing.join(", ")}, which this version of moderate needs. Run `bin/rails " \
                "moderate:install:migrations`, then `bin/rails db:migrate`."
      # Under a rake task (the very command that copies them, or db:migrate) log
      # instead: raising there would make the fix impossible to run.
      raise Moderate::ConfigurationError, message if mode == :raise && !running_rake_task?

      Rails.logger&.error(message)
      warn(message)
    end

    def self.running_rake_task?
      defined?(::Rake.application) && ::Rake.application.top_level_tasks.any?
    end

    # Register the model macros on ActiveRecord, the canonical Rails way.
    #
    # `ActiveSupport.on_load(:active_record)` defers until ActiveRecord::Base is
    # actually defined, so we never force-load AR at boot and we play nicely with
    # the host's load order. Once it fires, every model gains `has_reporting_and_blocking`,
    # `has_reportable_content`, and `moderates` as class methods (the macros that lazily
    # include Moderate::Actor / Moderate::Reportable / Moderate::ContentFilterable).
    #
    # `Moderate::Macros` is require_relative'd by the spine, so the constant resolves
    # the instant this hook fires.
    initializer "moderate.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend Moderate::Macros
      end
    end

    # The gem's I18n files (config/locales/*.yml — default copy and the generic
    # reportable-field labels) need NO initializer: every Rails::Engine registers
    # its `config/locales/**/*.{rb,yml}` in `config.i18n.railties_load_path`, which
    # Rails puts AHEAD of the host app's own locale files — so a host translation
    # of any `moderate.*` key overrides ours, as it must.
    #
    # Do NOT also append them to `app.config.i18n.load_path` (an earlier version
    # did, while the directory was still empty): that list is loaded AFTER the
    # host's files, so the gem's defaults would silently clobber the host's
    # translations. test/integration/locale_precedence_test.rb pins this.
  end
end
