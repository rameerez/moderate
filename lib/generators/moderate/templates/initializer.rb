# frozen_string_literal: true

Moderate.configure do |config|
  # ==========================================================================
  # WHO ARE YOUR USERS?
  # ==========================================================================
  #
  # The model that reports, blocks, gets reported, and gets banned. This is the
  # model where you `include Moderate::Actor`. Stored as a string and resolved
  # lazily, so it works no matter when your app boots.
  #
  # Default: "User"
  config.user_class = "User"

  # ==========================================================================
  # CONTENT FILTERING
  # ==========================================================================
  #
  # The default mode used by `moderates :field` when you don't pass `mode:`.
  #
  #   :off    - no check (filtering disabled for fields that don't override it)
  #   :block  - reject the save with a validation error if the filter trips
  #   :flag   - let the save through, then create a Moderate::Flag after commit
  #             for human or automated review (great for DMs, where you never
  #             want to block someone mid-conversation)
  #
  # Default: :block
  # config.default_filter_mode = :block

  # The default text adapter used by `moderates :field` and `Moderate.classify`.
  # Every adapter implements the same tiny contract — `classify(value) → Result`
  # — so they're interchangeable per field. `moderate` ships exactly ONE built-in
  # adapter; anything else (text-with-context, images, a hosted moderation API) is
  # bring-your-own (`register_adapter`, below):
  #
  #   :wordlist - fast, multilingual, offline wordlist (ships en/es). The ONLY
  #               built-in. Unicode + leetspeak + spacing-evasion resistant.
  #
  # Default: :wordlist
  # config.filter_adapter = :wordlist

  # Per-field filter policies, declared in one place instead of (or in addition
  # to) `moderates :field` in your models. Handy when you want all your T&S
  # configuration to live in this initializer.
  #
  # Signature: filter <ClassName>, <field>, with: <adapter>, mode: <mode>
  #
  # config.filter "Message", :body,   with: :wordlist, mode: :flag
  # config.filter "Profile", :bio,    with: :wordlist, mode: :block
  # config.filter "Profile", :avatar, with: :rekognition, mode: :flag  # a registered adapter (see below)

  # Bring your own adapter — it's just an object that responds to `classify`,
  # returning a Moderate::Result. Register it once, then reference it by name
  # in `moderates` or `config.filter` with `with: :my_adapter`.
  #
  # Two ready-to-copy reference adapters ship under the gem's examples/ directory —
  # OpenAI moderation (text + image, via the ruby_llm gem) and AWS Rekognition
  # (images). They are NOT a dependency: copy one into your app, add its gem to your
  # Gemfile, and register it here. Async adapters (a remote classifier) are only valid
  # in :flag mode; :block needs the synchronous :wordlist.
  #
  # config.register_adapter :openai, OpenAIModerationAdapter.new
  # config.register_adapter :my_adapter, MyAdapter.new

  # Extra wordlist entries layered on top of the built-in lists, and entries to
  # exclude (false positives you never want flagged in your domain). Both apply
  # to the :wordlist adapter.
  #
  # config.additional_words = %w[customword anotherword]
  # config.excluded_words   = %w[scunthorpe assangea]

  # Override the in-app COMMUNITY report category list (what a user picks from a
  # "Report" sheet). Defaults to Moderate::Report::DEFAULT_CATEGORIES. Adding a
  # category here requires NO migration — `category` is validated in the model. (The
  # separate, regulator-defined DSA legal-reason taxonomy is NOT overridable.)
  #
  # config.report_categories = %w[harassment hate spam fraud my_custom_label]

  # ==========================================================================
  # AUDIT — one hook, recorded however you want
  # ==========================================================================
  #
  # Called for every important action so you can write it to YOUR audit system.
  # `moderate` never writes to your audit log directly — it just emits the event.
  # No-op by default.
  #
  # The event carries a stable envelope:
  #   event.name        # Symbol, e.g. :report_decision
  #   event.subject      # the record acted on (a Report, Block, Flag, Appeal…)
  #   event.actor        # who took the action (a moderator, a user, or nil/system)
  #   event.recipients   # who should be notified (Array)
  #   event.payload      # Hash of event-specific context (includes :summary)
  #   event.to_h         # the whole envelope as a Hash
  #
  # config.audit = ->(event) { AuditLog.record!(event_type: event.name, data: event.payload) }

  # ==========================================================================
  # NOTIFY — one hook, fan out anywhere
  # ==========================================================================
  #
  # Called for every notifiable event. Wire it once and fan out to email
  # (goodmail), admin alerts (telegrama), in-app + push (noticed) — all from the
  # same place. No-op by default.
  #
  # The full event vocabulary:
  #   :report_received        :report_decision        :affected_user_decision
  #   :appeal_received        :appeal_decision
  #   :user_blocked           :user_unblocked         :user_banned
  #   :content_flagged        :content_removed
  #
  # IMPORTANT: keep this fast. Use background jobs (deliver_later, perform_later)
  # so notifications never block a moderation action.
  #
  # config.notify = ->(event) do
  #   case event.name
  #   when :report_received, :report_decision, :affected_user_decision
  #     # email the user — goodmail
  #     ModerationMailer.with(event: event).public_send(event.name).deliver_later
  #   when :content_flagged
  #     # ping admins — telegrama
  #     Telegrama.send_message("🚩 #{event.payload[:summary]}")
  #   end
  # end

  # ==========================================================================
  # ON BLOCK — optional side effects when one user blocks another
  # ==========================================================================
  #
  # Run extra teardown when a block happens (cancel a pending invite, leave a
  # shared room, drop a follow…). No-op by default. Signature uses keyword args.
  #
  # config.on_block = ->(blocker:, blocked:) { CancelPendingInvites.call(blocker, blocked) }

  # ==========================================================================
  # BAN HANDLER — how a "ban" is actually applied in YOUR app
  # ==========================================================================
  #
  # `moderate` doesn't own your user lifecycle, so it never bans a user itself.
  # When a moderator resolves a report with `ban_user: true`, this proc decides
  # what "banned" means in your domain — suspend, soft-delete, flip a flag, etc.
  # Signature uses keyword args. No-op by default (the action still audits).
  #
  # config.ban_handler = ->(user:, by:, reason:) { user.suspend!(reason: reason) }

  # ==========================================================================
  # SIGNED LINKS — purposes for the signed Global IDs in emails & notices
  # ==========================================================================
  #
  # `moderate` mints signed, single-purpose links (e.g. an appeal link in a
  # decision email, a confirm-receipt link in a DSA notice). These purposes
  # scope each signature so a link minted for one action can't be replayed for
  # another. The defaults cover the built-in flows; add your own if you mint
  # custom signed links against moderate records.
  #
  # Default: [:appeal, :confirm_notice, :unsubscribe]
  # config.signed_gid_purposes = [:appeal, :confirm_notice, :unsubscribe]

  # ==========================================================================
  # LOCALE
  # ==========================================================================
  #
  # The locale used for user-facing copy moderate generates on its own (filter
  # validation messages, the DSA statement-of-reasons taxonomy labels, the
  # notice-form strings). Defaults to your app's I18n.default_locale.
  #
  # config.locale = :en
end
