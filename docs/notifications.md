# Notifications — wire email, in-app, and admin alerts once

`moderate` never sends an email, never posts to Telegram, never writes a push. It does exactly one thing with notifications: it **emits events**. You wire those events to wherever they should go — **once** — and everything downstream (a report receipt, a decision email, an admin "🚩 new flag" ping, an in-app feed item) flows from that single hook.

That hook is `config.notify`:

```ruby
Moderate.configure do |config|
  config.notify = ->(event) { ... }   # called for every notifiable event; no-op by default
end
```

One lambda. Every notifiable thing that happens in your Trust & Safety layer passes through it. Inside it you `case` on `event.name` and fan out to:

- **[`goodmail`](https://github.com/rameerez/goodmail)** — beautiful transactional **emails** to the *user* (report receipt, decision / statement-of-reasons, appeal outcome).
- **[`telegrama`](https://github.com/rameerez/telegrama)** — a one-line Telegram **admin alert** (a new report landed, content got auto-flagged, a DSA notice arrived).
- **[`noticed`](https://github.com/excid3/noticed)** — multi-channel **in-app feed + push** to the user.

The whole point: **notify users by email and in-app, AND optionally ping yourself on Telegram, all wired in one place.** No notification logic scattered across your models, services, and controllers — `moderate` collects every moment worth telling someone about and hands them to you with a stable envelope.

> [!NOTE]
> `config.notify` is for **people** (users get emails/push, admins get a Telegram nudge). It's separate from `config.audit`, which is for **machines** (append-only record of every action for your audit log). Same envelope, different intent — see [Audit](#audit-the-other-hook) at the bottom. Most apps wire both, in the same initializer, in about fifteen lines.

---

## TL;DR — the one recipe

```ruby
# config/initializers/moderate.rb
Moderate.configure do |config|
  config.notify = ->(event) do
    # 1) Email the user (goodmail) — receipts, decisions, statements of reasons.
    case event.name
    when :report_received, :report_decision, :affected_user_decision,
         :appeal_received, :appeal_decision, :notice_received
      Array(event.recipients).each do |user|
        next unless user.respond_to?(:email)   # anonymous DSA notifiers carry an email, not a User
        ModerationMailer.with(event: event, recipient: user)
                        .public_send(event.name)
                        .deliver_later
      end
    end

    # 2) Ping admins on Telegram (telegrama) — ONE message, only for things YOU care about.
    case event.name
    when :report_received, :notice_received, :content_flagged
      Telegrama.send_message(event.payload[:summary], formatting: { obfuscate_emails: true })
    end

    # 3) In-app feed + push (noticed) — the user's bell icon and device.
    case event.name
    when :report_decision, :affected_user_decision, :appeal_decision,
         :user_banned, :content_removed
      Moderate::DecisionNotifier.with(event: event).deliver(event.recipients)
    end
  end
end
```

That's the entire integration. Three `case`s, one per channel, in one lambda. Add or drop an `event.name` from any list to turn a channel on/off for that moment. The rest of this doc explains the envelope, the full vocabulary, and each channel in detail.

> [!IMPORTANT]
> **Keep `config.notify` fast.** It runs inside the same call as the moderation action (often inside a transaction). Always hand off to a background job — `deliver_later` (goodmail / Action Mailer), `perform_later` (your own jobs), or `Telegrama`'s async mode (below). Never do blocking HTTP in the hook itself.

---

## The event envelope

Every event your `notify` hook receives is the same small, stable object. You never construct it — `moderate` does — you only read it:

```ruby
event.name        # Symbol — which moment this is, e.g. :report_decision (the full list below)
event.subject     # the record this is about — a Moderate::Report / Flag / Block / Appeal / Notice
event.actor       # who triggered it — a moderator, a user, or nil for system/automated events
event.recipients  # Array of who should be told — usually the user(s) to email/notify
event.payload     # Hash of event-specific context, ALWAYS including :summary (a ready-to-send line)
event.to_h        # the whole envelope as a Hash (handy for logging, tests, and noticed params)
```

Two fields do most of the work:

- **`event.recipients`** — already resolved to *the right people* for this event. For `report_received` it's the reporter (their receipt). For `report_decision` it's the reporter (the outcome). For `affected_user_decision` it's the person whose content/account was acted on (their statement of reasons). You don't compute audiences — `moderate` does, and hands you the array. Iterate it.
- **`event.payload[:summary]`** — a short, human, already-redaction-safe one-liner describing what happened (e.g. `"New harassment report on Comment #4213 by joh…e@example.com"`). It exists so your **admin Telegram ping is literally one line** — no string-building, no leaking. Everything richer (the model, the category, the moderator's note) is also in `payload` if you want to compose your own copy.

A recipient is usually one of your `User` records (it responds to `email`, `id`, etc.), **except** for DSA-notice events (`notice_received`, and the `affected_user_decision` for a public notice) where the notifier may be an anonymous person — there `moderate` gives you a lightweight recipient that responds to `email`/`name` but is **not** a `User`. The `next unless user.respond_to?(:email)` / `user.is_a?(User)` guards in the recipes above handle that cleanly.

---

## The full event vocabulary

These are every event `moderate` can emit. Wire the ones you care about; ignore the rest (the hook is a plain `case` — unmatched names just fall through).

| Event | When it fires | `actor` | `recipients` | Typical channels |
| --- | --- | --- | --- | --- |
| `report_received` | A user files an in-app report | the reporter | the reporter (receipt) | 📧 user receipt · 💬 admin ping |
| `notice_received` | A public **DSA Art. 16** notice is submitted | the notifier (may be anonymous) | the notifier (Art. 16(4) confirmation of receipt) | 📧 confirmation · 💬 admin ping |
| `report_decision` | A moderator resolves/dismisses a report | the moderator | the reporter (outcome) | 📧 email · 🔔 in-app |
| `affected_user_decision` | A decision affects the reported party | the moderator | the reported user / notice subject (**statement of reasons**, Art. 17) | 📧 email · 🔔 in-app |
| `appeal_received` | A user appeals a decision (Art. 20) | the appellant | the appellant (receipt) | 📧 receipt · 💬 admin ping |
| `appeal_decision` | A moderator upholds/rejects an appeal | the moderator | the appellant | 📧 email · 🔔 in-app |
| `user_blocked` | One user blocks another | the blocker | — *(usually silent; no recipients)* | 🔕 audit only, typically |
| `user_unblocked` | A block is lifted | the blocker | — | 🔕 audit only, typically |
| `user_banned` | A user is banned (your `ban_handler` ran) | the moderator | the banned user | 📧 email · 🔔 in-app |
| `content_flagged` | The filter auto-creates a `Moderate::Flag` (`:flag` mode) | nil (system) | — *(no user; it's a queue item)* | 💬 admin ping |
| `content_removed` | Content is removed (via `remove_reported_field!`) | the moderator | the content's owner | 📧 email · 🔔 in-app |

A few notes that save you grief:

- **`content_flagged` has no user recipient.** It's the system telling *admins* "something needs a look" — there's nothing to email the author. Route it to Telegram (and/or your moderation dashboard), not to a user mailer. Its `recipients` is empty by design.
- **`report_decision` vs `affected_user_decision` are two events on purpose.** The same resolution tells the *reporter* "we handled your report" (one tone) and the *reported party* "here's what we did and why, and how to appeal" (the DSA Art. 17 statement of reasons — a different tone, different legal weight). Two events let you send two different emails from one moderator click.
- **Blocks are usually silent.** You rarely email "you've been blocked" (it invites retaliation). `user_blocked` / `user_unblocked` exist mostly for `config.audit`, but they're here in `notify` too if your product wants an in-app signal.

---

## Channel 1 — Email the user with [`goodmail`](https://github.com/rameerez/goodmail)

Receipts, decisions, and statements of reasons are exactly what `goodmail` is for: clean, single-template transactional email with zero HTML hell. Build one mailer keyed by event name and let `config.notify` call it.

```ruby
# config/initializers/moderate.rb
config.notify = ->(event) do
  case event.name
  when :report_received, :report_decision, :affected_user_decision,
       :appeal_received, :appeal_decision, :notice_received, :user_banned, :content_removed
    Array(event.recipients).each do |recipient|
      next unless recipient.respond_to?(:email) && recipient.email.present?
      ModerationMailer.with(event: event, recipient: recipient)
                      .public_send(event.name)
                      .deliver_later
    end
  end
end
```

```ruby
# app/mailers/moderation_mailer.rb
class ModerationMailer < ApplicationMailer
  # `event` and `recipient` arrive via `.with(...)` and are available as `params[:event]` / `params[:recipient]`.

  def report_received
    event = params[:event]
    goodmail_mail(to: params[:recipient].email, from: "trust@myapp.com",
                  subject: "We received your report") do
      h1 "Thanks — we're on it"
      text "We received your report and our team is reviewing it. You don't need to do anything else."
      info_row "Reference", event.subject.reference
      info_row "Filed",     event.subject.created_at.to_date.to_s
      sign
    end
  end

  def affected_user_decision
    event = params[:event]
    # DSA Art. 17 statement of reasons: action taken, the ground, automated-means flag, redress path.
    goodmail_mail(to: params[:recipient].email, from: "trust@myapp.com",
                  subject: "An update about your content") do
      h1 "We took action on your content"
      text event.payload[:reason]                       # the human-readable ground
      info_row "Action",          event.payload[:action]        # e.g. "Content removed"
      info_row "Automated means", event.payload[:automated] ? "Yes" : "No"
      space
      text "If you believe this was a mistake, you can appeal — it's free and reviewed by a person."
      button "Appeal this decision", event.payload[:appeal_url] # moderate mints a signed link for you
      sign
    end
  end

  def notice_received
    event = params[:event]
    goodmail_mail(to: params[:recipient].email, from: "legal@myapp.com",
                  subject: "Confirmation of your notice") do
      h1 "We received your notice"
      text "This confirms receipt of your notice under Article 16 of the Digital Services Act."
      info_row "Reference", event.subject.reference
      sign
    end
  end
end
```

Why this shape:

- **`.with(event:, recipient:)`** is the standard Action Mailer params path, so the same arguments survive `deliver_later` serialization (the event's records are GlobalID-serializable AR objects).
- **`public_send(event.name)`** lets the *event name* select the mailer action — `report_received` → `#report_received` — so adding a new email is "add a method," not "add a branch."
- **`goodmail_mail`** is goodmail's mailer helper: it renders the DSL block, wires `List-Unsubscribe`, and hands a normal multipart message to Action Mailer. Use its DSL (`h1`, `text`, `info_row`, `button`, `sign`, …) instead of ERB templates. `info_row`/`price_row` are perfect for the reference/date/action rows a decision email needs.
- **The appeal link** in a decision email is the signed link `moderate` mints for you (`config.signed_gid_purposes` includes `:appeal`); read it from `event.payload[:appeal_url]` rather than building your own route.

> [!TIP]
> Per-product or per-tenant branding? `goodmail_mail` accepts `config: { company_name:, brand_color:, logo_url: }` for a scoped, thread-local override — handy if your app is white-labeled. See goodmail's "Per-message branding."

---

## Channel 2 — Ping admins on Telegram with [`telegrama`](https://github.com/rameerez/telegrama)

This is the "tell *me* something happened" channel. `event.payload[:summary]` is built for it — a single, safe line — so the admin ping is genuinely one call:

```ruby
config.notify = ->(event) do
  case event.name
  when :report_received, :notice_received, :content_flagged, :appeal_received
    Telegrama.send_message(event.payload[:summary], formatting: { obfuscate_emails: true })
  end
end
```

That's it. `event.payload[:summary]` for `content_flagged` reads like:

> 🚩 Auto-flagged Message #8821 — categories: hate, threats

and for `report_received`:

> 🚩 New harassment report on Comment #4213 by joh…e@example.com

`obfuscate_emails: true` means even if a summary or your own copy contains a user's address, telegrama redacts it (`john.doe@x.com` → `joh…e@x.com`) before it hits a shared admin chat. Turn it on for anything touching user PII.

### Compose a richer alert when you want one

The `summary` is the fast path. When you'd rather build the message (the way you'd alert a sale), reach into `event.payload` and use telegrama's MarkdownV2 formatting:

```ruby
when :report_received
  report = event.subject
  msg = <<~MSG
    🚩 *New report*

    *Category:* #{report.category}
    *On:* #{report.reportable_label}
    *By:* #{event.actor&.email}

    [🔗 Open in moderation queue](#{Rails.application.routes.url_helpers.admin_report_url(report)})
  MSG
  Telegrama.send_message(msg, formatting: { obfuscate_emails: true })
```

### Route different alerts to different chats / topics

Got separate Telegram chats (or forum topics) for "trust & safety" vs "everything else"? telegrama takes `chat_id:` and `message_thread_id:` per message:

```ruby
TRUST_CHAT  = Rails.application.credentials.dig(:telegram, :trust_chat_id)
TRUST_TOPIC = Rails.application.credentials.dig(:telegram, :trust_topic_id)

when :content_flagged, :notice_received
  Telegrama.send_message(event.payload[:summary],
                         chat_id: TRUST_CHAT,
                         message_thread_id: TRUST_TOPIC,
                         formatting: { obfuscate_emails: true })
```

> [!TIP]
> Enable telegrama's **async delivery** (`config.deliver_message_async = true` in `config/initializers/telegrama.rb`) so admin pings never block a moderation action — this is the cleanest way to keep your `config.notify` hook fast for the Telegram leg. telegrama also degrades gracefully (MarkdownV2 → HTML → plain text), so a weird character in a user's content can't break the alert.

---

## Channel 3 — In-app feed + push with [`noticed`](https://github.com/excid3/noticed)

For decisions and outcomes that the *user* should see in your app's notification bell (and on their phone), `noticed` is the multi-channel fan-out. The event envelope drops straight into `Notifier.with(...).deliver(recipients)`:

```ruby
# config/initializers/moderate.rb
config.notify = ->(event) do
  case event.name
  when :report_decision, :affected_user_decision, :appeal_decision,
       :user_banned, :content_removed
    Moderate::DecisionNotifier.with(event: event.to_h).deliver(event.recipients)
  end
end
```

```ruby
# app/notifiers/moderate/decision_notifier.rb
class Moderate::DecisionNotifier < Noticed::Event
  deliver_by :database          # the in-app feed
  deliver_by :fcm do |config|   # push to devices
    config.credentials = Rails.application.credentials.fcm
    config.json { |notification| { title: "Moderation update", body: params.dig(:event, :payload, :summary) } }
  end

  notification_methods do
    def message = params.dig(:event, :payload, :summary)
    def url     = params.dig(:event, :payload, :url)
  end
end
```

Notes:

- Pass **`event.to_h`** (the Hash) rather than the raw event object to `noticed` — `noticed` serializes params to the database, and a plain Hash of GlobalID-able records and scalars stores cleanly. `event.payload[:summary]` doubles as the push body.
- `event.recipients` is already the correct audience, so `deliver(event.recipients)` needs no massaging.
- Same `:summary` you used for Telegram works as the push title/body — write the human line once, reuse it across channels.

> This is the [RailsFast Native](https://railsfast.com) path: `noticed` + `:fcm`/APNs gives you the in-app feed and native push from the same decision event, so a moderation outcome reaches the user on web and mobile without a second integration.

---

## Putting all three together (the full hook)

Here's the complete, production-shaped `config.notify` — email via goodmail, admin pings via telegrama, in-app + push via noticed — wired exactly once:

```ruby
# config/initializers/moderate.rb
Moderate.configure do |config|
  config.notify = ->(event) do
    # --- 1. Email the user (goodmail) ---------------------------------------
    case event.name
    when :report_received, :report_decision, :affected_user_decision,
         :appeal_received, :appeal_decision, :notice_received,
         :user_banned, :content_removed
      Array(event.recipients).each do |recipient|
        next unless recipient.respond_to?(:email) && recipient.email.present?
        ModerationMailer.with(event: event, recipient: recipient)
                        .public_send(event.name)
                        .deliver_later
      end
    end

    # --- 2. Ping admins on Telegram (telegrama) -----------------------------
    case event.name
    when :report_received, :notice_received, :content_flagged, :appeal_received
      Telegrama.send_message(event.payload[:summary], formatting: { obfuscate_emails: true })
    end

    # --- 3. In-app feed + push (noticed) ------------------------------------
    case event.name
    when :report_decision, :affected_user_decision, :appeal_decision,
         :user_banned, :content_removed
      Moderate::DecisionNotifier.with(event: event.to_h).deliver(event.recipients)
    end
  end
end
```

Every branch is independent: the same event can email a user **and** ping you on Telegram **and** drop into their in-app feed, or just one of those, depending on which lists you put its name in. One user-facing decision, one moderator click, three channels — no duplicate audience logic, no notification code in your models.

---

## Audit — the other hook

`config.notify` is for telling **people**. `config.audit` is for telling your **records**: an append-only log of every important action, with the *same* envelope, so compliance and forensics don't depend on whether an email went out.

```ruby
Moderate.configure do |config|
  config.audit = ->(event) do
    AuditLog.record!(
      event_type: event.name,
      actor:      event.actor,
      subject:    event.subject,
      data:       event.payload
    )
  end
end
```

`audit` fires for **every** event (including the silent ones like `user_blocked` that you usually don't notify on), it's append-only by intent, and it's where DSA **Art. 24 transparency counters** ultimately draw from (notices received, actions taken, appeal outcomes). Wire it once next to `notify` and you have both halves: humans get told, history gets kept.

> [!NOTE]
> Same envelope (`name` / `subject` / `actor` / `recipients` / `payload` / `to_h`), two destinations. Keep both hooks fast and side-effect-light; push real work (emails, HTTP, heavy writes) to background jobs.

## See also

- [Notifications & audit — one hook each](../README.md#-notifications---audit--one-hook-each) — the README overview
- [The DSA notice form](dsa-notice-form.md) — where `notice_received` (the Art. 16 confirmation of receipt) comes from
- [`goodmail`](https://github.com/rameerez/goodmail) · [`telegrama`](https://github.com/rameerez/telegrama) · [`noticed`](https://github.com/excid3/noticed) — the three destinations
