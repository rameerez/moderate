# Compliance: DSA, App Store, and Google Play — the checklist you hand to legal

Trust & Safety is the one part of your app where "I think we covered it" isn't good enough. A missing **block** button gets your build rejected by Apple. A missing **notice form** gets you a letter from a European regulator. A missing **appeal** path is a DSA violation with a fine attached. The rules are real, they're specific, and they're written by people who have never opened your codebase.

So this page does the boring, load-bearing work: it maps **every requirement** from the three regimes that actually gate a UGC app — the **EU Digital Services Act**, the **Apple App Store Review Guidelines**, and the **Google Play** developer policies — to the **exact `moderate` feature** that satisfies it, with the **test** that proves it. It's written to be **printed and handed to a lawyer or a store reviewer**: each row is a claim, and each claim has a receipt.

> [!NOTE]
> `moderate` gives you the **mechanisms** the law and the stores require — the report intake, the block edge, the filter, the queue, the appeal, the statement-of-reasons, the transparency counters, the public notice form. It cannot make your **policies** or **operations** compliant for you: you still have to publish a contact address, actually read the queue, and answer notices "in a timely manner." This checklist marks which is which — **[gem]** rows are done the moment you install; **[you]** rows are things only you can do, that the gem makes easy. Don't hand legal the **[gem]** column and call it a day.

> [!IMPORTANT]
> This is engineering documentation, not legal advice. It reflects the text of the **DSA (Regulation (EU) 2022/2065)**, the **App Store Review Guidelines**, and the **Google Play Developer Program Policies** as the gem was built against them. Regulations and store rules change; your obligations depend on your size, your users, and your content. Have your own counsel confirm the mapping before you rely on it.

---

## How to read this

Every checklist row has four columns:

| Column | What it means |
| --- | --- |
| **Requirement** | The specific obligation, quoted or closely paraphrased, with its article/guideline number. |
| **How `moderate` satisfies it** | The concrete feature, model, hook, or method that covers it. |
| **Who** | **[gem]** = built in, true the moment you install. **[you]** = your responsibility, made easy by the gem. **[gem + you]** = gem does the mechanism, you wire one hook or write one line. |
| **Proof** | The test in the suite (or the manual check) that demonstrates it. |

The **Proof** column points at `test/` paths. Run the whole thing with `bundle exec rake test`; the named files are your evidence that the mechanism actually works, not just that it's documented.

---

## 1. EU Digital Services Act (Regulation (EU) 2022/2065)

The DSA applies to any "hosting service" — which includes basically any app that stores user-generated content — **that serves recipients in the EU**, regardless of where you're based. The four articles that matter for a small/mid app (you are almost certainly **not** a "Very Large Online Platform," which carries extra duties this gem does not cover) are **16, 17, 20, and 24**. `moderate` is organized around exactly these.

> [!NOTE]
> **Scope honesty.** `moderate` targets the obligations that apply to ordinary hosting services and online platforms. It does **not** implement VLOP-only duties (risk assessments, independent audits, the transparency database submission, vetted-researcher data access, Art. 34–43). If you cross 45M monthly EU users, you have a much bigger compliance program than any gem — talk to specialists.

### Art. 16 — Notice and action mechanisms

