# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount the engine the way a real host does: the engine's routes are RELATIVE, and
  # the host picks the path. We deliberately mount at "/trust" (NOT "/legal") to
  # prove the gem hardcodes no prefix — the public DSA Art. 16 notice form then lives
  # at /trust/notices/new, and the host gets the `moderate.` URL-helper proxy the
  # controller/integration tests rely on. See docs/dsa-notice-form.md.
  mount Moderate::Engine => "/trust"

  # A trivial host root so url_for / default_url_options have a target and the
  # post-report redirect fallback ("send the user back to the app root") resolves.
  root to: ->(_env) { [200, { "Content-Type" => "text/plain" }, ["dummy"]] }
end
