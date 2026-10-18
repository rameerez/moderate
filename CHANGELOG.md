# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Human labels for reportable fields.** `has_reportable_content :body, :files, labels:
  { body: "Chat message", files: "Chat photo" }` (and `reportable_fields …, labels:`) names
  each field once, next to its declaration, so moderators and affected users stop reading raw
  column names («Body») for what was reported. Resolution: the declared label (a String, or a
  lambda evaluated at read time) → i18n `moderate.reportable_fields.<model>.<field>` (walking
  reportable STI parents) → `moderate.reportable_fields.<field>` → `field.humanize`. Read it
  with `Moderate.reportable_field_label(record_or_class_or_type, field)`,
  `Report#reported_field_label`, `Flag#field_label`, or `record.reportable_field_label(field)`;
  labels resolve from the stored type, so they survive the content being deleted. A label key
  for an undeclared field raises. Hosts that kept their own field → label map can delete it.
- **Labels everywhere the gem names a field.** The public appeal page shows the reported
  content's label; the statement-of-reasons payload (`affected_user_decision`, `report_decision`)
  carries `reported_field` + `reported_field_label`; `report_received` carries both and appends
  the label to its summary; `content_flagged` and the `flag_decision` audit carry `field_label`,
  and the `content_flagged` summary prints the label instead of `Type#field`.
- **Default locale files** (`config/locales/en.yml`, `es.yml`): the appeal page's new string and
  generic labels for common field names (`body` → "Text"/"Texto", `avatar` → "Profile
  photo"/"Foto de perfil", …).
- **Enforce from a flag.** `flag.action!(by:, note:, remove_content: true)` and
  `flag.action!(by:, note:, ban_user: true)` (any combination, plus `resolution_basis:`)
  escalate to a report and resolve it: the newest open report on the same content and field
  if a person already filed one, else a system report (no reporter, so no receipt and no
  reporter-facing decision). Content is removed through the reportable's
  `remove_reported_field!`, the ban goes through your `ban_handler`, and the affected user
  gets the statement of reasons and the appeal window a restriction requires. It all runs
  under the flag's row lock, so two moderators pressing it at once enforce once, and the
  decision notices go out after the lock is released. `flag.report` is the report it went
  through. Hosts that hand-wrote this bridge (find-or-create a report, resolve it, then close
  the flag) can delete it. Without those options `action!` is the triage close it was.
- **`Moderate::Flag.flag_for_review!(record, field:, by:, note: nil)`**: an administrator
  filing content for review by hand (the "Flag for review" button on a transcript line). It
  returns the pending flag on that field if one already waits, else files a
  `source: "manual"` flag owned by the content's person, with the evidence snapshot as
  excerpt and `context` naming who filed it; `flag.previously_new_record?` says which. The
  check and the insert run under the record's row lock, so two administrators pressing it
  together file one flag. Audited as `:flag_filed`. Hosts that hand-assembled the nine
  `Flag.flag!` arguments (and, without a lock, could file two) can call this instead.
- **`Flag#resolve!`**, an alias of `action!`: reports and flags now share one verb and one
  keyword contract, which is what `Moderate::Moderation#resolve` and `docs/madmin.md`
  always assumed.

### Changed

- **`Flag#action!` / `#dismiss!` go through `Moderate::Services::ResolveFlag`.** The beta2
  model methods were a second closing path with no row lock and no `flag_decision` audit;
  now there is one. Re-closing an already decided flag returns it unchanged (as the service
  always did) instead of overwriting the first decision.
- **`ResolveReport.new(report, by:, deliver: false)`** holds the decision notices back for a
  caller that decides inside a lock of its own; `#deliver_decision_notices` sends them.

### Fixed

- **`Moderate::Moderation#resolve` works on flags.** It called `record.resolve!`, which
  `Moderate::Flag` didn't have, so a host following the concern's own documentation got a
  `NoMethodError` (as an alert flash) on every flag. It also passes `resolution_basis` when
  the form sends one, and its flash says "Flag actioned." / "Flag dismissed." for flags.
- **Content spoken by something that isn't a person no longer breaks reports and flags.**
  moderate stored `reportable.reported_owner` straight into `Report#reported_user` and
  `Flag#owner`, both associations to `config.user_class`. A support desk or a bot behind the
  content (chats answers `author || sender`, which is a desk for an unsigned support reply)
  raised `ActiveRecord::AssociationTypeMismatch` and the report never filed. The new
  `Moderate.responsible_user(record)` keeps the owner only if it is a person; anything else
  means "nobody to reach": the report files, the evidence is kept, content can still be
  removed, and only a decision notice or a ban has no addressee. Report intake, `Flag.flag!`,
  the `:flag` after_commit and `ClassifyJob` all go through it. A reportable that never
  defined `reported_owner` still raises at the first report. Hosts that overrode
  `Chats::Message#reported_owner` to return nil for non-users can delete the override.
- **The gem's locale files can no longer override the host's.** The engine appended its
  `config/locales` to `config.i18n.load_path`, which Rails loads AFTER the app's own locale
  files — harmless while the directory was empty, but any shipped default would have silently
  beaten the host's translation of the same key. Rails already loads an engine's
  `config/locales` before the app's, so the initializer is gone.

## [1.0.0.beta2] - 2026-07-10

Second beta on the road to 1.0. Fixes beta1's async-adapter routing bug (the one
that forced hosts to hand-roll their own enqueue), makes Active Storage
attachments filterable with zero wiring, and gives `Flag` first-class close
methods. Drop-in upgrade from beta1: no migrations, no breaking API changes —
and hosts that worked around the ClassifyJob bug can now delete the workaround.

