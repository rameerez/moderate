# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - unreleased

A complete, ground-up rewrite. `moderate` graduates from a single-purpose profanity
validator (0.1.0) into a full **Trust & Safety** engine for Rails apps with user-generated
content: report, block, filter, a moderation queue, appeals, and EU DSA / App Store / Google
Play **aligned** primitives. (First cut ships as `1.0.0.beta1`.)

> **Breaking:** 1.0 keeps the gem name but is an entirely new API. The 0.x profanity
> validator (`validates :field, moderate: true`) still loads for backward compatibility
> (see _Upgrading from 0.x_), but everything else is new. Pin `~> 0.1` if you relied on the
> old behavior and are not ready to adopt the new surface.

### Fixed — since 1.0.0.beta1

- **Async adapters now actually run in `Moderate::ClassifyJob`.** beta1's `:flag`
  after_commit called `Moderate.classify` inline for *every* adapter — including
  ones declaring `synchronous? == false` — so a remote moderation API ran its
  network call inside the request that saved the content, and `ClassifyJob`
  (whose docs promised this routing) was never enqueued by anything. The concern
  now checks `config.adapter_async?(policy.adapter)` (new public helper, same
  probe as the `:block` validator) and enqueues the job instead; the job re-reads
  the persisted value and files the Flag itself. Hosts that worked around this by
  enqueuing `ClassifyJob` themselves and short-circuiting
  `moderation_field_changed_for_commit?` can delete both workarounds.

### Added — since 1.0.0.beta1

- **Active Storage attachments filter out of the box.** `moderates :avatar, with:
  :your_image_adapter, mode: :flag` on a `has_one_attached` model needs zero extra
  wiring now: the concern snapshots `attachment_changes` in a `before_save` (AR
  dirty tracking can't see attachment writes, and Active Storage clears the
  changes before after_commit), consumes the snapshot at commit time, and both
  the concern and `ClassifyJob` treat an unattached `ActiveStorage::Attached`
  proxy as blank (nothing to classify — covers purge-between-enqueue-and-run).
  The three `moderation_field_*` seam overrides remain for richer cases.

### Added

- **Reporting.** `Moderate::Report` plus the `has_reportable_content :fields` macro and
  `Actor#report!(reportable, category:, details:)`. Reports and DSA notices share one model
  and one queue (`intake_kind: "community" | "dsa"`).
- **Blocking.** `Moderate::Block`, the `has_reporting_and_blocking` actor macro, and
  `block!` / `unblock!` / `blocks?` / `blocked_by?` / `blocked_with?`. `Moderate.blocked_ids_for(user)`
  is the bidirectional single source of truth you compose into feed/search/inbox queries.
  Optional `config.on_block` teardown hook runs inside the block transaction.
- **Content filtering.** The `moderates :field, mode: :off|:block|:flag, with: :adapter` macro
  (and the equivalent `config.filter`), the offline multilingual `:wordlist` adapter (the only
  built-in), the `classify(value) => Moderate::Result` adapter contract with
  `config.register_adapter`, asynchronous classification via `Moderate::ClassifyJob`, and
  ready-to-copy reference adapters for OpenAI omni-moderation and AWS Rekognition under
  `examples/` (bring-your-own, never a dependency).
- **Moderation queue & decisions.** `Moderate::Flag` and the service objects
  `Moderate::Services::{IntakeReport, ResolveReport, ResolveFlag, IntakeAppeal, ResolveAppeal,
  IntakeNotice}`. Decisions are taken under a row lock, re-check open state, apply enforcement
  (remove content / ban) inside the transaction, and fire notifications outside it; the appeal
  window and statement-of-reasons fields are stamped automatically.
- **DSA-aligned primitives.** A mountable public **notice-and-action** form (Art. 16) you mount
  at any path, **statement of reasons** (Art. 17), internal **appeals** (Art. 20), and
  **transparency** counters (Art. 24). The notice form prefills from query params + the signed-in
  user, locks auto-filled identity fields, and auto-detects `rails_cloudflare_turnstile`.
- **Hooks (all no-op by default).** `config.audit`, `config.notify` (returns a delivery boolean
  used to gate `decision_notified_at`), `config.on_block`, `config.ban_handler`, the
  host-overridable `config.report_categories`, and `config.notice_human_verification_skip_if` /
  `config.appeal_human_verification_skip_if` for native-app bot-gate carve-outs.
- **Optional integrations**, all auto-detected at runtime via `defined?`/`respond_to?` and never
  hard dependencies: madmin, goodmail, telegrama, noticed, rails_cloudflare_turnstile.
- **Install tooling.** `rails generate moderate:install` writes a documented initializer and an
  adaptive migration (uuid/bigint primary keys, jsonb/json/MySQL JSON columns); `moderate:views`
  ejects the notice form for customization.

### Changed

- Taxonomies (report categories, DSA legal reasons, country codes) are now frozen model
  constants with inclusion validations instead of DB `CHECK` constraints — adding or
  customizing a category needs no migration.
- External classifiers (OpenAI, image moderation) are reference adapters in `examples/`, not
  shipped or loaded code — the gem core forces no service dependency on apps that never use it.
- All "DSA-compliant" / "App Store compliant" language reframed to **DSA-aligned primitives**:
  the gem ships the mechanisms the law and the stores require; your policies, response times,
  and operations are still yours.

### Upgrading from 0.x

- The 0.x profanity validator still loads: `validates :field, moderate: true` continues to work
  via compatibility shims, so existing apps keep validating. To adopt 1.0, add
  `has_reporting_and_blocking` to your user model and `has_reportable_content` / `moderates` to your
  content models, run `rails generate moderate:install`, and migrate.

## [0.1.0] - 2024-11-03

- Initial release (profanity validator).
