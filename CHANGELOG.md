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
- **Labels for every value list the gem defines, in English and Spanish.**
  `Moderate.taxonomy_label(kind, value)` names a community category, a DSA legal reason, an
  EU member state, a content type, a resolution basis, a decision, an intake kind, a report /
  flag / appeal status, a flag source or mode, or an appeal source in the current locale, from
  `moderate.<scope>.<value>` (scopes in `Moderate::TAXONOMY_LABEL_SCOPES`), falling back to
  the value humanized so a host's own category or adapter name still renders. The gem's
  `config/locales/{en,es}.yml` now carry every value, and a host's translation wins. The
  public notice form, which always read `moderate.legal_reasons/content_types/member_states`,
  now shows real copy in both languages. **`Moderate::Report.category_options`** gives a
  report form's select its `[label, value]` pairs, honoring `config.report_categories`. Hosts
  that translated the regulator's vocabulary themselves can drop their copies for en/es.
- **"Report and block": `report!(…, block: true)`** blocks the person responsible for the
  content once the report is filed, through the one block path (idempotent, audited,
  `on_block`, `user_blocked`). `Report#block_reported_user`, which has existed since beta1
  and which nothing read, is what it sets. Nothing is blocked when the content has no person
  behind it.
- **Reports know what kind of content they're about.** A community report with no
  `content_type` takes the reportable's `moderation_content_type` (with or without the field
  argument, since chats' takes none), stored if it is one of `Report::CONTENT_TYPES`, else
  `"other"`, so a host's own word never fails an intake. `Moderate::Reportable` defines it
  (nil) and `Moderate::Actor` answers `"user_profile"`. Hosts that mapped their models to
  content types in the report controller can delete the map.
- **`Reportable#to_moderation_sgid`** and the view helper
  **`moderate_report_target_path(record, field:)`**: the signed report target and the report
  form's path, public and non-expiring, for markup rendered once for many viewers (a chat
  bubble broadcast to everyone in the thread, a fragment cache), where
  `moderate_report_link`'s per-viewer check can't run. The helper always probed for
  `to_moderation_sgid`; now it exists. Hosts building
  `to_sgid_param(for: Moderate::Report::SIGNED_GLOBAL_ID_PURPOSE)` by hand can use these
  (without `expires_in: nil`, that token changed on every render and died after a month).
- **The `content_removed` event is emitted.** It was in the documented vocabulary from
  beta1 and nothing sent it. A decision whose `remove_reported_field!` removed something now
  audits `content_removed` inside the decision's transaction and announces it with the
  decision notices, to the content's person, with `reported_field`, its label and the
  moderator's reason. (`notice_received`, which the DSA form has always sent, joins the
  vocabulary lists in the README, the configuration guide and the initializer.)
- **`examples/regexp_pattern_adapter.rb`**: a reference adapter for what a word list can't
  express (phone numbers, links, "contact me on…"), each pattern filed under the category it
  means, synchronous so `:block` works too, the matched fragments in `raw[:matches]`. The
  idea is @killondark's (#1, written against the 0.x validator).
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

- **A ban needs a `ban_handler`.** With none configured, `ban_user: true` (on a report or a
  flag) and `Moderate.apply_ban` raise `Moderate::ConfigurationError` before anything
  changes. Before, the default no-op handler let the decision record
  `decision_visibility: "account_suspended"`, audit and announce `user_banned`, and send the
  person a statement of reasons saying their account was suspended, while nothing had
  suspended it: a false Art. 17 statement. `config.ban_handler = nil` restores the default;
  a non-callable raises `ArgumentError`; `config.ban_handler_configured?` tells. Decisions
  without a ban are unaffected. **Behavior change** for hosts that never wired one and
  relied on the no-op.
- **An in-app report is refused when its reporter may not report the content.** A community
  report filed by a signed-in person now validates the reportable's own `report_visible_to?`
  (never your own content; for a chats message, only a conversation you're in), with an
  error on `:reportable` ("isn't something you can report",
  `moderate.errors.not_reportable_by_reporter`). The report link always hid itself on that
  rule, and chats' docs said moderate re-checks it server-side, but nothing did: a signed
  target replayed or pasted from elsewhere reached the model unchecked. DSA notices and
  system reports (no reporter) are not affected. **Behavior change:** a host that files
  community reports on behalf of people who couldn't see the content now gets a validation
  error; use a manual flag (`Flag.flag_for_review!`) for an administrator's own concern.

### Fixed

- **`moderate_report_target_path` (and `moderate_report_link`) find the host's report route
  from inside another engine's views**, through `main_app`. Rendered in a chats slot, the
  helper fell back to the hard-coded `/reports/new`.
- **The transparency page labels its counters from the gem's own keys.** Two of its cards
  read `moderation.legal_reasons.*` / `moderation.resolution_bases.*`, a namespace from the
  app the gem was extracted from that no other part of the gem uses; the rest printed raw
  values humanized. Every card now goes through `Moderate.taxonomy_label`.
- **`Moderate.blocked_ids_for(nil)` returns the same type as every other call**: an empty
  relation selecting user ids, not `[]`. Composing the two shapes was a real bug in a host
  (`relation | array` yields User records, and `include?(id)` silently missed). Call `.ids`
  for an Array.
- **`Report#pending?` and `Appeal#pending?`** exist, twins of the `pending` scopes all three
  queues share (`docs/madmin.md` called them and they didn't exist).
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

### Documentation

- **`docs/chats.md`**: the whole chats integration from moderate's side (reportable and
  filtered messages, blocks, Report on a broadcast bubble, Block in the thread menu, the
  admin side, a launch checklist), the shape two production hosts converged on.
- **`docs/madmin.md` runs as written.** It called `scope :resolved` (the scopes are
  `actioned`), `attribute :kind` / `:details` (the columns are `intake_kind` / `message`),
  `report.pending?` (now real), `Moderate.system_actor` (never existed; automated decisions
  pass `by: nil`) and `flag.scores[:csam]` (scores are JSON with string keys, and the
  canonical category is `sexual/minors`). The flag controller now shows enforcement, and a
  new section covers "Flag for review" from a browse screen.

### Upgrading from 1.0.0.beta2

No migrations. Check these against your app:

1. **Wire `config.ban_handler`** if any moderator can press "ban": without one, a ban now
   raises instead of being a silent no-op.
2. **Reports are visibility-checked.** If you file community reports with a `reporter:` who
   couldn't see the content, they now fail validation. Use `Flag.flag_for_review!` for an
   administrator's own concern.
3. **Delete the workarounds this release makes unnecessary**, if you wrote them:
   - a `reported_owner` override that returns nil for non-users;
   - a find-or-create-report bridge for removing or banning from a flag (use
     `flag.action!(remove_content:, ban_user:)`);
   - a hand-assembled manual `Flag.flag!` (use `Flag.flag_for_review!`);
   - a model-to-`content_type` map in your report controller;
   - your own "report and block" (use `report!(…, block: true)`);
   - `to_sgid_param(for: Moderate::Report::SIGNED_GLOBAL_ID_PURPOSE)` (use
     `to_moderation_sgid` or `moderate_report_target_path`);
   - en/es translations of the gem's taxonomies and field names (keep only the ones you
     changed);
   - a duplicated `config.filter` next to a `moderates` declaration for the same field.
4. **`Flag#action!` re-closing** an already decided flag no longer overwrites the first
   decision: it returns the flag as it was.
5. **`Moderate.blocked_ids_for(nil)`** is an empty relation, not `[]`. Call `.ids` if you
   need an Array.

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