### Fixed

- **Async adapters now actually run in `Moderate::ClassifyJob`.** beta1's `:flag`
  after_commit called `Moderate.classify` inline for *every* adapter — including
  ones declaring `synchronous? == false` — so a remote moderation API ran its
  network call inside the request that saved the content, and `ClassifyJob`
  (whose docs promised this routing) was never enqueued by anything. The concern
  now checks `config.adapter_async?(policy.adapter)` (new public helper, same
  probe as the `:block` validator) and enqueues the job instead; the job re-reads
  the persisted value and files the Flag itself. Hosts that worked around this by
  enqueuing `ClassifyJob` themselves and short-circuiting
  `moderation_field_changed_for_commit?` can delete both workarounds. (#3)

### Added

- **Active Storage attachments filter out of the box.** `moderates :avatar, with:
  :your_image_adapter, mode: :flag` on a `has_one_attached` model needs zero extra
  wiring now: the concern snapshots `attachment_changes` in a `before_save` (AR
  dirty tracking can't see attachment writes, and Active Storage clears the
  changes before after_commit), consumes the snapshot at commit time, and both
  the concern and `ClassifyJob` treat an unattached `ActiveStorage::Attached`
  proxy as blank (nothing to classify — covers purge-between-enqueue-and-run).
  The three `moderation_field_*` seam overrides remain for richer cases. (#3)
- **Flag close sugar.** `Flag#action!(note:, by: nil)` / `Flag#dismiss!(note:, by: nil)` —
  model-level closes mirroring `Report#resolve!`/`#dismiss!`, so hosts stop hand-writing
  status updates. `by:` stays nil for automated closes (don't fake a human in the audit
  trail). Canonical automated use: dismiss a pending flag whose flagged content was
  **superseded** (text edited, photo replaced/reverted) — left pending it keeps `flagged?`
  true and mislabels the NEW content in any host UI keyed on it. (#4)

## [1.0.0] - unreleased

A complete, ground-up rewrite. `moderate` graduates from a single-purpose profanity
validator (0.1.0) into a full **Trust & Safety** engine for Rails apps with user-generated
content: report, block, filter, a moderation queue, appeals, and EU DSA / App Store / Google
Play **aligned** primitives. (First cut shipped as `1.0.0.beta1`; second as `1.0.0.beta2`.)

> **Breaking:** 1.0 keeps the gem name but is an entirely new API. The 0.x profanity
> validator (`validates :field, moderate: true`) still loads for backward compatibility
> (see _Upgrading from 0.x_), but everything else is new. Pin `~> 0.1` if you relied on the
> old behavior and are not ready to adopt the new surface.

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
