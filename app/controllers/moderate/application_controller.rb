# frozen_string_literal: true

module Moderate
  # Base controller for the engine's OWN controllers (today: the public DSA notice
  # form). It is NOT used by the host's in-app report/admin controllers — those are
  # BYOUI and inherit from the host's own ApplicationController.
  #
  # The parent class is INDIRECTED through `config.parent_controller`
  # (default `"::ActionController::Base"`), exactly the `config.parent_controller`
  # trick Devise and `api_keys` use. Why indirect instead of just inheriting from
  # `ActionController::Base`?
  #   - On an API-only app there is no `ActionController::Base` view stack by
  #     default; defaulting to it (and pulling in the view modules below) keeps the
  #     HTML notice form working even there.
  #   - A host that wants the public forms to sit inside its own site chrome points
  #     `config.parent_controller` at its own base controller and inherits
  #     its layout, locale-setting, current_user, etc. — without us hard-coding any
  #     of that.
  #
  # We resolve the parent at class-definition time via `Class.new(...)` + a
  # `const_set`-free `superclass` trick: Ruby can't change a class's superclass
  # after definition, so we constantize the configured name HERE, on first load of
  # this file. The configured value is a STRING constantized lazily, consistent with
  # the rest of the gem's "store class names as strings" rule.
  parent = begin
    Moderate.config.parent_controller.to_s.constantize
  rescue NameError
    # Defensive fallback: if the configured parent isn't loadable (typo, or an
    # API-only app without ActionController::Base required yet), fall back to the
    # stock base so the engine still boots. ActionController::Base is part of Rails.
    require "action_controller"
    ::ActionController::Base
  end

  class ApplicationController < parent
    # CSRF protection — but only when the parent actually supports it. On
    # `ActionController::API` (or a host base that doesn't include the module),
    # `protect_from_forgery` isn't defined, so we guard the call. The public notice
    # form is a state-changing POST, so we want forgery protection whenever it's
    # available. `with: :exception` is the modern Rails default.
    if respond_to?(:protect_from_forgery)
      protect_from_forgery with: :exception
    end
  end
end
