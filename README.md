# 🛡️ `moderate` - Trust & Safety for your Rails app (report, block, filter, comply)

[![Gem Version](https://badge.fury.io/rb/moderate.svg)](https://badge.fury.io/rb/moderate) [![Build Status](https://github.com/rameerez/moderate/workflows/Tests/badge.svg)](https://github.com/rameerez/moderate/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=moderate)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=moderate)!

`moderate` gives your Rails app a complete **Trust & Safety** layer — let users **report** abusive content, **block** each other, **filter** objectionable text and images before they're posted, and run a **moderation queue** your admins actually use. It ships **DSA-compliant** (EU Digital Services Act) and aligned with the **Apple App Store** and **Google Play** review guidelines for user-generated content, so you stop leaving store approvals and legal exposure to chance.

It reads like plain English. Make any model reportable:

```ruby
class Comment < ApplicationRecord
  reportable
end
```

Let any user block another:

```ruby
current_user.block!(@other_user)
current_user.blocks?(@other_user)   # => true
```

Filter content before it's ever saved — one line:

```ruby
class Message < ApplicationRecord
  moderates :body            # blocks profanity/slurs/threats by default; or :flag for review
end
```

And give admins a real queue to act on:

```ruby
Moderate::Report.pending           # everything awaiting a decision
report.resolve!(by: current_user, remove_content: true, ban_user: true, note: "Hate speech")
```

That's the whole idea: **the messy, legally-loaded plumbing every social/UGC app needs — report, block, filter, moderate, appeal, comply — as one coherent, Ruby-esque gem** instead of scattered, half-finished, store-rejecting DIY code.

> [!NOTE]
> `moderate` is **UI-agnostic by design**: most Trust & Safety lives in *admin* surfaces, so the gem ships the **primitives** (models, services, helpers, controller concerns) and lets you **bring your own UI**. It plugs into [`madmin`](https://github.com/excid3/madmin) (or any admin) in minutes — see [Admin & moderation queue](#-admin--the-moderation-queue). It also snaps into the rest of the ecosystem: [`goodmail`](https://github.com/rameerez/goodmail) for decision emails, [`telegrama`](https://github.com/rameerez/telegrama) for admin alerts, and [`noticed`](https://github.com/excid3/noticed) for multi-channel notifications — all through one `notify` hook.

---

## Why this gem exists

Every app with user-generated content eventually faces the same wall. A user posts something vile, another user wants them gone, Apple rejects your build for "no way to report objectionable content," and a Spanish lawyer emails you about the Digital Services Act. So you start bolting on a `reports` table, a `blocks` table, a profanity regex, an admin page, a "notify the reporter" email… and it's suddenly a sprawling, half-correct subsystem entangled with your core app.

It's the kind of plumbing nobody wants to build, everybody rebuilds, and almost everybody ships *incomplete* — which is exactly what gets apps rejected from the stores and exposed under the DSA. `moderate` is the single, opinionated, batteries-included source of truth for it:

- **Report** users and content (in-app), with evidence snapshots and a real decision workflow.
- **Block** users (bidirectional), enforced everywhere a blocked pair could reconnect.
- **Filter** text and images before they're posted (`:off` / `:block` / `:flag`), with pluggable backends — a built-in offline wordlist, plus ready-to-copy reference adapters in `examples/` (OpenAI, AWS Rekognition) or your own.
- **Moderate** from a queue: remove content, ban users, dismiss, all audited.
- **Comply**: DSA notice-and-action (Art. 16), statement of reasons (Art. 17), internal appeals (Art. 20), transparency counters (Art. 24); Apple Guideline 1.2 and Google Play UGC requirements.

It works standalone, and gets better with the rest of the ecosystem.

## What `moderate` does and doesn't do

**Does:**
- User & content **reporting** (in-app) + a public **DSA legal-notice** intake form.
- **Blocking** with a single source-of-truth query you enforce in search, messaging, profiles, anywhere.
- **Pre-publication content filtering** with three modes and pluggable adapters — the built-in offline wordlist (text), plus image/LLM moderation via reference adapters you register (see `examples/`).
- A **moderation queue** with audited resolve / dismiss / remove-content / ban actions.
- **Appeals**, **statement-of-reasons** notifications, and **transparency** aggregation for the DSA.
- Optional **audit** and **notification** hooks that fan out to your mailer / admin alerts / push.

**Doesn't** (on purpose — these are other tools' jobs):
- Authentication / current-user (that's Devise — you tell `moderate` your user class).
- Sending the actual emails/push (that's [`goodmail`](https://github.com/rameerez/goodmail) / [`noticed`](https://github.com/excid3/noticed) — `moderate` just emits events).
- The admin UI chrome (that's [`madmin`](https://github.com/excid3/madmin) / your app — `moderate` gives you the data + primitives).
- A bulletproof ML classifier out of the box (the default text filter is a fast, multilingual wordlist; bring an LLM/image adapter when you want one).

---

## Quickstart

Add the gem:

```ruby
gem "moderate"
```

Install it (creates the migration + an initializer):

```bash
bundle install
rails generate moderate:install
rails db:migrate
```

Tell `moderate` who your users are, and make a model reportable:

```ruby
# config/initializers/moderate.rb
Moderate.configure do |config|
  config.user_class = "User"
end
```

```ruby
class User < ApplicationRecord
  has_moderation_capabilities # can report, block, be blocked, be banned
end

class Message < ApplicationRecord
  reportable         # can be reported
  moderates :body    # …and filtered before it's saved
end
```

That's it — you now have reporting, blocking, filtering, and a moderation queue. Everything below is detail.

---

## 🧑‍🤝‍🧑 Actors: report & block

Add `has_moderation_capabilities` to your user model (or any model that acts on behalf of a person):

```ruby
class User < ApplicationRecord
  has_moderation_capabilities
end
```

*(Prefer an explicit include? `include Moderate::Actor` is the exact equivalent — the macro just lazily includes it.)*

**Blocking** is a bidirectional safety edge — once either side blocks, neither should see or reach the other:

```ruby
current_user.block!(@other)     # idempotent; audited; fires your on_block hook
current_user.unblock!(@other)
current_user.blocks?(@other)    # I blocked them
current_user.blocked_by?(@other)
current_user.blocked_with?(@other)   # either direction — the one you check in features
```

Enforce it anywhere with the single source-of-truth query (no hand-rolled block SQL ever again):

```ruby
# Hide blocked people from a marketplace / search / inbox:
Post.where.not(user_id: Moderate.blocked_ids_for(current_user))
```

**Reporting** content or a person:

```ruby
current_user.report!(@message, category: :harassment, details: "Won't stop messaging me")
current_user.report!(@user,    category: :impersonation)
```

`moderate` snapshots the offending content at report time (so evidence survives edits/deletes), infers who's responsible, sends the reporter a receipt, and drops it in the queue.

## 🚩 Reportable content

Declare what can be reported with one `reportable` line — the fields are optional (omit them to report the whole record):

```ruby
class Listing < ApplicationRecord
  reportable :title, :description

  # Tell moderate how to present & clean this content when a moderator acts:
  def moderation_label = "Listing #{id}"
  def reported_owner   = user                # who's responsible (defaults sensibly)
end
```

*(Explicit-include equivalent: `include Moderate::Reportable` + `reportable_fields :title, :description`.)*

You get:

```ruby
listing.reports          # reports filed against this record
listing.reported?        # any open report?
listing.flagged?         # any pending system (auto-filter) flag?
```

Drop a report link into any view with the helper (it renders nothing if the viewer can't report the content):

```erb
<%= moderate_report_link(@listing, field: :description) %>
```

Adding a new reportable type is one `reportable` line — the intake, queue, snapshot, and admin code never change.

## 🧪 Content filtering: `:off` / `:block` / `:flag`

Filtering is one declaration per field, with three modes:

```ruby
class Message < ApplicationRecord
  moderates :body                       # uses the default mode (see config)
end

class Profile < ApplicationRecord
  moderates :bio,    mode: :block       # reject the save if it trips the filter
  moderates :avatar, mode: :flag, with: :image   # `:image` = a registered adapter (see examples/); only :wordlist ships built in
end
```

- **`:off`** — no check.
- **`:block`** — the write is rejected with a validation error (great for public, high-trust fields).
- **`:flag`** — the write **succeeds**, and a `Moderate::Flag` is created **after commit** for human or automated review (great for DMs, where you don't want to block mid-conversation).

Why this matters: `:flag` never lives in a validator (validators must be side-effect-free, and a flag created inside a rolled-back transaction would silently vanish) — `moderate` handles that correctly for you.

Check content directly anywhere:

```ruby
result = Moderate.classify("some sketchy text")
result.allowed?    # => false
result.categories  # => [:hate, :"hate/threatening"]
result.scores      # => { "hate" => 0.97, "hate/threatening" => 0.81 }   (0..1 for service adapters)
result.labels      # => [#<Label category: :hate, subcategory: :threatening, score: 0.81, input: :text>, …]
```

### Filter adapters (the built-in wordlist, reference adapters, your own — one interface)

Every backend implements the same tiny contract — `classify(value) → Moderate::Result` — so they're interchangeable per field. `moderate` ships exactly **one** built-in adapter, the offline `:wordlist`; OpenAI, AWS Rekognition, and anything else are **bring-your-own** — copy a ready-made reference adapter from [`examples/`](examples/), add its gem to *your* Gemfile, and `register_adapter` it:

| Adapter | Use it for | Notes |
| --- | --- | --- |
| `:wordlist` (built-in, default) | text | Fast, multilingual, offline, zero-dependency. Unicode + leetspeak + spacing-evasion resistant. Ships `en`/`es` lists; add your own. The only adapter the gem ships. |
| OpenAI (reference adapter — [`examples/openai_moderation_adapter.rb`](examples/openai_moderation_adapter.rb)) | **text *and* image** | OpenAI `omni-moderation-latest` via the `ruby_llm` gem — **free**, multimodal, its category set IS the canonical taxonomy + `0..1` scores. Copy it in, `gem "ruby_llm"`, `register_adapter(:openai, …)`. Runs **async** (`Moderate::ClassifyJob`) in `:flag` mode. |
| AWS Rekognition (reference adapter — [`examples/aws_rekognition_adapter.rb`](examples/aws_rekognition_adapter.rb)) | images / avatars | `detect_moderation_labels` via `aws-sdk-rekognition`, with its taxonomy mapped onto the canonical labels. Copy it in, `gem "aws-sdk-rekognition"`, `register_adapter(:rekognition, …)`. Async, `:flag` mode. |
| *your own* | anything | `register_adapter(:replicate, …)` / Perspective / a self-hosted model — any object responding to `classify`. No built-in pretends the backend must be an "LLM". |

All adapters map their provider labels onto **one canonical taxonomy** (OpenAI's: `harassment[/threatening]`, `hate[/threatening]`, `sexual[/minors]`, `self-harm[/intent|/instructions]`, `violence[/graphic]`, `illicit[/violent]`), so `Moderate::Flag`, the DSA statement of reasons, and the transparency counters all speak one vocabulary.

```ruby
Moderate.configure do |config|
  config.default_filter_mode = :block
  config.filter_adapter      = :wordlist

  # Bring an external classifier: copy examples/openai_moderation_adapter.rb into
  # your app, add `gem "ruby_llm"`, then register and use it by name.
  config.register_adapter :openai, OpenAIModerationAdapter.new

  config.filter "Message", :body,   with: :wordlist, mode: :flag
  config.filter "Profile", :avatar, with: :openai,   mode: :flag   # one adapter moderates text AND images
end
```

> **`:block` requires a synchronous adapter** (`:wordlist`) — you can't reject a save on a background result. The async reference adapters (the OpenAI/Rekognition examples) declare `synchronous? == false`, so they run in `:flag` mode (allow the write, classify in a job, file a `Moderate::Flag`). `moderate` validates this for you and says so.

Bring your own adapter — it's just an object that responds to `classify`:

```ruby
class MyAdapter
  def classify(value) = Moderate::Result.new(allowed: ..., categories: [...], scores: {...})
end
Moderate.register_adapter(:my_adapter, MyAdapter.new)
```

> The original `moderate` (≤ 0.1) was *only* a profanity validator. That `validates :field, moderate: true` one-liner still works — it's now the `:wordlist` adapter in `:block` mode. See [Upgrading from 0.x](#upgrading-from-0x).

## 🛠️ Admin & the moderation queue

Most of Trust & Safety happens in admin. `moderate` gives you the primitives; you bring the UI.

```ruby
Moderate::Report.pending             # the report queue
Moderate::Flag.pending               # the auto-filter queue (human OR ML consumer reads the same scope)
Moderate::Appeal.pending             # appeals awaiting a human

report.resolve!(by: admin, remove_content: true, ban_user: false, note: "Removed: hate speech")
report.dismiss!(by: admin, note: "No violation")
appeal.uphold!(by: admin, note: "...")   # overturns the decision
appeal.reject!(by: admin, note: "...")
```

Every action is atomic, requires a moderator + a note, runs your enforcement (content removal via the reportable's own `remove_reported_field!`, bans via your `ban_handler`), and writes to your audit log.

### Use it from a controller (BYOUI)

```ruby
class Admin::ReportsController < ApplicationController
  include Moderate::Moderation   # resolve!/dismiss! actions, strong params, redirects

  before_action :require_admin
end
```

### Integrate with [`madmin`](https://github.com/excid3/madmin)

`moderate`'s models are plain ActiveRecord, so they show up in `madmin` like anything else. Generate a resource and point it at the model:

```bash
rails generate madmin:resource Moderate::Report
```

Then wire the resolve/dismiss actions to `Moderate::Report#resolve!`/`#dismiss!` from a custom member action (full walkthrough in [`docs/madmin.md`](docs/madmin.md)). The same pattern works for `Moderate::Flag` and `Moderate::Appeal`.

## 🔔 Notifications & 🧾 audit — one hook each

`moderate` never sends an email or writes to *your* audit log directly. It **emits events** through two hooks you wire once — so notifications fan out wherever you want, and important actions are recorded however you want.

```ruby
Moderate.configure do |config|
  # Called for every important action — wire it to your audit system (or leave it; it no-ops):
  config.audit = ->(event) { AuditLog.record!(event_type: event.name, data: event.payload) }

  # Called for every notifiable event — fan out to email / admin Telegram / push / in-app:
  config.notify = ->(event) do
    case event.name
    when :report_received, :report_decision, :affected_user_decision
      ModerationMailer.with(event:).public_send(event.name).deliver_later   # goodmail
    when :content_flagged, :report_received
      Telegrama.send_message("🚩 #{event.payload[:summary]}")               # admin alert
    end
  end

  # Optional side effects when a block happens (e.g. tear down a pending invite):
  config.on_block = ->(blocker:, blocked:, at:) { CancelPendingInvites.call(blocker, blocked, at: at) }
end
```

Events carry a stable envelope (`event.name`, `event.subject`, `event.recipients`, `event.actor`, `event.payload`), so a single `notify` hook can drive **goodmail** (user emails), **telegrama** (admin alerts), and **noticed** (in-app feed + push) at once. Notify users via email/in-app **and** ping admins on Telegram from the same place. (Recipes in [`docs/notifications.md`](docs/notifications.md).)

The full event vocabulary: `report_received`, `report_decision`, `affected_user_decision`, `appeal_received`, `appeal_decision`, `user_blocked`, `user_unblocked`, `user_banned`, `content_flagged`, `content_removed`.

## ⚖️ DSA & app-store compliance, out of the box

`moderate` is built around the rules so you don't have to read the regulation:

- **DSA Art. 16 (notice & action):** a public, electronic notice form — a mountable engine you place at the path of your choosing (`mount Moderate::Engine => "/trust"`, no hardcoded `/legal`) — capturing the substantiated reason, exact URL, notifier name+email, good-faith statement, the EU **statement-of-reasons taxonomy**, and the member-state selector, with an automatic confirmation of receipt. A notice is a `Moderate::Report` with `intake_kind: "dsa"` (no separate model), built via `Moderate::Services::IntakeNotice`. The form prefills the reported-content fields from query params (editable) and a signed-in notifier's identity (locked), and auto-integrates [`rails_cloudflare_turnstile`](https://github.com/instrumentl/rails-cloudflare-turnstile) when present (falling back to a `config.notice_guard` proc, with an optional per-request skip hook for clients that cannot render a browser challenge). See [`docs/dsa-notice-form.md`](docs/dsa-notice-form.md).
- **DSA Art. 17 (statement of reasons):** decision notices state the action, the legal/contractual ground, whether automated means were used, and the redress path.
- **DSA Art. 20 (appeals):** a free, electronic internal complaint mechanism, open ≥ 6 months, decided by a human.
- **DSA Art. 24 (transparency):** counters you can publish (notices received, actions taken, median handling time, appeal outcomes).
- **Apple Guideline 1.2 & Google Play UGC:** filter-before-post, in-app report **and** block, ongoing moderation, published contact — `moderate` covers all four. See the mapped checklist in [`docs/compliance.md`](docs/compliance.md).

> Two taxonomies, on purpose: an in-app **community report** category set (harassment, spam, …) and a separate, regulator-aligned **DSA legal-reason** taxonomy for public notices. `moderate` ships both. The community set is host-customizable via `config.report_categories`; the DSA legal-reason taxonomy is regulator-defined and fixed.

## 🤓 Why the models?

`rails generate moderate:install` creates four tables:

- **`moderate_reports`** — a report/notice + an immutable evidence snapshot + decision metadata + the appeal window. Serves both in-app reports and public DSA notices (distinguished by `intake_kind`).
- **`moderate_blocks`** — the bidirectional `blocker`/`blocked` edge, with a self-block check and the SSOT relation behind `Moderate.blocked_ids_for`.
- **`moderate_flags`** — system/auto-filter flags (source: `text_filter` / `image_filter` / `external_classifier` / `manual`), with the classifier's labels + scores; the queue both human admins and ML consumers read via `pending`.
- **`moderate_appeals`** — DSA Art. 20 internal complaints against a decision.

> The value-list taxonomies (community `category`, `status`, `content_type`, the DSA `legal_reason`/`legal_country_code`, `resolution_basis`, plus `Flag` source/mode/status and `Appeal` source/status) are validated **in the models** — frozen constants + ActiveModel `inclusion` validations — **not** by database `CHECK` constraints. That means **adding or customizing a label never requires a migration**: the community category list is host-overridable via `config.report_categories` (defaults to `Moderate::Report::DEFAULT_CATEGORIES`), and the gem can grow its own taxonomies in a point release without touching your schema. The only value guard kept at the DB level is a cheap message-length backstop; everything else the migration adds is structural (NOT NULLs, FKs, the unique block edge, and the self-block CHECK).

The migration is **adaptive**: it matches your app's primary-key type (UUID or bigint) and JSON column type (`jsonb` / `json`) automatically, so it drops cleanly into any Rails 7.1+ schema.

## Configuration reference

```ruby
Moderate.configure do |config|
  config.user_class        = "User"          # who reports/blocks/gets banned
  config.default_filter_mode = :block        # :off / :block / :flag
  config.filter_adapter    = :wordlist       # default text adapter

  config.audit       = ->(event) { ... }     # optional; no-op by default
  config.notify      = ->(event) { ... }     # optional; no-op by default
  config.on_block    = ->(blocker:, blocked:, at:) { ... }   # optional
  config.ban_handler = ->(user:, by:, reason:) { user.suspend! }   # how a "ban" is applied in your app

  config.filter "Message", :body, with: :wordlist, mode: :flag
end
```

Reportable classes are auto-discovered from the `reportable` macro (or `include Moderate::Reportable`) — no manual registry.

## Upgrading from 0.x

`moderate` 1.0 is a ground-up rewrite: the old gem was a profanity validator; 1.0 is a full Trust & Safety system. The one piece of the old API that remains is the validator, now backed by the `:wordlist` adapter:

```ruby
validates :body, moderate: true     # still works — equivalent to `moderates :body, mode: :block`
```

Everything else is new. There's no automated data migration (0.x stored nothing). See [`CHANGELOG.md`](CHANGELOG.md).

## Testing

We use Minitest. Run the suite (a dummy Rails app under `test/dummy`, against SQLite/PostgreSQL/MySQL via Appraisals):

```bash
bundle exec rake test
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run `rake test`. You can also run `bin/console` for an interactive prompt.

To install this gem onto your local machine, run `bundle exec rake install`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/moderate. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
