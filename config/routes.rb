# frozen_string_literal: true

# The engine's routes. They are RELATIVE on purpose: the engine declares only the
# resource, and the HOST chooses the mount point in its own routes —
#
#   mount Moderate::Engine => "/trust"      # => form at /trust/notices/new
#   mount Moderate::Engine => "/moderation" # => form at /moderation/notices/new
#   mount Moderate::Engine => "/dsa"        # => form at /dsa/notices/new
#
# We deliberately do NOT hardcode a "/legal" prefix here (or anywhere). The path is
# the host's call; the gem only owns the routes RELATIVE to wherever it's mounted.
#
# Because the engine is isolated, these become the `moderate.` URL-helper proxy in
# the host (e.g. `moderate.new_notice_path`). NOTHING here is required to use the
# rest of the gem (report/block/filter/queue) — mounting is only for the public
# DSA Art. 16 notice form. See docs/dsa-notice-form.md.
Moderate::Engine.routes.draw do
  # The public DSA "notice and action" form.
  #   GET  /notices/new   — the form (prefillable via query params; see the controller)
  #   POST /notices        — submit (validate + persist a dsa-kind Moderate::Report +
  #                          confirm receipt, Art. 16(4))
  #
  # Only :new and :create — a notice is a `Moderate::Report` with no public,
  # enumerable identifier, so there is no per-notice `show` page; on success the
  # controller redirects back to the form with a confirmation flash (the durable,
  # on-record proof of receipt is the report's `acknowledged_at`, and the human-
  # facing confirmation goes out through the `notice_received` notify hook).
  resources :notices, only: %i[new create]

  # The engine root redirects to the form, so mounting the engine makes its mount
  # point itself a sensible landing spot (and a fine place to host the DSA Art.
  # 11/12 "point of contact" copy once the views are ejected).
  root to: "notices#new"
end
