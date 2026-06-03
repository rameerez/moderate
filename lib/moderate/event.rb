# frozen_string_literal: true

require "securerandom"

module Moderate
  # The stable envelope every notifiable/auditable moment travels in.
  #
  # `Moderate.notify` and `Moderate.audit` both hand the host's hook ONE of these,
  # so a single `config.notify` lambda can `case event.name` and fan out to email
  # (goodmail), admin alerts (telegrama), and in-app + push (noticed) without any
  # of those channels knowing about each other. See docs/notifications.md.
  #
  # The fields are the contract the docs promise the host can rely on:
  #   event.name        # Symbol — which moment, e.g. :report_decision
  #   event.subject     # the record this is about (a Report / Flag / Block / Appeal / Notice)
  #   event.actor       # who triggered it (a moderator, a user, or nil for system events)
  #   event.recipients  # Array — already resolved to the right people to notify
  #   event.payload     # Hash of event-specific context, ALWAYS including :summary
  #   event.occurred_at # when it happened
  #   event.to_h        # the whole envelope as a Hash (for logging, tests, noticed params)
  #
  # Immutable value object (`Data.define`, Ruby 3.2+). The host never constructs
  # one — the gem's services do — the host only reads it.
  Event = Data.define(:name, :subject, :actor, :recipients, :payload, :occurred_at, :id) do
    # Keyword constructor with forgiving defaults so internal call sites stay terse.
    # `recipients` is coerced to a compacted Array (an event may target one user,
    # several, or none — `content_flagged` has no user recipient by design, so an
    # empty array is normal and correct). `payload` is symbolized for stable access
    # (hooks read `event.payload[:summary]`).
    def initialize(name:, subject: nil, actor: nil, recipients: nil, payload: nil,
                   occurred_at: Time.now, id: SecureRandom.uuid)
      super(
        name: name.to_sym,
        subject: subject,
        actor: actor,
        recipients: Array(recipients).compact,
        payload: symbolize(payload),
        occurred_at: occurred_at,
        id: id
      )
    end

    # The whole envelope as a plain Hash. docs/notifications.md tells hosts to pass
    # `event.to_h` (not the raw object) into `noticed`, because noticed serializes
    # params to the database and a Hash of GlobalID-able records + scalars stores
    # cleanly. Keep this a flat, predictable shape.
    def to_h
      {
        name: name,
        subject: subject,
        actor: actor,
        recipients: recipients,
        payload: payload,
        occurred_at: occurred_at,
        id: id
      }
    end

    # The one-line, redaction-safe description of what happened. Built for the
    # admin Telegram ping ("Telegrama.send_message(event.payload[:summary])"), so
    # we surface it as a first-class reader rather than making every hook reach
    # into the payload Hash. Falls back to the event name if a producer forgot it.
    def summary
      payload[:summary] || name.to_s
    end

    private

    def symbolize(payload)
      return {} if payload.nil?

      payload.to_h.transform_keys(&:to_sym)
    end
  end
end
