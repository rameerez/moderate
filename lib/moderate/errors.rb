# frozen_string_literal: true

module Moderate
  # Base class for every error this gem raises. Host apps can rescue
  # `Moderate::Error` to catch anything the gem throws without coupling to a
  # specific subclass.
  #
  # NOTE: 0.x already defined `Moderate::Error` (a bare StandardError used by the
  # profanity word-list downloader). We keep the exact same constant so any host
  # code that rescued it on the old gem keeps working — see "Upgrading from 0.x"
  # in the README. The class is just re-homed here in 1.0.
  class Error < StandardError; end

  # Raised by `Configuration#validate!` (called at the end of `Moderate.configure`)
  # when the initializer block contains a bad value — an unknown filter mode, an
  # unregistered adapter name, a blank `user_class`, etc.
  #
  # We deliberately *also* raise plain `ArgumentError` from the validating setters
  # themselves (per docs/configuration.md: "raises a plain-English ArgumentError
  # immediately"), so a typo fails fast at the assignment line. `ConfigurationError`
  # exists for the cases where validation can only run once the whole block is
  # known (e.g. a `:block`-mode filter pointed at an async adapter, which needs
  # both the mode and the adapter resolved together). It subclasses `Error` so a
  # blanket `rescue Moderate::Error` still catches it.
  class ConfigurationError < Error; end
end
