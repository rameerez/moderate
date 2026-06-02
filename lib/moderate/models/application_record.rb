# frozen_string_literal: true

module Moderate
  # The abstract base class every model the gem ships inherits from
  # (Moderate::Report / Block / Flag / Appeal). It plays the exact role an engine's
  # `app/models/<engine>/application_record.rb` normally plays:
  #
  #   - It is `abstract_class`, so it never maps to a table of its own; it only
  #     exists to give the gem's records a single, gem-owned ancestor.
  #
  #   - It inherits from the HOST's `::ActiveRecord::Base`, NOT from the host's
  #     `::ApplicationRecord`. That matters: the gem must not pick up host
  #     concerns/defaults bolted onto the app's ApplicationRecord (multitenancy
  #     scopes, default associations, etc.) — its tables are infrastructure, owned
  #     by the gem, and should behave identically in every host. (This is why the
  #     dummy's own `ApplicationRecord` doc note says the gem's models inherit from
  #     `Moderate::ApplicationRecord`, not from the host base.)
  #
  # WHY this class has to exist as a separate file (and isn't just `ActiveRecord::Base`
  # inline in each model): the gem's models are written as `class Report <
  # ApplicationRecord` *inside* `module Moderate`. Ruby constant lookup resolves the
  # bare `ApplicationRecord` to `Moderate::ApplicationRecord` first (the lexically
  # enclosing namespace), and Zeitwerk autoloads it from this file. Defining it here
  # — rather than letting the lookup fall through to the host's top-level
  # `::ApplicationRecord` — keeps the gem's base independent of the host's, which is
  # the whole point. The reference to `::ActiveRecord::Base` is fully qualified so it
  # can never be re-bound to a `Moderate::ActiveRecord` by the same lookup quirk.
  class ApplicationRecord < ::ActiveRecord::Base
    self.abstract_class = true
  end
end
