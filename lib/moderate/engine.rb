# frozen_string_literal: true

require "rails/engine"

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
    #      can't be both manually required and autoloaded). The 0.x compatibility
    #      shims (`text`, `text_validator`, `word_list`) are ignored too: they either
    #      define non-conventional constants (`text_validator.rb` reopens
    #      `ActiveModel::Validations`, not a `Moderate::*` constant) or are legacy and
    #      loaded only on demand.
    #
    # We do this on the host's MAIN autoloader (`Rails.autoloaders.main`) inside an
    # initializer scheduled BEFORE `:set_autoload_paths`, the same point Rails wires
    # up its own roots — so our `push_dir`/`collapse`/`ignore` are in place before
    # Zeitwerk's `setup`/`eager_load` ever run.
    LIB_ROOT = File.expand_path("..", __dir__) # => .../lib
    MODERATE_LIB = File.expand_path("moderate", LIB_ROOT) # => .../lib/moderate

    # Spine + 0.x-compat files Zeitwerk must NOT manage (they're require_relative'd
    # from the spine or define non-conventional constants).
    ZEITWERK_IGNORED = %w[
      version.rb errors.rb label.rb result.rb event.rb
      configuration.rb engine.rb macros.rb
      text.rb text_validator.rb word_list.rb
    ].freeze

    initializer "moderate.autoload", before: :set_autoload_paths do
      loader = Rails.autoloaders.main

      # ACRONYM INFLECTION. Zeitwerk derives the expected constant from the file name
      # by camelizing it, so `openai.rb` → `Openai`. The adapter class is spelled
      # `Moderate::Filters::OpenAI` (the brand's own capitalization, and what the
      # `Moderate::Adapters::OpenAI` alias and the README examples use), so we teach
      # the inflector the override or Zeitwerk raises "expected file … to define
      # constant Moderate::Filters::Openai". (Same mechanism Rails uses for `api` →
      # `API`; see https://github.com/fxn/zeitwerk#inflection.)
      loader.inflector.inflect("openai" => "OpenAI")

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

    # Make the host's migrations:install task pick up the gem's migration template
    # location, and ensure the gem's own migration directory is on the path. The
    # primary install path is still `rails generate moderate:install` (which copies
    # the adaptive migration into the host's db/migrate); appending the path here is
    # belt-and-suspenders so engine-style `moderate:install:migrations` also works.
    initializer "moderate.migrations" do |app|
      unless app.root.to_s == root.to_s
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path
        end
      end
    end

    # Register the model macros on ActiveRecord, the canonical Rails way.
    #
    # `ActiveSupport.on_load(:active_record)` defers until ActiveRecord::Base is
    # actually defined, so we never force-load AR at boot and we play nicely with
    # the host's load order. Once it fires, every model gains `has_moderation`,
    # `reportable`, and `moderates` as class methods (the macros that lazily
    # include Moderate::Actor / Moderate::Reportable / Moderate::ContentFilterable).
    #
    # `Moderate::Macros` is require_relative'd by the spine, so the constant resolves
    # the instant this hook fires.
    initializer "moderate.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend Moderate::Macros
      end
    end

    # Surface the gem's I18n files (filter validation messages, the DSA taxonomy
    # labels, the notice-form copy) to the host's I18n load path. The locale files
    # ship under the engine's conventional config/locales (provided by other
    # components); listing the glob here is harmless if none exist yet.
    initializer "moderate.locales" do |app|
      app.config.i18n.load_path += Dir[root.join("config", "locales", "**", "*.{rb,yml}").to_s]
    end
  end
end
