# frozen_string_literal: true

# The engine's routes. A host exposes them with a single line in its own routes:
#
#   mount Moderate::Engine => "/legal"   # => form at /legal/notices/new
#
# Because the engine is isolated, these become the `moderate.` URL-helper proxy in
# the host (e.g. `moderate.new_notice_path`). NOTHING here is required to use the
# rest of the gem (report/block/filter/queue) — mounting is only for the public
# DSA Art. 16 notice form. See docs/dsa-notice-form.md.
Moderate::Engine.routes.draw do
  # The public DSA "notice and action" form.
  #   GET  /notices/new     — the form
  #   POST /notices         — submit (validate + persist + confirm receipt)
  #   GET  /notices/:id      — the public receipt, looked up by OPAQUE `reference`
  #                            (the controller does `find_by!(reference: params[:id])`,
  #                            so :id here is the unguessable reference, never the
  #                            sequential primary key).
  resources :notices, only: [:new, :create, :show]

  # The engine root redirects to the form, so `mount … => "/legal"` makes `/legal`
  # itself a sensible landing spot (and a fine place to host the DSA Art. 11/12
  # "point of contact" copy once the views are ejected).
  root to: "notices#new"
end
