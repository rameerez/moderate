# frozen_string_literal: true

module Moderate
  # Drop-in admin moderation actions for a host's admin controller (BYOUI).
  #
  #   class Admin::ReportsController < ApplicationController
  #     include Moderate::Moderation   # resolve/dismiss (+ uphold/reject) actions
  #     before_action :require_admin   # you bring auth
  #   end
  #
  # `moderate` deliberately ships NO admin UI — Trust & Safety chrome (branding,
  # auth, layout) is the part every app wants to own. What it DOES own is the
  # decision *logic*: every status change must go through the model's atomic
  # decision method (`resolve!`/`dismiss!`/`uphold!`/`reject!`) so content removal,
  # bans, the notify/audit hooks, the DSA Art. 17 statement-of-reasons, and the
  # Art. 20 appeal window all happen together-or-not-at-all. This concern is the
  # thin HTTP glue that calls those methods, so a host gets the standard wiring for
  # free and never hand-rolls a raw `status = "..."` update (which would skip every
  # one of those guarantees). See docs/madmin.md.
  #
  # The actions assume `@record` is already loaded (madmin's ResourceController and
  # most admin frameworks set it from the member route). If yours doesn't, override
  # `moderation_record` below.
  module Moderation
    extend ActiveSupport::Concern

    # --- Report / Flag decisions ---------------------------------------------
    # Both `Moderate::Report` and `Moderate::Flag` expose `resolve!`/`dismiss!` with
    # the same keyword contract, so the SAME two actions drive either resource —
    # the host just includes this concern in whichever controller.

    # Resolve (action) a report/flag: optionally remove the offending content and/or
    # ban the responsible user, always with a moderator + a note.
    #
    # `remove_content`/`ban_user` come from the form as checkboxes ("1"/"0"); the
    # model casts them, but we pass them through untouched so the model stays the one
    # place that interprets them. `note` is required by the model (it feeds the
    # statement of reasons) — we let the model raise and turn that into a flash.
    def resolve
      record = moderation_record
      record.resolve!(**moderation_decision_params)
      redirect_after_moderation(record, notice: moderation_t(:resolved))
    rescue => error
      redirect_after_moderation(record, alert: moderation_error(:resolve, error))
    end

    # Dismiss (action) a report/flag: no violation found. Note still required.
    def dismiss
      record = moderation_record
      record.dismiss!(by: moderation_actor, note: moderation_note)
      redirect_after_moderation(record, notice: moderation_t(:dismissed))
    rescue => error
      redirect_after_moderation(record, alert: moderation_error(:dismiss, error))
    end

    # --- Appeal decisions (DSA Art. 20) --------------------------------------
    # An appeal is a free, electronic, human-decided internal complaint against a
    # decision. `uphold!` OVERTURNS the original decision; `reject!` CONFIRMS it.
    # https://eur-lex.europa.eu/eli/reg/2022/2065/oj (Article 20)

    def uphold
      record = moderation_record
      record.uphold!(by: moderation_actor, note: moderation_note)
      redirect_after_moderation(record, notice: moderation_t(:upheld))
    rescue => error
      redirect_after_moderation(record, alert: moderation_error(:uphold, error))
    end

    def reject
      record = moderation_record
      record.reject!(by: moderation_actor, note: moderation_note)
      redirect_after_moderation(record, notice: moderation_t(:rejected))
    rescue => error
      redirect_after_moderation(record, alert: moderation_error(:reject, error))
    end

    private

    # The record being decided on. Override if your admin framework names it
    # differently — madmin uses `@record`, many hand-rolled admins do too.
    def moderation_record
      @record
    end

    # The moderator making the call. `current_user` is the near-universal accessor;
    # a host whose admin uses a different actor (e.g. `current_admin`) overrides
    # this single method. Required by every decision method (the decision must be
    # attributable to a human — a DSA Art. 17/20 requirement).
    def moderation_actor
      current_user
    end

    # The mandatory decision rationale. Required by the model too (belt and
    # suspenders) — it's what populates the statement of reasons sent to the parties.
    def moderation_note
      params[:note]
    end

    # Strong params for the richest decision (`resolve` on a report). We don't use
    # `params.require(:report)` because the decision form is a flat panel of
    # checkboxes + a note, not a nested model form — so we read top-level params and
    # hand the model exactly the keyword args it documents. `ban_user`/`remove_content`
    # default to off so a missing checkbox never accidentally bans someone.
    def moderation_decision_params
      {
        by: moderation_actor,
        note: moderation_note,
        remove_content: params[:remove_content],
        ban_user: params[:ban_user]
      }
    end

    # Redirect back to the record after a decision.
    #
    # `status: :see_other` (303) is REQUIRED, not stylistic: the decision actions are
    # POSTs, and Turbo Drive only follows a redirect after a non-GET when the status
    # is 303 — without it the redirect is swallowed and the page appears to hang.
    # This is the same convention Rails' own scaffold create/update use.
    # https://turbo.hotwired.dev/handbook/drive#redirecting-after-a-form-submission
    #
    # We fall back to `:back` when we can't build a path for the record, so the
    # concern works regardless of the host's route names (BYOUI — we don't know
    # them). The host can override `moderation_redirect_path` for an exact target.
    def redirect_after_moderation(record, **flash)
      path = moderation_redirect_path(record)
      if path
        redirect_to(path, status: :see_other, **flash)
      else
        redirect_back(fallback_location: "/", status: :see_other, **flash)
      end
    end

    # Where to go after a decision. Returns nil so `redirect_after_moderation` falls
    # back to `redirect_back` — the safe default for an admin we know nothing about.
    # Override in the host controller to land on the record's show page, e.g.
    #   def moderation_redirect_path(record) = main_app.madmin_report_path(record)
    def moderation_redirect_path(_record)
      nil
    end

    # A flash message for the failure case. We surface the model's own error message
    # (e.g. "report already closed", "note required") so the moderator sees WHY the
    # decision didn't apply, not a generic "something went wrong".
    def moderation_error(action, error)
      message = error.respond_to?(:message) ? error.message : error.to_s
      moderation_t(:"#{action}_failed", default: "Could not #{action}: #{message}", error: message)
    end

    # Translated flash copy, with a plain-English default so the concern works even
    # before the host loads the gem's locale file.
    def moderation_t(key, **options)
      defaults = {
        resolved: "Report resolved.",
        dismissed: "Report dismissed.",
        upheld: "Appeal upheld.",
        rejected: "Appeal rejected."
      }
      I18n.t("moderate.moderation.#{key}", default: options.delete(:default) || defaults[key] || key.to_s, **options)
    end
  end
end
