# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount the engine exactly as a real host would (docs/dsa-notice-form.md):
  #   mount Moderate::Engine => "/legal"
  # This exposes the public DSA Art. 16 notice form at /legal/notices/new and gives
  # the host the `moderate.` URL-helper proxy the controller/mailer tests rely on.
  mount Moderate::Engine => "/legal"

  # A trivial host root so url_for / default_url_options have a target and the
  # post-report redirect fallback ("send the user back to the app root") resolves.
  root to: ->(_env) { [200, { "Content-Type" => "text/plain" }, ["dummy"]] }
end