> Providers shall put mechanisms in place to allow **any individual or entity** to notify them of allegedly illegal content, **by electronic means**, that are **easy to access and user-friendly**.

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| A public, **electronic** notice mechanism, open to **anyone** (not just logged-in users). | The mountable notice engine, mounted at the path of your choosing (e.g. `mount Moderate::Engine => "/trust"`), serves a public form at `<mount>/notices/new`. See [`docs/dsa-notice-form.md`](dsa-notice-form.md). | **[gem]** | `test/integration/notice_form_test.rb` |
| Notice contains a **sufficiently substantiated explanation** of why the content is illegal — Art. 16(2)(a). | `message` field, required and validated on `Moderate::Report` (a notice is a `Report` with `intake_kind: "dsa"`). | **[gem]** | `test/services/moderate/intake_notice_test.rb` |
| Notice contains the **exact electronic location** (URL) — Art. 16(2)(b). | `subject_url` (one or more), validated as an `http(s)` URL; the model resolves it to a reportable record for the evidence snapshot. | **[gem]** | `test/models/moderate/report_test.rb` |
| Notice contains the **name and email** of the notifier — Art. 16(2)(c). | `notifier_name` + `notifier_email`, required for `dsa` notices and email-validated. | **[gem]** | `test/models/moderate/report_test.rb` |
| **Anonymity carve-out**: name/email are **not** required for notices alleging certain offences against minors (CSAM and related, Art. 16(2)(c) proviso). | When `anonymous` is set and `legal_reason` is `protection_of_minors`, the model **waives** the `notifier_name`/`notifier_email` requirement; any other anonymous notice is rejected. | **[gem]** | `test/models/moderate/report_test.rb` |
| A **good-faith statement** that the information is accurate and complete — Art. 16(2)(d). | `good_faith_confirmed` (acceptance); the save is rejected unless it's truthy. | **[gem]** | `test/models/moderate/report_test.rb` |
| **Confirmation of receipt**, sent to the notifier **without undue delay** — Art. 16(4). | `Moderate::Services::IntakeNotice` stamps the report's `acknowledged_at` and fires the `notice_received` event through `config.notify`; you wire it to your mailer once (e.g. `goodmail`) for the receipt, and the form shows an on-screen confirmation flash. | **[gem + you]** | `test/services/moderate/intake_notice_test.rb` |
| Notice the provider that the decision **and** the redress options are communicated — Art. 16(5). | Acting on the report (resolve/dismiss) emits `report_decision` (and `affected_user_decision`) carrying the statement of reasons; see Art. 17 below. | **[gem + you]** | `test/services/moderate/resolve_report_test.rb` |
| Decisions taken in a **timely, diligent, non-arbitrary and objective manner** — Art. 16(6). | The notice lands in `Moderate::Report.pending` — the same queue as in-app reports — with full evidence; you act on it. The gem records who decided, when, and why (mandatory moderator + note on every action). | **[gem + you]** | `test/services/moderate/resolve_report_test.rb` |

> [!TIP]
> Don't want to mount the engine? You can build your own public page and call `Moderate::Services::IntakeNotice` (which persists a `Moderate::Report` with `intake_kind: "dsa"`) directly — every Art. 16 validation, the snapshot, the durable `acknowledged_at` receipt, and the `notice_received` event still apply. Mounting is the fast path; the service is the full-control path. See [Staying optional](dsa-notice-form.md#staying-optional-ignore-the-engine-entirely).

### Art. 17 — Statement of reasons

> Where a provider restricts content, it shall provide a **clear and specific statement of reasons** to the affected recipient.

