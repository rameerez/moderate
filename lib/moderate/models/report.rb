# frozen_string_literal: true

module Moderate
  # The core notice/report record of the Trust & Safety system.
  #
  # A `Moderate::Report` is BOTH an in-app community report ("this comment is
  # harassment") AND a public EU DSA legal notice ("this URL hosts illegal
  # content"), distinguished by `intake_kind`. Keeping them in one table — one
  # queue, one decision workflow, one evidence snapshot — is deliberate: the DSA
  # wants notices "decided in a timely, diligent, non-arbitrary and objective
  # manner" (Art. 16(6)), and the simplest way to guarantee that is to make a
  # legal notice land in the exact same `pending` queue a moderator already works.
  # See: https://eur-lex.europa.eu/eli/reg/2022/2065/oj
  #
  # The model owns: validations, the immutable evidence snapshot, the
  # automated-processing disclosure (DSA Art. 16(6)/17(3)(c)), the appeal window
  # (DSA Art. 20), and a signed-GlobalID locator for the public flows. It stays
  # host-agnostic: who "owns" reported content, how content is snapshotted, and
  # what fields may be reported are all answered by the polymorphic `reportable`
  # (through the `Moderate::Reportable` interface), never by anything domain-specific.
  class Report < ApplicationRecord
    self.table_name = "moderate_reports"

    STATUSES = %w[open actioned dismissed].freeze
    INTAKE_KINDS = %w[community dsa].freeze

    # The default in-app COMMUNITY report categories. Two taxonomies on purpose
    # (README): a friendly community set the user picks from a "Report" sheet, plus
    # the regulator-aligned DSA legal-reason set below for public notices. These two
    # vocabularies serve different audiences and must NOT be collapsed.
    #
    # This list is HOST-CUSTOMIZABLE: a host that needs its own community labels sets
    # `config.report_categories = %w[...]` and validation tracks that instead (see
    # `.report_categories` below). The taxonomy lives in the MODEL — there is no DB
    # check constraint on `category` — precisely so adding a label never requires a
    # migration. (The DSA legal-reason/country lists below are regulator-defined and
    # therefore fixed, NOT host-overridable.)
    DEFAULT_CATEGORIES = %w[
      harassment hate threats sexual_content spam fraud unsafe_behavior
      illegal_content privacy child_safety other hate_abuse_harassment
      violent_speech graphic_violent_media illegal_regulated_behaviors
      impersonation adult_sexual_content private_non_consensual_content
      suicide_self_harm terrorism_violent_extremism scam_fraud
    ].freeze

    # The DSA "statement of reasons" legal-reason taxonomy used on public notices.
    # These are the categories the EU Transparency Database expects, so the Art. 24
    # transparency counters and the Art. 16 intake speak one regulator-aligned
    # vocabulary. Regulator-defined, so this is a FIXED constant (not host-overridable):
    # widening it is a gem change, not a host config. Validated by the model, not the DB.
    DSA_LEGAL_REASONS = %w[
      animal_welfare consumer_information cyber_violence data_protection_privacy
      illegal_or_harmful_speech civic_elections non_consensual_behavior
      pornography_sexualized_content protection_of_minors public_security
      scams_fraud scope_of_platform_service self_harm unsafe_illegal_products
      violence intellectual_property other
    ].freeze

    # The 27 EU member-state codes plus "EU" (whole-union). The DSA notice form
    # requires the member state whose law is allegedly broken. Regulator-defined and
    # therefore fixed (not host-overridable). Validated by the model, not the DB.
    EU_COUNTRY_CODES = %w[
      AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT
      RO SE SI SK EU
    ].freeze

    # Generic, host-agnostic content-type buckets. A host's reportable supplies its
    # own via `moderation_content_type`, but the stored value is constrained to this
    # vocabulary (model-level inclusion, NULL allowed) so the queue and transparency
    # counts stay tidy.
    CONTENT_TYPES = %w[
      user_profile profile_avatar listing message conversation group other
    ].freeze

    # The legal/contractual ground a moderator records when closing a report —
    # the DSA Art. 17(1) "legal or contractual ground" of the statement of reasons.
    # Model-level inclusion (NULL allowed); no DB constraint.
    RESOLUTION_BASES = %w[terms law law_and_terms insufficient_information no_violation].freeze

    # Matches the `moderate_reports_message_length_check` DB constraint — the one
    # value guard kept at the DB level (a cheap runaway-free-text backstop).
    MESSAGE_MAX_LENGTH = 4000

    # Signed-GlobalID purposes. A purpose is a namespace tag baked into the signed
    # token so a token minted to locate the *reported content* can't be replayed to
    # locate the *report itself* (and vice versa) — GlobalID verifies the purpose on
    # the way back out. See https://github.com/rails/globalid#signed-global-ids.
    # The strings are gem-stable ("moderate_*") and host-agnostic.
    SIGNED_GLOBAL_ID_PURPOSE = "moderate_report"
    APPEAL_SIGNED_GLOBAL_ID_PURPOSE = "moderate_appeal"

    # DSA Art. 20(1): the internal complaint (appeal) mechanism must stay open for
    # "at least six months following the decision". We default to exactly six months
    # and refuse appeals filed after it (enforced on Moderate::Appeal).
    APPEAL_WINDOW = 6.months

    # Transient flags a caller may set on the intake side (e.g. "don't email a
    # receipt for this seeded record", "also block the reported user"). They never
    # persist; the services read them. Kept here so both the model and its services
    # share one definition.
    attr_accessor :skip_received_notice, :block_reported_user

    # All actor associations resolve to the HOST's configured user class, read
    # lazily from the configuration as a String so this file loads before the host
    # has declared its User model (the initializer sets `config.user_class` first,
    # models autoload on demand). `optional: true` everywhere a user may be absent:
    # a DSA notice can come from a non-user, and reported content does not always
    # resolve to a single owning account.
    belongs_to :reporter, class_name: Moderate.config.user_class, optional: true
    belongs_to :reported_user, class_name: Moderate.config.user_class, optional: true
    belongs_to :resolved_by, class_name: Moderate.config.user_class, optional: true
    belongs_to :reportable, polymorphic: true, optional: true

    has_many :appeals, class_name: "Moderate::Appeal", dependent: :destroy

    # The auto-filter flags that touched the SAME (record, field) this report is
    # about. Used to disclose automated means at intake (Art. 17(3)(c)) — if the
    # wordlist/image adapter already flagged this exact content, the decision email
    # must not later claim "no automated means were used". The scope re-keys the
    # association onto the polymorphic flaggable columns, since a Flag points at the
    # content polymorphically, not at the Report.
    has_many :flags,
      ->(report) { where(flaggable_type: report.reportable_type, field: report.reported_field) },
      class_name: "Moderate::Flag",
      primary_key: :reportable_id,
      foreign_key: :flaggable_id

    before_validation :normalize_strings
    before_validation :hydrate_reporter_contact, if: :reporter
    before_validation :infer_reported_user, on: :create
    before_validation :capture_snapshot, on: :create
    before_validation :capture_automated_processing, on: :create
    # Default the JSON columns to their empty shape before save. WHY: the migration
    # makes these NOT NULL, but MySQL 8+ forbids a DEFAULT on a JSON column, so on
    # MySQL the column has NO database default — inserting a row that never touched
    # `automated_processing` / `resolution_actions` would write NULL and trip a
    # NotNullViolation. (SQLite/PostgreSQL get a `{}`/`[]` default from the migration
    # and don't need this, but coalescing nil→empty is harmless there.) The migration
    # explicitly delegates this to the model ("Models handle nil metadata gracefully
    # by defaulting to {} in their accessors"); this is that handling.
    before_save :default_json_columns

    scope :open, -> { where(status: "open") }
    scope :actioned, -> { where(status: "actioned") }
    scope :dismissed, -> { where(status: "dismissed") }
    # `pending` == awaiting a decision. The README/admin queue is `Report.pending`;
    # it's the same set as `open`, named for the queue's vocabulary (a "pending"
    # decision) rather than the record's status word. Both exist so each call site
    # reads naturally.
    scope :pending, -> { where(status: "open") }
    scope :recent_first, -> { order(created_at: :desc) }

    validates :status, inclusion: { in: STATUSES }
    validates :intake_kind, inclusion: { in: INTAKE_KINDS }
    # `category` is validated against the HOST-CUSTOMIZABLE list (config override or
    # DEFAULT_CATEGORIES) — resolved at validation time, NOT class-load time, so a host
    # that sets `config.report_categories` in its initializer is honored even though
    # this model loads first. Passed as a lambda because `inclusion: { in: [...] }`
    # snapshots a plain array once at load; a lambda is re-evaluated per record. The
    # lambda's argument IS the record, so we reach the class method through its class
    # (inside the proc, `self` is the record instance, which has no `report_categories`).
    validates :category, inclusion: { in: ->(report) { report.class.report_categories } }
    validates :message, presence: true, length: { maximum: MESSAGE_MAX_LENGTH }
    # DSA Art. 16(2)(c): notices must carry the notifier's name and email — UNLESS
    # the notice alleges an offence against minors, where the regulation waives the
    # identity requirement (the CSAM/child-safety anonymity carve-out). Both name and
    # email are required ONLY for DSA public notices: a notifier the provider has no
    # account for must be reachable to receive the Art. 16(4) confirmation of receipt
    # and the Art. 17 decision. An in-app COMMUNITY report comes from a logged-in user
    # the app can already reach (or doesn't need to email at all — they get the in-app
    # acknowledgement), and that user may legitimately have no email column, so we do
    # NOT force a notifier_email there. The format check still applies to any email
    # that IS present, on either path.
    validates :notifier_name, presence: true, if: -> { dsa? && !anonymous_notice? }
    validates :notifier_email, presence: true, if: -> { dsa? && !anonymous_notice? }
    validates :notifier_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validates :subject_url, length: { maximum: 2048 }, allow_blank: true
    validates :reported_field, length: { maximum: 64 }, allow_blank: true
    validates :resolution_note, presence: true, if: :closed?
    # DSA Art. 16(2)(d): a notice/report must include a good-faith statement that its
    # contents are accurate and complete. `acceptance: true` rejects the save unless
    # the flag is truthy. This applies to BOTH intake kinds: a public DSA notifier
    # ticks the box on the form, and an in-app reporter attests implicitly by tapping
    # "Report" — so the `report!` actor helper sets `good_faith_confirmed: true` for
    # the community path (see Moderate::Actor#report!). Keeping ONE always-on
    # validation (rather than scoping it to DSA) means a Report built directly with a
    # falsy good-faith flag is rejected regardless of kind, which is the safe default.
    validates :good_faith_confirmed, acceptance: true
    validates :legal_reason, inclusion: { in: DSA_LEGAL_REASONS }, allow_blank: true
    validates :legal_country_code, inclusion: { in: EU_COUNTRY_CODES }, allow_blank: true
    validates :content_type, inclusion: { in: CONTENT_TYPES }, allow_blank: true
    validates :resolution_basis, inclusion: { in: RESOLUTION_BASES }, allow_blank: true
    validate :reporter_cannot_report_self
    validate :reportable_field_must_be_allowed
    validate :subject_url_must_be_http_url
    validate :public_notice_requires_subject_url
    validate :dsa_notice_must_be_substantiated
    validate :anonymous_notice_only_for_child_safety

    # --- Taxonomy (host-customizable) ----------------------------------------

    # The community `category` vocabulary in effect: the host's `config.report_categories`
    # if they set one, else the gem's DEFAULT_CATEGORIES. Read at the point of use (not
    # memoized) so a host can change it without a reboot and so it tracks `Moderate.reset!`
    # in tests. Coerced to strings to match the normalized, persisted column value.
    def self.report_categories
      Array(Moderate.config.report_categories).map(&:to_s).presence || DEFAULT_CATEGORIES
    end

    # --- Signed-GlobalID locators --------------------------------------------

    # Resolve a signed token back into the reported content. `only:` is scoped to
    # the auto-discovered reportable classes (NOT every model), so a forged/replayed
    # token can only ever resolve to a class the host explicitly made reportable —
    # a deliberate allow-list against object-substitution attacks.
    def self.locate_signed_reportable(token)
      return if token.blank?

      GlobalID::Locator.locate_signed(
        token,
        for: SIGNED_GLOBAL_ID_PURPOSE,
        only: Moderate.reportable_classes
      )
    end

    # Resolve a signed token back into the Report it was minted for (used by the
    # public appeal flow, where the appellant arrives via an emailed signed link).
    # Locked to `self` so the token can only ever name a Report.
    def self.locate_signed_appeal_report(token)
      return if token.blank?

      GlobalID::Locator.locate_signed(token, for: APPEAL_SIGNED_GLOBAL_ID_PURPOSE, only: [self])
    end

    # --- Status predicates ----------------------------------------------------

    def open?
      status == "open"
    end

    def actioned?
      status == "actioned"
    end

    def dismissed?
      status == "dismissed"
    end

    def closed?
      actioned? || dismissed?
    end

    def dsa?
      intake_kind == "dsa"
    end

    def community?
      intake_kind == "community"
    end

    # The anonymity carve-out from DSA Art. 16(2)(c): a notice may omit the
    # notifier's identity ONLY when it concerns offences against minors. We tie it
    # to the `protection_of_minors` legal reason — the single ground for which the
    # regulation lets a notice be filed anonymously.
    def anonymous_notice?
      anonymous? && legal_reason == "protection_of_minors"
    end

    # --- Human-readable labels (delegated to the reportable, host-agnostic) ----

    # How to address the notifier in copy: their name if given, else their email.
    def notifier_label
      notifier_name.presence || notifier_email
    end

    # A label for the reported thing. We ask the reportable for its own label (via
    # the Moderate::Reportable interface), fall back to the notice URL, and finally
    # to a generic localized "legal notice" string — so a notice about an external
    # URL (no in-app record) still renders something sensible in the queue.
    def reportable_label
      return reportable.moderation_label if reportable.respond_to?(:moderation_label)

      subject_url.presence || I18n.t("moderate.reports.legal_notice_label", default: "Legal notice")
    end

    # The snapshotted text of the reported field, asked of the reportable. Returns
    # nil when the reportable doesn't expose snapshot text (or there's no record).
    def reported_content_text
      return unless reportable.respond_to?(:moderation_snapshot_text)

      reportable.moderation_snapshot_text(reported_field)
    end

    # --- Signed GIDs for emailed links ---------------------------------------

    def signed_reportable_gid
      reportable&.to_sgid_param(for: SIGNED_GLOBAL_ID_PURPOSE)
    end

    def signed_appeal_gid
      to_sgid_param(for: APPEAL_SIGNED_GLOBAL_ID_PURPOSE)
    end

    # --- URL helpers (defensive parsing) -------------------------------------

    def safe_subject_url
      parsed_subject_uri(subject_url)&.to_s
    end

    def safe_subject_url_for(url)
      parsed_subject_uri(url)&.to_s
    end

    def safe_subject_urls
      subject_url_list.filter_map { |url| parsed_subject_uri(url)&.to_s }
    end

    # The de-duplicated list of notice URLs (a notice may cite several). Falls back
    # to the single `subject_url` for records created before/without the list column.
    def subject_url_list
      Array(subject_urls).presence || Array(subject_url)
    end

    # --- Lifecycle helpers ----------------------------------------------------

    # DSA Art. 16(4): record that the confirmation of receipt was acknowledged.
    # `update_column` skips validations/callbacks on purpose — this is a timestamp
    # stamp, not a content change, and must succeed even on an already-validated row.
    # Idempotent: only sets the first acknowledgement.
    def acknowledge!(at: Time.current)
      update_column(:acknowledged_at, at) if acknowledged_at.blank?
    end

    # DSA Art. 20(1): open the redress (appeal) window for at least six months after
    # the decision. Stamped once when the report is decided; idempotent so re-running
    # a decision flow doesn't slide the deadline.
    def close_redress_window!(at: resolved_at || Time.current)
      update_column(:appeal_deadline_at, at + APPEAL_WINDOW) if appeal_deadline_at.blank?
    end

    # DSA Art. 17(3)(c): did automated means (a wordlist/image/remote classifier)
    # participate in surfacing or deciding this report? The decision email reads this
    # to truthfully state whether automation was used. We treat the disclosure as
    # "used" if the explicit `used` flag is true OR any captured evidence value is
    # true — defensive against partially-populated evidence hashes.
    def automated_processing_used?
      automation = automated_processing.to_h
      boolean = ActiveModel::Type::Boolean.new

      return true if boolean.cast(automation["used"])

      automation.except("used").values.any? { |value| value == true || value == "true" }
    end

    private

    # Coalesce the JSON columns to their empty shape so a NULL never reaches a
    # NOT-NULL JSON column (the MySQL-no-JSON-default case — see the before_save
    # comment). Hash-shaped columns default to {}, the list-shaped one to [].
    def default_json_columns
      self.snapshot ||= {}
      self.automated_processing ||= {}
      self.resolution_actions ||= {}
      self.subject_urls ||= []
    end

    # Normalize every free-text field once, up front: collapse internal whitespace,
    # turn blanks into nil (so `presence`/`allow_blank` validations behave), downcase
    # emails, upcase country codes, and canonicalize newlines in long text. Doing it
    # in one before_validation keeps the snapshot and the validations consistent.
    def normalize_strings
      self.reported_field = reported_field.to_s.squish.presence
      self.category = category.to_s.squish.presence
      self.status = status.to_s.squish.presence || "open"
      self.intake_kind = intake_kind.to_s.squish.presence || "community"
      self.notifier_name = notifier_name.to_s.squish.presence
      self.notifier_email = notifier_email.to_s.squish.presence&.downcase
      self.subject_url = subject_url.to_s.squish.presence
      self.subject_urls = normalize_subject_urls
      self.legal_reason = legal_reason.to_s.squish.presence
      self.legal_country_code = legal_country_code.to_s.squish.upcase.presence
      self.content_type = content_type.to_s.squish.presence
      self.reported_account_identifier = reported_account_identifier.to_s.squish.presence
      self.resolution_basis = resolution_basis.to_s.squish.presence
      self.decision_visibility = decision_visibility.to_s.squish.presence
      self.message = message.to_s.gsub(/\r\n?/, "\n").strip.presence
      self.resolution_note = resolution_note.to_s.strip.presence
    end

    # When an authenticated user files the report, copy their contact onto the
    # notifier fields so DSA notices and community reports carry the same identity
    # shape downstream. We read `email`/`display_name` via `try` so the host's user
    # class only needs whichever it actually has.
    def hydrate_reporter_contact
      self.notifier_email ||= reporter.try(:email)
      self.notifier_name ||= reporter.try(:display_name)
    end

    # Infer who's responsible for the reported content from the reportable itself
    # (its `reported_owner`, per the Moderate::Reportable interface). This is how a
    # report against a piece of content becomes a report "about" the user who posted
    # it — without this model knowing anything about the host's ownership model.
    def infer_reported_user
      return if reported_user.present?
      return unless reportable.respond_to?(:reported_owner)

      self.reported_user = reportable.reported_owner
    end

    # Capture an IMMUTABLE evidence snapshot at create time. This is the heart of a
    # defensible decision: the content as it was WHEN reported, frozen into JSON, so
    # the evidence survives the author editing or deleting the original afterward
    # (DSA Art. 17 "facts and circumstances relied on"; Apple/Play "timely response"
    # all assume the evidence is still there when you act). `.compact` drops nils so
    # the snapshot stores only what was actually present.
    def capture_snapshot
      self.snapshot = {
        intake_kind: intake_kind,
        reportable_type: reportable_type,
        reportable_id: reportable_id,
        reported_field: reported_field,
        reported_user_id: reported_user_id,
        reporter_id: reporter_id,
        subject_url: subject_url,
        subject_urls: subject_url_list,
        legal_reason: legal_reason,
        legal_country_code: legal_country_code,
        content_type: content_type,
        reported_account_identifier: reported_account_identifier,
        content_text: reported_content_text,
        captured_at: Time.current.iso8601
      }.compact
    end

    def capture_automated_processing
      evidence = automated_processing_evidence
      return if evidence.blank?

      # DSA Art. 16(6)/17(3)(c) require disclosing whether automated means were used
      # in detection or decision. We store the factual source/category metadata at
      # INTAKE so a later decision notice can never accidentally say "No automated
      # means" after a wordlist or image adapter already flagged this exact content.
      # Merge (don't overwrite) so any pre-set evidence is preserved.
      # Source: https://eur-lex.europa.eu/eli/reg/2022/2065/oj
      self.automated_processing = automated_processing.to_h.deep_stringify_keys.merge(evidence)
    end

    # --- Custom validations ---------------------------------------------------

    def reporter_cannot_report_self
      return if reporter_id.blank? || reported_user_id.blank? || reporter_id != reported_user_id

      errors.add(:reported_user, I18n.t("moderate.errors.reporter_cannot_report_self", default: "You can't report yourself"))
    end

    # The reported field must be one the reportable actually allows to be reported
    # (declared via `reportable :title, :description`). We ask the reportable via its
    # `reportable_field_allowed?` predicate; if it doesn't expose one (a record that
    # isn't a managed reportable), we don't constrain the field.
    def reportable_field_must_be_allowed
      return if reportable.blank?
      return unless reportable.respond_to?(:reportable_field_allowed?)
      return if reportable.reportable_field_allowed?(reported_field)

      errors.add(:reported_field, I18n.t("moderate.errors.invalid_reported_field", default: "is not a reportable field"))
    end

    def subject_url_must_be_http_url
      invalid_urls = subject_url_list.reject { |url| parsed_subject_uri(url).present? }
      return if invalid_urls.empty?

      errors.add(:subject_url, I18n.t("moderate.errors.invalid_subject_url", default: "must be a valid http(s) URL"))
    end

    # A notice with NO in-app reportable record (a pure external-URL DSA notice)
    # must carry at least one subject URL — DSA Art. 16(2)(b) requires the "exact
    # electronic location" of the content.
    def public_notice_requires_subject_url
      return if reportable.present?
      return if subject_url_list.any?

      errors.add(:subject_url, I18n.t("moderate.errors.missing_subject_url", default: "is required"))
    end

    # DSA Art. 16(2): a legal notice must be "sufficiently substantiated" — we
    # require the legal ground, the member state, and the content type so the
    # statement of reasons (Art. 17) can actually be written from it.
    def dsa_notice_must_be_substantiated
      return unless dsa?

      errors.add(:legal_reason, :blank) if legal_reason.blank?
      errors.add(:legal_country_code, :blank) if legal_country_code.blank?
      errors.add(:content_type, :blank) if content_type.blank?
    end

    # The anonymity carve-out is NARROW: anonymous notices are permitted only for
    # offences against minors. Any other anonymous notice is rejected, so the
    # identity requirement of Art. 16(2)(c) isn't bypassed for ordinary notices.
    def anonymous_notice_only_for_child_safety
      return unless anonymous?
      return if legal_reason == "protection_of_minors"

      errors.add(:anonymous, I18n.t("moderate.errors.anonymous_notice_child_safety_only", default: "anonymous notices are only allowed for offences against minors"))
    end

    # Accept either a multi-URL list or newline-separated text, fold in the single
    # `subject_url`, squish/dedupe, and keep `subject_url` pointing at the first —
    # so the single-URL and multi-URL representations never drift apart.
    def normalize_subject_urls
      urls = Array(subject_urls).flat_map { |value| value.to_s.split(/\R/) }
      urls << subject_url
      urls = urls.map { |value| value.to_s.squish.presence }.compact.uniq
      self.subject_url = urls.first
      urls
    end

    # Parse a string into a URI only if it's a real http(s) URL with a host —
    # rejecting `javascript:`, `file:`, scheme-relative, and garbage. Returns nil
    # (never raises) on malformed input, so it's safe to use in both validations and
    # the `safe_*` readers that feed links into emails/views.
    def parsed_subject_uri(url)
      return if url.blank?

      uri = URI.parse(url)
      uri if uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end

    # Gather the automated-means evidence for this report's (record, field): any
    # existing auto-Flags on the same content, plus a fresh synchronous classify if
    # the field is under a :block policy. Returns nil when nothing automated touched
    # it (so the caller can skip storing an empty disclosure).
    def automated_processing_evidence
      evidence = {}

      matching_flags = flags.to_a
      if matching_flags.any?
        evidence["used"] = true
        evidence["flag_ids"] = matching_flags.map(&:id)
        evidence["sources"] = matching_flags.map(&:source).compact.uniq
        evidence["categories"] = matching_flags.flat_map { |flag| Array(flag.categories) }.compact.uniq
      end

      result = automated_classifier_result
      if result&.flagged?
        evidence["used"] = true
        evidence["field"] = reported_field
        evidence["sources"] = Array(evidence["sources"]).concat([result.source]).compact.uniq
        evidence["categories"] = Array(evidence["categories"]).concat(result.categories).compact.uniq
        evidence["scores"] = result.scores
        # `raw` is the untouched provider payload (Moderate::Result#raw) — kept for
        # audit so a regulator query can be answered with the exact classifier output.
        evidence["metadata"] = result.raw
      end

      evidence.presence
    end

    # Run the configured filter for this (record, field) ONLY when it's a synchronous
    # :block policy — an async adapter can't have contributed to a synchronous intake
    # decision, so re-running it here would be both wrong (it didn't fire) and slow.
    def automated_classifier_result
      return if reportable.blank? || reported_field.blank?

      policy = Moderate.filter_policy_for(reportable, reported_field)
      return unless policy.block?

      value = reported_content_text
      return if value.blank?

      Moderate.classify(value, policy: policy)
    end
  end
end
