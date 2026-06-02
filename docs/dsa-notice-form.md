# The DSA notice form — a mountable, X-style legal-notice intake

The EU **Digital Services Act, Article 16 ("Notice and action")** says every hosting service that serves EU users must offer a **public, electronic** way for *anyone* — not just logged-in users — to flag illegal content, and must **acknowledge receipt** of that notice. This is the form you see at the bottom of X, YouTube, Reddit: "Report illegal content (EU)". It is a hard requirement, it is separate from your in-app "Report" button, and it is exactly the kind of legally-loaded plumbing `moderate` exists to take off your plate.

So `moderate` ships it as a **mountable Rails engine**: one line in your routes and you have a compliant, public notice form. The form, the controller, the model, the bot gate, the rate-limit, and the confirmation-of-receipt are all done for you. The default view is plain, accessible, and CSS-framework-agnostic — and it's **overridable the way Devise does it**: run one generator to eject the templates into your app and style them to match your brand.

It is also **completely optional**. If you'd rather build the public notice page yourself (you already have a design system, you want it inside an existing controller, whatever), don't mount the engine — use `Moderate::Report` (with `intake_kind: "dsa"`) directly and skip everything below. The engine is a convenience, not a dependency.

> [!NOTE]
> This is the **public, regulator-facing** form (DSA Art. 16). It is *not* the in-app "Report this comment" button (that's `current_user.report!(...)` from [the Actors section](../README.md#-actors-report--block)) and it is *not* the admin moderation queue (that's BYOUI — `moderate` gives you the primitives). Two intakes, one `moderate_reports` table, distinguished by `intake_kind`. See [why the models](../README.md#-why-the-models).

---

## TL;DR

```ruby
# config/routes.rb
# The engine's routes are RELATIVE — YOU choose the mount path. The gem hardcodes no
# prefix; pick whatever reads right for your app (/trust, /moderation, /dsa, …).
mount Moderate::Engine => "/trust"   # => form at /trust/notices/new
```

```ruby
# config/initializers/moderate.rb
Moderate.configure do |config|
  config.notice_form_enabled = true                # default; flip to false to hard-disable the engine
  config.notice_rate_limit   = { max: 5, within: 1.hour }   # per-IP throttle
  # Bot gate: install the rails_cloudflare_turnstile gem (below) and it auto-integrates —
  # nothing to set here. Or wire any other check with config.notice_guard.
end
```

That's it — `GET /trust/notices/new` renders the form, `POST /trust/notices` validates + persists a `Moderate::Report` with `intake_kind: "dsa"`, fires the `notice_received` notification (your confirmation-of-receipt email + admin alert), and redirects back with a confirmation message. The durable, on-record proof of receipt (Art. 16(4)) is the report's `acknowledged_at` timestamp.

The form also **prefills and partially locks** itself from the request (see [Prefill & lock](#prefill--lock-art-162b-c)), and **auto-uses the `rails_cloudflare_turnstile` gem** as a bot gate when it's installed (see [The bot gate](#the-bot-gate-auto-integrates-rails_cloudflare_turnstile)) — both with zero extra wiring.

Want to restyle it? Eject the views, then edit them:

```bash
rails generate moderate:views
# => creates app/views/moderate/notices/new.html.erb (and friends) in YOUR app
```

---

## Why an engine (and why like Devise)

Most of `moderate` is deliberately **UI-agnostic** — Trust & Safety lives in admin surfaces, and we don't presume to own your admin chrome. The DSA notice form is the **one exception**, for three reasons:

1. **It must exist and it must be public.** Unlike the admin queue (which you'd build anyway), the Art. 16 form is a legal must-have that has nothing to do with your product UI. Shipping it means most apps get compliant with one line instead of researching the regulation.
2. **The fields are dictated by law, not by you.** The legal-reason taxonomy, the good-faith statement, the "exact URL" requirement, the EU member-state selector — these come straight from the DSA. There's no product decision to make, so there's nothing to design. We can ship a correct default.
3. **You still own the look.** A bundled-but-overridable view is the best of both: it works out of the box, and you can make it yours without forking the gem.

That third point is the **Devise pattern**, and we copy it on purpose because every Rails developer already understands it:

| Devise | `moderate` |
| --- | --- |
| `mount` is implicit via `devise_for` | `mount Moderate::Engine => "/<your-path>"` |
| Views ship inside the gem | Views ship inside the engine (`app/views/moderate/notices/`) |
| `rails g devise:views` copies them to your app | `rails g moderate:views` copies them to your app |
| `config.parent_controller` | `config.parent_controller` |
| Rails view lookup prefers `app/views` over the gem | identical — an ejected view **shadows** the bundled one, zero config |
| Works untouched if you never eject | Works untouched if you never eject |

The magic in both is the same boring Rails fact: **the host app's `app/views` sits ahead of any engine's view paths in the lookup chain.** So when you run `moderate:views` and a file appears at `app/views/moderate/notices/new.html.erb`, Rails renders *yours* instead of the gem's — no registration, no config flag, no monkey-patch. Delete your copy and the gem's default comes back.

---

## How it mounts

`Moderate::Engine` is an **isolated** engine (`isolate_namespace Moderate`), so its routes, controllers, helpers, and table prefixes never collide with your app. Its routes are declared **relative** — the engine only owns `resources :notices` (and a root that redirects to the form) — so **you choose the mount path**; the gem hardcodes nothing:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Moderate::Engine => "/trust"     # form at /trust/notices/new
  # ...your app routes
end
```

Pick whatever path reads right for your app — there is no special "/legal" prefix baked in:

```ruby
mount Moderate::Engine => "/trust"        # → /trust/notices/new
mount Moderate::Engine => "/moderation"   # → /moderation/notices/new
mount Moderate::Engine => "/dsa"          # → /dsa/notices/new
mount Moderate::Engine => "/legal"        # → /legal/notices/new   (also fine — your call)
```

The engine's routes (in the gem, you never write these):

```ruby
# config/routes.rb inside the engine
Moderate::Engine.routes.draw do
  resources :notices, only: %i[new create]
  root to: "notices#new"
end
```

- `GET  <mount>/notices/new` — the form
- `POST <mount>/notices` — submit (validate + persist + confirm receipt); on success it redirects back to the form with a confirmation flash
- `GET  <mount>` — the engine root redirects to the form

There is no per-notice `show`/receipt page: a notice is a `Moderate::Report` with no public, enumerable identifier, so we never expose one over a guessable URL. The confirmation of receipt is delivered out-of-band through the `notice_received` notify hook (your email), and the durable proof is the report's `acknowledged_at` timestamp.

Link to it from your footer using the engine's named routes (mounted engines expose a helper named after the mount, here `moderate`):

```erb
<%= link_to "Report illegal content (EU)", moderate.new_notice_path %>
```

> [!TIP]
> Want the canonical "DSA point of contact" page the regulation also asks for (Art. 11/12)? The engine root is a fine place to host a short page that links to the form and lists your contact address — but that's content, not code, so we leave the copy to you. Eject the views and edit `new.html.erb`'s intro block.

---

## Prefill & lock (Art. 16(2)(b)/(c))

The form **prefills itself from the request**, X-style, so a notifier doesn't have to copy-paste what they're flagging — and it **locks the fields it shouldn't let them edit**.

### Reported-content prefill (from the query string, stays editable)

Deep-link to the form from any piece of content and pass the details in the query string. The param names are the gem's documented contract:

| Query param | Prefills | Maps to (Report column) | DSA |
| --- | --- | --- | --- |
| `content_url` | the exact URL field | `subject_url` | Art. 16(2)(b) — "the exact electronic location" |
| `content_type` | the content-type select | `content_type` | the host-agnostic bucket for the snapshot/queue |
| `content_author` | the account/handle field | `reported_account_identifier` | optional host-side identity of the content |
| `content_id` | the account/handle field (fallback if no `content_author`) | `reported_account_identifier` | optional host-side identifier |

```erb
<%= link_to "Report this (EU notice)",
      moderate.new_notice_path(
        content_url:    request.original_url,
        content_type:   "message",
        content_author: @author.username
      ) %>
```

These are the **reported-content** fields, so they stay fully **editable** — the notifier may correct the URL, change the content type, etc. `content_type` is only echoed when the query value is one the model would actually accept (a crafted `?content_type=<script>` is ignored), so a query param can't pre-poison the select.

### Identity prefill + lock (from Devise `current_user`, locked)

The form is public and anonymous-friendly, but when someone **is** logged in we prefill their **name/email** from `current_user` (detected safely — the gem never hard-depends on Devise; it checks `respond_to?(:current_user)`). Those **identity** fields are then rendered **readonly (locked)** so a logged-in notifier can't put someone else's name/email on a legal notice — and the controller **re-asserts identity server-side** on submit, so even a tampered request that re-enables the field can't spoof it. For an anonymous notifier (no `current_user`) the name/email fields are blank and editable — they're the only identity there is.

---

## The controller / model boundary

We keep the split clean and obvious — the controller does HTTP, the model does Trust & Safety.

### `Moderate::Report` (intake_kind: "dsa") — the model (does the real work)

A notice is **not a fourth table**. It's a `Moderate::Report` distinguished by `intake_kind: "dsa"` — the same table that backs in-app reports. This is on purpose: a notice and a report share the same decision workflow, the same evidence snapshot, the same appeal window, the same transparency counters. One queue, one statement-of-reasons path, one Art. 24 aggregation — whether the flag came from a logged-in user tapping "Report" or an anonymous lawyer filling in the public form. The `Moderate::Services::IntakeNotice` service forces that DSA shape and runs the shared intake (save + acknowledge + audit + the `notice_received` event).

```ruby
# Conceptually (the real model/service live in the gem; this is the contract you rely on):
intake = Moderate::Services::IntakeNotice.new(
  attributes: {
    legal_reason:        "intellectual_property",   # from the DSA taxonomy (see below)
    legal_country_code:  "ES",                        # ISO-3166 EU/EEA selector
    content_type:        "message",                   # host-agnostic CONTENT_TYPES bucket
    subject_url:         "https://yourapp.com/p/123", # Art. 16(2)(b) exact location
    message:             "This post reproduces my copyrighted photo without licence.",
    notifier_name:       "Jane Doe",
    notifier_email:      "jane@example.com",
    good_faith_confirmed: "1"                          # Art. 16(2)(d), must be checked
  }
)
intake.save                # → persisted as a moderate_reports row, intake_kind: "dsa", status: "open"
intake.report.acknowledged_at   # → set; the durable Art. 16(4) proof of receipt
```

The model owns: validations (every required DSA field, a real email, an `http(s)`-URL check, the good-faith attestation being true, the narrow `protection_of_minors` anonymity carve-out), the immutable evidence snapshot (it tries to resolve `subject_url` to a reportable record and snapshot it, so evidence survives edits/deletes), and dropping into `Moderate::Report.pending` so your admins act on it exactly like any other report. The service fires the `notice_received` event through `config.notify` — that's your confirmation-of-receipt to the notifier **and** your admin alert, from one hook.

> [!NOTE]
> "Confirmation of receipt without undue delay" (Art. 16(4)) is satisfied two ways: the durable record is `acknowledged_at` (a database fact, set before any email is attempted), and the human-facing confirmation is the `notice_received` event → your mailer. The gem emits the event; you wire it to [`goodmail`](https://github.com/rameerez/goodmail) (or any mailer) once, the same way you wire `report_received`. See [Notifications](../README.md#-notifications---audit--one-hook-each).

### `Moderate::NoticesController` — the controller (does HTTP only)

The controller is intentionally boring. It builds a prefilled (and partially locked) `Moderate::Report` for `new`, strong-params it on `create`, runs the **bot gate** and the **rate-limit** as `before_action`s, and on success redirects back to the form with a confirmation flash. On failure it re-renders `new` with `422` and the model's validation errors — standard Rails.

```ruby
# Conceptually (lives in the gem):
module Moderate
  class NoticesController < Moderate::ApplicationController
    before_action :enforce_notice_enabled!
    before_action :throttle_notices!, only: :create   # config.notice_rate_limit
    before_action :verify_human!,     only: :create   # auto-Turnstile, else config.notice_guard

    def new
      @report = Moderate::Report.new(prefill_attributes)   # query-param + current_user prefill
      @identity_locked = identity_locked?                  # lock name/email when signed in
    end

    def create
      intake = Moderate::Services::IntakeNotice.new(attributes: notice_params, reporter: current_notifier)
      if intake.save
        redirect_to new_notice_path, notice: t("moderate.notices.received"), status: :see_other
      else
        @report = intake.report
        render :new, status: :unprocessable_entity
      end
    end
  end
end
```

`Moderate::ApplicationController` (the engine's base) inherits from `config.parent_controller.constantize` (default `"::ActionController::Base"` so it works even on API-only apps, with `protect_from_forgery` applied when available) — exactly the `parent_controller` indirection Devise uses, so you can point it at your own base controller to inherit your layout, locale-setting, and `current_user`.

#### The bot gate (auto-integrates `rails_cloudflare_turnstile`)

A public, unauthenticated form is a spam magnet. `moderate` ships a **single, request-time bot gate** (`verify_human!`) that auto-adapts to your bundle — with **zero wiring**:

- **If the [`rails_cloudflare_turnstile`](https://github.com/instrumentl/rails-cloudflare-turnstile) gem is installed**, the gate uses it automatically. That gem mixes its helpers in for you, so:
  - the **view renders the widget** (`cloudflare_turnstile` + `cloudflare_turnstile_script_tag`), and
  - the **controller verifies the challenge server-side** (`validate_cloudflare_turnstile`); a failed challenge (the gem's `RailsCloudflareTurnstile::Forbidden`) is turned into a friendly `422` so the submitter can retry.

  You add the gem and its keys (its own `config/initializers/cloudflare_turnstile.rb`) — `moderate` needs **no env var and no config** to pick it up. Detection is via `defined?`/`respond_to?`, and `rails_cloudflare_turnstile` is **not** a dependency of `moderate`.
- **Otherwise**, the gate falls back to a configurable proc, `config.notice_guard` (no-op by default, so the form just works in dev/test and for apps that gate at the edge). The proc receives the controller and returns a boolean:

  ```ruby
  # Use hCaptcha / reCAPTCHA / your own check instead of Turnstile:
  config.notice_guard = ->(controller) { MyCaptcha.verify(controller.params["my-token"]) }
  ```

  An exception in the guard is treated as "failed closed" (re-render the form so the submitter retries) — a flaky bot service must never 500 a legal notice form.

We default to recommending Turnstile (privacy-friendly, free, the RailsFast house default), but you're never locked in: the guard is just a lambda.

#### The rate-limit hook

On Rails 7.2+ you could use the built-in `rate_limit` API; `moderate` instead implements a tiny per-IP, cache-backed counter (`Rails.cache`) as a `before_action`, so it honors your **runtime** `config.notice_rate_limit` (the class-level macro is evaluated at class load, before your initializer has run). Configure it once:

```ruby
config.notice_rate_limit = { max: 5, within: 1.hour }   # default
config.notice_rate_limit = false                        # disable (you throttle at the edge)
```

When tripped, `create` responds `429 Too Many Requests` with a retry message, rendered through the same (overridable) view. Both gates are deliberately **defense in depth** and both degrade to "off" gracefully, so the form never becomes a support burden in environments where you don't need them.

---

## The form fields (the DSA Art. 16 contract)

These are the fields the regulation requires, mirrored on the X / YouTube public forms. The default view renders exactly this set; if you eject and customize, **keep all of them** — they're what makes the notice legally valid (and they map 1:1 to the model's validations).

| Field | Param (`notice[...]`) | Required | Notes |
| --- | --- | --- | --- |
| **Legal reason** | `legal_reason` | yes | A `<select>` from the **DSA statement-of-reasons taxonomy** (`Moderate::Report::DSA_LEGAL_REASONS`). This is the regulator-aligned set, *not* your in-app community-report categories. |
| **Exact URL** | `subject_url` | yes | "the exact electronic location of that information" — Art. 16(2)(b). Validated as an `http(s)` URL; the model tries to resolve it to a reportable record for the evidence snapshot. Prefillable via `?content_url=`. |
| **Content type** | `content_type` | yes | A `<select>` from the host-agnostic `Moderate::Report::CONTENT_TYPES` bucket — keeps the snapshot/queue tidy. Prefillable via `?content_type=`. |
| **Account/handle** | `reported_account_identifier` | no | Optional host-side identity of the content (a username). Prefillable via `?content_author=` / `?content_id=`. |
| **Explanation** | `message` | yes | The "sufficiently substantiated explanation … why the individual or entity alleges the information to be illegal" — Art. 16(2)(a). Free text. |
| **Your name** | `notifier_name` | yes* | Art. 16(2)(c). *Optional only for `protection_of_minors` notices, where the DSA permits anonymity. Prefilled + **locked** from `current_user` when signed in. |
| **Your email** | `notifier_email` | yes | Art. 16(2)(c) — where the confirmation of receipt and the decision go. Validated as a real address. Prefilled + **locked** from `current_user` when signed in. |
| **EU member state** | `legal_country_code` | yes | ISO-3166 `<select>` of EU/EEA states (`Moderate::Report::EU_COUNTRY_CODES`) — establishes jurisdiction and routing. |
| **Good-faith statement** | `good_faith_confirmed` | yes | A checkbox attesting "the information and allegations are accurate and complete" — Art. 16(2)(d). Must be checked; the model rejects the save otherwise. |

The legal-reason `<select>` is driven by a single constant so the taxonomy stays consistent across the form, the model, and the Art. 17 statement-of-reasons and Art. 24 transparency counters:

```ruby
Moderate::Report::DSA_LEGAL_REASONS
# => ["animal_welfare", "consumer_information", "cyber_violence", "data_protection_privacy",
#     "illegal_or_harmful_speech", "civic_elections", "non_consensual_behavior",
#     "pornography_sexualized_content", "protection_of_minors", "public_security",
#     "scams_fraud", "scope_of_platform_service", "self_harm", "unsafe_illegal_products",
#     "violence", "intellectual_property", "other"]   # the EU Transparency Database vocabulary
```

> [!NOTE]
> **Two taxonomies, on purpose.** The in-app **community report** categories (`:harassment`, `:spam`, …) are about *your* rules; the **DSA legal-reason** taxonomy here is about *the law*. `moderate` ships both and never conflates them — a public notice always carries a `legal_reason`, an in-app report always carries a community `category`. See [DSA & compliance](../README.md#️-dsa--app-store-compliance-out-of-the-box).

---

## The default view, and how to override it (the `moderate:views` generator)

### Out of the box

The gem ships the templates inside the engine, under `app/views/moderate/`. They render with no CSS framework assumed, themable via CSS custom properties (`:root { --moderate-* }`), and pull every label/hint through `I18n` (`moderate.notices.*`) so you can translate without touching markup. The layout inherits nothing from your app by default; point `config.parent_controller` at your own base controller (and give it a `layout`) if you'd rather the forms sit inside your site chrome.

### Ejecting the views

When you want full control of the markup, run the generator — **the Devise move**:

```bash
rails generate moderate:views
```

That copies the engine's templates into your app. Because your `app/views` outranks the engine in Rails' view lookup, your copies **shadow** the gem's automatically — no config, no registration. Delete a file and the gem's default for that template comes back. Upgrade the gem and your ejected copies are untouched (you re-run the generator only if you *want* the new defaults).

> [!TIP]
> Generator naming follows the ecosystem: `moderate:install` (migration + initializer, like every other gem) and `moderate:views` (eject the form, like Devise). Nothing else is generated — we do **not** ship admin-view generators, because admin is BYOUI.

---

## Staying optional: ignore the engine entirely

The engine is a courtesy, not a contract. If you want to build the public notice page yourself — your own route, your own controller, your own styling — **don't mount it**, and talk to the service/model directly:

```ruby
class LegalController < ApplicationController
  def new_notice  = (@report = Moderate::Report.new)

  def create_notice
    intake = Moderate::Services::IntakeNotice.new(attributes: notice_params, reporter: current_user)
    if intake.save
      # your own confirmation page / mailer
    else
      @report = intake.report
      render :new_notice, status: :unprocessable_entity
    end
  end
end
```

You still get every Art. 16 validation, the evidence snapshot, the durable `acknowledged_at`, the `notice_received` event, and the row landing in `Moderate::Report.pending` — you just bring the HTML. Mounting the engine is the fast path; using the service directly is the full-control path. Either way the compliance lives in the model, not the view.

And if you don't serve EU users at all? Skip both. Reporting, blocking, and filtering work standalone without ever touching the notice intake.

---

## Configuration reference (notice form)

```ruby
Moderate.configure do |config|
  config.notice_form_enabled        = true                  # mount-able engine on/off (default: true)
  config.parent_controller          = "::ActionController::Base"  # like Devise's config.parent_controller
  config.appeal_form_enabled        = true
  config.appeal_rate_limit          = { max: 10, within: 1.minute }
  config.appeal_guard               = ->(controller) { true }
  config.appeal_return_path         = "/"
  config.notice_rate_limit          = { max: 5, within: 1.hour }  # per-IP throttle, or false to disable

  # Bot gate:
  #   - Install `rails_cloudflare_turnstile` and it AUTO-integrates (widget + verify), no config here.
  #   - Otherwise set a guard proc (no-op by default) to use hCaptcha / reCAPTCHA / your own check:
  config.notice_guard               = ->(controller) { true }     # ->(controller) { boolean }
end
```

Every one of these has a sensible default, so `mount Moderate::Engine => "/<your-path>"` with an otherwise-empty config gives you a working, compliant form. See the [main configuration reference](../README.md#configuration-reference) for the rest of `moderate`.

## See also

- [DSA & app-store compliance, out of the box](../README.md#️-dsa--app-store-compliance-out-of-the-box) — the full Art. 16/17/20/24 mapping
- [Notifications & audit](../README.md#-notifications---audit--one-hook-each) — wiring the `notice_received` confirmation-of-receipt
- [`docs/compliance.md`](compliance.md) — the App Store / Play / DSA checklist
- [Why the models](../README.md#-why-the-models) — why a notice and a report share one table