The statement must include, at minimum: the **restriction imposed** (and its scope), the **facts and circumstances** relied on, whether **automated means** were used, the **legal or contractual ground**, and information on **redress** (internal complaints, out-of-court dispute settlement, judicial remedy).

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| State the **specific restriction** imposed and its scope (content removed? account suspended?). | Every resolution records its action (`remove_content:`, `ban_user:`) and emits `affected_user_decision` with that action in `event.payload`. | **[gem]** | `test/services/moderate/resolve_report_test.rb` |
| State the **facts and circumstances** relied on. | The immutable **evidence snapshot** taken at report time travels with the decision; the moderator's mandatory `note:` is the human-readable ground. | **[gem]** | `test/models/moderate/report_test.rb` |
| State whether **automated means** were used in detection or decision — Art. 17(3)(c). | Reports/flags carry their `source` (`text_filter`, `image_filter`, `external_classifier`, or `manual`). A decision acting on an auto-`Moderate::Flag` is flagged as automated-means in the `affected_user_decision` payload; a human report is not. | **[gem]** | `test/services/moderate/resolve_report_test.rb` |
| State the **legal or contractual ground**. | For DSA notices, the `legal_reason` (from `Moderate::Report::DSA_LEGAL_REASONS`) is the legal ground; for in-app reports, the community `category` + your `note:` is the contractual (terms-of-service) ground. Both ride in the decision payload. | **[gem + you]** | `test/services/moderate/resolve_report_test.rb` |
| Communicate **redress** options (internal complaint, out-of-court, judicial). | The `affected_user_decision` event carries the appeal entry point; you render the redress text in your decision email (the gem ships the data; the copy is yours, because it names your jurisdiction). | **[gem + you]** | `test/services/moderate/resolve_report_test.rb` |
| Deliver the statement to the **affected recipient** (the content owner), not just the reporter. | Two distinct events fire: `report_decision` → the **reporter**; `affected_user_decision` → the **content owner** (resolved via the reportable's `reported_owner`). You wire both. | **[gem + you]** | `test/services/moderate/resolve_report_test.rb` |

> [!NOTE]
> **Why two decision events.** Art. 16(5) wants the **notifier** informed; Art. 17 wants the **affected user** informed — they are different people with different rights. `moderate` keeps them separate (`report_decision` vs `affected_user_decision`) so your one `notify` hook sends the right message to the right person. Collapsing them into one email is a classic DSA mistake. See [Notifications](../README.md#-notifications---audit--one-hook-each).

### Art. 20 — Internal complaint-handling system (appeals)

> Providers shall provide recipients with access to an **effective internal complaint-handling system**, **free of charge**, for at least **six months** after a decision, with complaints handled in a **timely, non-discriminatory, diligent and non-arbitrary manner** and **not solely on automated means**.

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| An **internal** appeal mechanism against moderation decisions. | `Moderate::Appeal` — a complaint filed against a resolved report/notice; the queue is `Moderate::Appeal.pending`. | **[gem]** | `test/models/moderate/appeal_test.rb` |
| **Free of charge.** | There is no charge anywhere in the appeal path — it's just a record + a queue. (You simply don't bill for it.) | **[gem]** | n/a (no payment code exists in the path) |
| Open for **at least six months**, counted from the day the person **is informed** of the decision (Art. 20(2)). | Each report stores its **appeal window** (`appeal_deadline_at`): six months from the decision (a minimum: the notice says "at least until"), moved to six months from delivery when your notifier confirms the notice actually went out (`Moderate.delivered!`, which stamps `decision_notified_at` / `affected_user_notified_at` once), never earlier. A queued mail doesn't count. `Moderate::Appeal` refuses a complaint filed after it; one filed in time is decided whenever the review ends. | **[gem]** | `test/models/moderate/appeal_window_test.rb`, `test/models/moderate/appeal_test.rb` |
| Decisions **reversible** — uphold the complaint and reverse the action. | `appeal.uphold!(by:, note:)` overturns the original decision (and runs the reverse enforcement); `appeal.reject!(by:, note:)` confirms it. | **[gem]** | `test/services/moderate/resolve_appeal_test.rb` |
| **Not solely automated** — a human decides the complaint. | `uphold!`/`reject!` **require** a `by:` moderator and a `note:`; there is no path to auto-decide an appeal. | **[gem]** | `test/services/moderate/resolve_appeal_test.rb` |
| Inform the complainant of the **appeal decision** and remaining redress (out-of-court / judicial). | Resolving an appeal emits `appeal_decision` to the complainant; you render the out-of-court / judicial redress copy. | **[gem + you]** | `test/services/moderate/resolve_appeal_test.rb` |

### Art. 24 — Transparency reporting

> Providers shall publish, at least **once a year**, reports on their content moderation, including the **number of notices** received, **action taken**, **use of automated means**, and **complaints** received and their outcomes.

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| Count of **notices received** (by type/ground). | `Moderate.transparency` aggregates `moderate_reports` by `intake_kind` and `legal_reason`/`category`. | **[gem]** | `test/integration/transparency_report_test.rb` |
| Count of **actions taken** (removals, bans, dismissals). | The same aggregation tallies resolutions by action and dismissals. | **[gem]** | `test/integration/transparency_report_test.rb` |
| **Median handling time** (notice → decision). | Computed from each report's received-at vs decided-at timestamps. | **[gem]** | `test/integration/transparency_report_test.rb` |
| Use of **automated means** in moderation. | Counts of decisions acting on auto-`Moderate::Flag`s vs human reports, from the `source` column. | **[gem]** | `test/integration/transparency_report_test.rb` |
| **Appeals** received and their **outcomes** (upheld / rejected). | Aggregation over `moderate_appeals` by status. | **[gem]** | `test/integration/transparency_report_test.rb` |
| **Publish** the report (at least annually). | The gem produces the numbers; **you** publish them (a `/transparency` page, a PDF, whatever) — only you know your reporting period and format. | **[you]** | manual: render `Moderate.transparency(from:, to:)` |

> [!TIP]
> `Moderate.transparency(from: 1.year.ago, to: Time.current)` returns a plain hash you can drop straight into a view, a JSON endpoint, or a rake task that emails it to you each January. The counters are the regulator-aligned ones — same taxonomy as the notice form (`Moderate::Report::DSA_LEGAL_REASONS`) — so the published numbers line up with the intake.

---

## 2. Apple App Store — Guideline 1.2 (User-Generated Content)

Apple is blunt: an app with UGC that lacks these gets **rejected**, and rejection is the most common reason a social/community app fails review. Guideline 1.2 lists four mechanisms; **all four are required**, and reviewers test them by hand during review.

> Apps with user-generated content … must include: **(a)** a method for **filtering objectionable material** from being posted, **(b)** a mechanism to **report** offensive content and timely responses to concerns, **(c)** the ability to **block abusive users**, and **(d)** **published contact information** so users can easily reach you.

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| **(a)** A method to **filter objectionable material** before it's posted. | `moderates :field` with `mode: :block` rejects the offending write before save; the default `:wordlist` adapter is a fast offline baseline, and you can register an image / remote adapter for stronger checks. | **[gem]** | `test/integration/content_filtering_test.rb` |
| **(b)** A mechanism to **report** offensive content. | `current_user.report!(content, category:)` in-app; reportable content exposes `reports`, `reported?`, `flagged?`; the `moderate_report_link` helper drops the button into any view. | **[gem]** | `test/models/moderate/reportable_test.rb`, `test/integration/reporting_test.rb` |
| **(b)** **Timely responses** to reports. | The report lands in `Moderate::Report.pending` with a snapshot; the reporter gets a `report_received` receipt immediately, and a `report_decision` when you act. (Acting promptly is on you — the gem surfaces the queue and the events.) | **[gem + you]** | `test/services/moderate/intake_report_test.rb` |
| **(c)** The ability to **block abusive users**. | `current_user.block!(other)` — bidirectional, idempotent, audited; enforce it everywhere with the single `Moderate.blocked_ids_for(user)` query. | **[gem]** | `test/models/moderate/block_test.rb` |
| **(d)** **Published contact information** to reach the developer. | The notice-engine root (`/legal`) is a natural home for your contact/abuse address; the gem gives you the page, **you** publish the address (Apple wants a real human-reachable contact). | **[gem + you]** | manual: contact shown in-app + on the notice page |

> [!IMPORTANT]
> **Guideline 1.2 also expects an EULA acknowledgement** for UGC apps: users must agree there's **no tolerance for objectionable content or abusive behavior**. That's a one-line acceptance in your signup/terms — `moderate` doesn't own your terms screen, but the **community-report categories** (`:harassment`, `:spam`, …) are what your EULA's "objectionable content" clause should enumerate, so the words match the buttons. Keep your terms and your report categories in sync.

> [!TIP]
> When you respond to App Review's inevitable "show us your moderation" question, point them at: the in-app **Report** button (1.2b), the **Block** action on a profile (1.2c), the fact that a banned-word post is **rejected** (1.2a), and your **contact** link (1.2d). Those are the four taps a reviewer makes. The rows above are the four they correspond to.

---

## 3. Google Play — User-Generated Content policy

Google Play's UGC policy overlaps heavily with Apple's but is explicit about **two things Apple states more loosely**: blocking/reporting must cover **both users and content**, and you must do **ongoing** moderation (not just provide the buttons). It also requires an in-app way to **accept terms / acceptable-use** before contributing UGC.

> Apps with UGC must: provide an in-app system for **reporting and blocking objectionable users and content**; provide a method to **moderate UGC**; and require users to **accept the app's terms of use / user policy** before creating or uploading UGC.

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| In-app **reporting** of objectionable **content**. | `current_user.report!(content, category:)`; any model that is reportable can be reported. | **[gem]** | `test/models/moderate/reportable_test.rb` |
| In-app **reporting** of objectionable **users**. | A user model with `has_reporting_and_blocking` is itself reportable: `current_user.report!(other_user, category: :impersonation)`. | **[gem]** | `test/models/moderate/report_test.rb` |
| In-app **blocking** of objectionable **users**. | `current_user.block!(other)` — the bidirectional safety edge. | **[gem]** | `test/models/moderate/block_test.rb` |
| In-app **blocking / hiding** of objectionable **content**. | Filter the blocked pair's content out of any feed with `Moderate.blocked_ids_for(current_user)` — the single source-of-truth query you apply in search, inbox, and listings. | **[gem]** | `test/integration/blocking_test.rb` |
| A method to **moderate UGC** (a real review surface, not just intake). | `Moderate::Report.pending` / `Moderate::Flag.pending` give admins the queue; `resolve!`/`dismiss!`/`remove_content`/`ban_user` are the audited actions. (BYOUI — you bind these to your admin; see [`docs/madmin.md`](madmin.md).) | **[gem + you]** | `test/services/moderate/resolve_report_test.rb` |
| **Ongoing** moderation, including proactive detection. | Pre-publication filtering (`moderates`) catches content at write time; `:flag` mode queues borderline content for review **after commit**; both feed the same admin queue. The mechanism is continuous, not one-shot. | **[gem]** | `test/integration/content_filtering_test.rb` |
| Users **accept terms / acceptable-use** before contributing UGC. | This is your signup/terms gate — `moderate` doesn't own it — but, as with Apple, your acceptable-use policy should enumerate the **community-report categories** so the terms and the report buttons describe the same prohibited behavior. | **[you]** | manual: terms acceptance in your onboarding |

> [!NOTE]
> **"Both users and content" is the row people miss.** Plenty of apps add a "Report comment" button and stop there. Play wants you to be able to report **and** block **both** a person and a thing. `moderate` covers all four cells because a user model with `has_reporting_and_blocking` is *also* reportable, and blocking is enforced over content via `blocked_ids_for`. If you only made content reportable and never made users blockable, you'd pass Apple's spot check and still fail Play's policy.

---

## 4. The one-page summary (hand this to legal)

If you read nothing else, this is the table that says "we did the thing."

| Regime | Obligation | `moderate` mechanism | Status |
| --- | --- | --- | --- |
| **DSA Art. 16** | Public electronic notice + confirmation of receipt | Notice engine (`mount Moderate::Engine`) + `notice_received` event | ✅ gem (+ wire 1 mailer) |
| **DSA Art. 17** | Statement of reasons (action, ground, automated-means, redress) | `affected_user_decision` event carrying action + ground + source + appeal path | ✅ gem (+ wire 1 mailer) |
| **DSA Art. 20** | Free internal appeals, ≥ 6 months, human-decided | `Moderate::Appeal` + 6-month window + `by:`/`note:`-required `uphold!`/`reject!` | ✅ gem |
| **DSA Art. 24** | Annual transparency report | `Moderate.transparency` counters | ✅ gem (you publish) |
| **Apple 1.2(a)** | Filter objectionable content | `moderates :field, mode: :block` | ✅ gem |
| **Apple 1.2(b)** | Report + timely response | `report!` + `Report.pending` + `report_decision` | ✅ gem (you respond) |
| **Apple 1.2(c)** | Block abusive users | `block!` + `blocked_ids_for` | ✅ gem |
| **Apple 1.2(d)** | Published contact | `/legal` page | ✅ gem (you publish address) |
| **Play UGC** | Report + block, **users and content** | `report!`/`block!` on users; reportable + `blocked_ids_for` on content | ✅ gem |
| **Play UGC** | Ongoing moderation surface | `Flag.pending` + `:flag`-mode filtering | ✅ gem (you review) |
| **Play UGC** | Accept terms before UGC | your onboarding gate | ⬜ you (categories align) |
| **GDPR Art. 5(1)(e)** | Don't keep personal data longer than needed | `Moderate.purge` (opt-in, keeps decisions; see [Retention](#5-retention-what-moderate-keeps-and-for-how-long)) | ✅ gem (you schedule it) |

Legend: **✅ gem** — the mechanism ships and is tested. **⬜ you** — your operational/policy step that the gem makes straightforward.

> [!WARNING]
> A green checklist is necessary, not sufficient. The stores and the DSA judge you on **behavior over time** — that you actually read the queue, answer notices, and decide appeals — not just that the buttons exist. `moderate` makes every one of those actions a one-liner with a built-in audit trail (`config.audit`), so doing the operational work is cheap. **Do it.** The mechanisms keep you compliant only if you keep using them.

---

## 5. Retention: what `moderate` keeps, and for how long

**Out of the box, nothing is purged.** The gem never deletes or redacts a moderation record on its own: every report, notice, flag, appeal and block stays exactly as it was written until you remove it, or until you schedule the opt-in purge below. That is a safe default for evidence and an unsafe one for privacy, so decide on a retention period and wire the purge before you launch in the EU.

### What the gem stores

| Table | What a row holds | Personal data in it |
| --- | --- | --- |
| `moderate_reports` | An in-app report or a DSA notice: category, legal ground, member state, content type; the reporter's message; an **evidence snapshot** (a copy of the reported text, the reported URLs, the reported account identifier, taken at intake so it survives edits); the **decision** (status, basis, actions, moderator note, decision visibility, automated-means disclosure, appeal deadline, notification timestamps); which earlier decision removed its content while it was pending (`covered_by_report_id`). | reporter, reported user, notifier name and email, message, snapshot, URLs |
| `moderate_flags` | A filter, classifier or manual flag: source, mode, categories, scores; an **excerpt** of the content (up to 500 characters); **context** (the classifier's raw response, a reviewer's note); the review. | owner, excerpt, context |
| `moderate_appeals` | An Art. 20 complaint: the reason, the appellant's name and email, a snapshot of the decision appealed, the outcome and its note. | appellant, name, email, reason |
| `moderate_blocks` | One blocker → blocked edge and when it was made. | both people |
| `moderate_classifications` | Bookkeeping for attachment classification: which record and field, a digest of the attached blob ids, who is classifying it (a claim) and when it was classified, the adapter and whether it flagged. | none beyond the record's id |

**Notices** (receipts, statements of reasons, appeal decisions) are not stored by the gem: it emits events and your mailer sends them. It only stamps when your notifier confirms one went out (`Moderate.delivered!`: `decision_notified_at`, `affected_user_notified_at`). Whatever your mailer or `config.audit` keeps is yours to retain or purge.

Rows go away by themselves only through ordinary associations: deleting a user destroys their blocks and nullifies them as reporter or reported user on reports (`Moderate::Actor`); deleting reported content nullifies the report's pointer to it (the evidence snapshot stays).

### What the law expects, in plain words

Not legal advice, and your national law and your own policies may add to it:

- **Keep the decision and its evidence while it can be challenged.** A decision must stay appealable for at least six months (DSA Art. 20), an appeal filed in time is decided whenever the review ends, and afterwards the person may still take it to an out-of-court dispute settlement body (Art. 21) or a court.
- **Keep the decision itself for longer.** It is the statement of reasons (Art. 17); it is what a repeat-misuse policy (Art. 23: suspending people who frequently post manifestly illegal content) looks back on; and the annual transparency report (Art. 15, 24) counts notices, actions, automated means, complaints and handling times for a whole reporting period, published after it ends.
- **Don't keep the personal data longer than that purpose needs** (GDPR Art. 5(1)(c) and (e): data minimisation, storage limitation). The copy of the reported content, the notifier's contact details and the complaint text have done their job once the decision can no longer be challenged. A person may ask for erasure (GDPR Art. 17); the exceptions for legal obligations and legal claims (Art. 17(3)(b) and (e)) are what let you keep a decision that is still contestable.

So: content copies and contact details get a short life, decisions and counts a long one. That split is what the purge implements.

### `Moderate.purge`: opt in

```ruby
Moderate.purge(older_than: 1.year)
# => { reports: 12, flags: 40, appeals: 1, classifications: 300, claims_kept: 0,
#      held: { reports: 1, flags: 2, appeals: 0 } }
Moderate.purge(older_than: 18.months, dry_run: true) # the same counts, changes nothing
```

**`1.year` is a default, not a rule.** GDPR storage limitation asks for a period set by *your* purposes (how long a decision can be challenged where you operate, your repeat-misuse policy, your national rules), so set `older_than` to the period your privacy policy states; the gem only refuses one shorter than the six-month appeal window.

```bash
bin/rails moderate:purge                              # OLDER_THAN_DAYS=365 by default
bin/rails moderate:purge OLDER_THAN_DAYS=540 DRY_RUN=1
```

Schedule it like any recurring job (cron, `config/recurring.yml` for Solid Queue, `sidekiq-cron`): `Moderate.purge` is safe to run every night. The rake task prints what it redacted and what it kept for a legal hold.

**Legal holds.** When a decision is under external redress (an out-of-court dispute settlement body, DSA Art. 21; a court case; an authority's request), hold that report and the nightly purge leaves it, its appeals and the flags on its content alone until the date you give:

```ruby
Moderate.hold(report, until: 1.year.from_now, by: admin, reason: "ODS case 2026-114")
report.held?                                # => true
Moderate.release_hold(report, by: admin)    # the dispute ended; the next purge treats it normally
```

Holding again moves the date; a hold that expires lifts itself. Both are audited (`:legal_hold_placed`, `:legal_hold_released`), and `dry_run` counts held rows under `:held` so you can see what a hold is keeping.

| It redacts | Only when | It keeps |
| --- | --- | --- |
| **Reports and notices**: the message (→ `"[redacted]"`), the evidence snapshot, the reported URLs and account identifier, the notifier's name and email, the reporter. | The report is closed, was decided more than `older_than` ago, its appeal window has closed, no appeal on it is open, and it isn't held. | Every row; category, legal ground, member state, content type, status, timestamps; the whole decision (basis, actions, note, visibility, automated-means disclosure); the reported user. |
| **Flags**: the excerpt (→ `"[redacted]"`) and the context. | The flag was decided more than `older_than` ago, and no held report is about its content and field. | Every row; source, mode, categories, scores, status, the owner, the review. |
| **Appeals**: the reason (→ `"[redacted]"`) and the appellant's name and email. | The appeal was decided more than `older_than` ago, and its report isn't held. | Every row; status, outcome note, timestamps, the appellant's account. |
| **Classification rows** (`moderate_classifications`): deleted, not redacted (nothing in them is evidence). | Last touched more than `older_than` ago, and not under a live claim (a worker classifying those files right now; counted under `:claims_kept`). | — |

Guarantees, each with a test in `test/models/moderate/retention_test.rb`:

- **Never** a pending report, flag or appeal, a report still inside its appeal window, a report with an open appeal, or anything a legal hold keeps, whatever their age. `older_than` below the six-month appeal window raises.
- A redacted row is stamped `redacted_at`, and the purge selects on that column, never on the content: a message that literally reads `"[redacted]"` is purged like any other.
- `Moderate.transparency` returns the same numbers before and after a purge, so a published report stays reproducible.
- **Blocks are never touched**: they are live safety state, not a record of the past.
- Idempotent (a second run finds nothing to do), `dry_run: true` only counts, and a run that changed something is audited as `:retention_purged` with the counts and the cutoff.
- One `UPDATE` per batch of 500, with no callbacks or validations: a redacted DSA notice no longer has the notifier details its validations require, and a final record should not be re-saved.

What it does **not** do, on purpose:

- **Delete rows.** The default `1.year` keeps every decision forever, as pseudonymous rows that still name the reported account. If your policy says decisions go after N years, delete them yourself once the transparency report that counts them is published: `Moderate::Report.where.not(status: "open").where(resolved_at: ...N.years.ago).destroy_all` (appeals go with their report).
- **Answer an erasure request.** Whether a given person's records must go now, or can be kept for a legal claim, is a decision for you and your counsel; the records are plain Active Record (`Moderate::Report.where(reporter: user)`, `Moderate::Appeal.where(appellant_email: email)`, `Moderate::Flag.where(owner: user)`).
- **Know about disputes by itself.** The gem can't see an out-of-court or court case; when one starts, `Moderate.hold` the report.

| Requirement | How `moderate` satisfies it | Who | Proof |
| --- | --- | --- | --- |
| Keep decisions contestable for ≥ 6 months (Art. 20) and while an appeal is open. | `Moderate.purge` never touches a record inside its appeal window or with an open appeal, and refuses an `older_than` below it. | **[gem]** | `test/models/moderate/retention_test.rb` |
| Keep what the annual transparency report counts (Art. 15, 24). | Redaction keeps every row and every counted column; `Moderate.transparency` is unchanged by a purge. | **[gem]** | `test/models/moderate/retention_test.rb` |
| Storage limitation for personal data (GDPR Art. 5(1)(e)). | `Moderate.purge` / `moderate:purge` redacts content copies and contact details from final records. | **[gem + you]** schedule it, choose `older_than` | `test/models/moderate/retention_test.rb` |
| Keep evidence during external redress (Art. 21, courts, authorities). | `Moderate.hold(report, until:)` keeps the report, its appeals and the flags on its content out of the purge. | **[gem + you]** place the hold | `test/models/moderate/retention_test.rb` |
| A written retention period, erasure requests. | Out of scope for a gem: your privacy policy and your counsel decide (`older_than` is yours to set). | **[you]** | manual |

---

## See also

- [`docs/dsa-notice-form.md`](dsa-notice-form.md) — the public Art. 16 notice form, in depth (mount, fields, Turnstile gate, the `moderate:views` eject)
- [DSA & app-store compliance](../README.md#️-dsa--app-store-compliance-out-of-the-box) — the README overview these tables expand on
- [Notifications & audit](../README.md#-notifications---audit--one-hook-each) — wiring `notice_received` / `*_decision` so Art. 16(4) and Art. 17 are actually delivered
- [Admin & the moderation queue](../README.md#️-admin--the-moderation-queue) — `resolve!`/`dismiss!`/`uphold!` and the audit trail behind every decision
