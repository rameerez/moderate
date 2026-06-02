# The DSA notice form — a mountable, X-style legal-notice intake

The EU **Digital Services Act, Article 16 ("Notice and action")** says every hosting service that serves EU users must offer a **public, electronic** way for *anyone* — not just logged-in users — to flag illegal content, and must **acknowledge receipt** of that notice. This is the form you see at the bottom of X, YouTube, Reddit: "Report illegal content (EU)". It is a hard requirement, it is separate from your in-app "Report" button, and it is exactly the kind of legally-loaded plumbing `moderate` exists to take off your plate.

So `moderate` ships it as a **mountable Rails engine**: one line in your routes and you have a compliant, public notice form live at `/legal/notices/new`. The form, the controller, the model, the Turnstile gate, the rate-limit, and the confirmation-of-receipt are all done for you. The default view is plain, accessible, and CSS-framework-agnostic — and it's **overridable the way Devise does it**: run one generator to eject the templates into your app and style them to match your brand.

It is also **completely optional**. If you'd rather build the public notice page yourself (you already have a design system, you want it inside an existing `/legal` controller, whatever), don't mount the engine — use `Moderate::Notice` directly and skip everything below. The engine is a convenience, not a dependency.

> [!NOTE]
> This is the **public, regulator-facing** form (DSA Art. 16). It is *not* the in-app "Report this comment" button (that's `current_user.report!(...)` from [the Actors section](../README.md#-actors-report--block)) and it is *not* the admin moderation queue (that's BYOUI — `moderate` gives you the primitives). Two intakes, one `moderate_reports` table, distinguished by `kind`. See [why the models](../README.md#-why-the-models).

---

## TL;DR

```ruby
# config/routes.rb
mount Moderate::Engine => "/legal"
```

```ruby
# config/initializers/moderate.rb
Moderate.configure do |config|
  config.notice_form_enabled = true               # default; flip to false to hard-disable the engine
  config.notice_turnstile_site_key   = ENV["TURNSTILE_SITE_KEY"]    # optional bot gate
  config.notice_turnstile_secret_key = ENV["TURNSTILE_SECRET_KEY"]
  config.notice_rate_limit = { max: 5, within: 1.hour }            # per-IP throttle
end
```

That's it — `GET /legal/notices/new` renders the form, `POST /legal/notices` validates + persists a `Moderate::Notice`, fires the `notice_received` notification (your confirmation-of-receipt email + admin alert), and shows the submitter a receipt with a reference number.

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
| `mount` is implicit via `devise_for` | `mount Moderate::Engine => "/legal"` |
| Views ship inside the gem | Views ship inside the engine (`app/views/moderate/notices/`) |
| `rails g devise:views` copies them to your app | `rails g moderate:views` copies them to your app |
| `config.parent_controller` | `config.notice_parent_controller` |
| Rails view lookup prefers `app/views` over the gem | identical — an ejected view **shadows** the bundled one, zero config |
| Works untouched if you never eject | Works untouched if you never eject |

The magic in both is the same boring Rails fact: **the host app's `app/views` sits ahead of any engine's view paths in the lookup chain.** So when you run `moderate:views` and a file appears at `app/views/moderate/notices/new.html.erb`, Rails renders *yours* instead of the gem's — no registration, no config flag, no monkey-patch. Delete your copy and the gem's default comes back.

---

## How it mounts

`Moderate::Engine` is an **isolated** engine (`isolate_namespace Moderate`), so its routes, controllers, helpers, and table prefixes never collide with your app. You mount it wherever you want the public form to live:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Moderate::Engine => "/legal"     # form at /legal/notices/new
  # ...your app routes
end
```

Common mount points:

```ruby
mount Moderate::Engine => "/legal"        # → /legal/notices/new   (recommended)
mount Moderate::Engine => "/dsa"          # → /dsa/notices/new
mount Moderate::Engine => "/report"       # → /report/notices/new
```

The engine's routes (in the gem, you never write these):

```ruby
# config/routes.rb inside the engine
Moderate::Engine.routes.draw do
  resources :notices, only: [:new, :create, :show], path: "notices"
  root to: "notices#new"
end
```

- `GET  /legal/notices/new` — the form
- `POST /legal/notices` — submit
- `GET  /legal/notices/:reference` — the public receipt (looked up by opaque `reference`, never by sequential `id`)
- `GET  /legal` — the engine root redirects to the form

Link to it from your footer using the engine's named routes (mounted engines expose a helper named after the mount, here `moderate`):

```erb
<%= link_to "Report illegal content (EU)", moderate.new_notice_path %>
```

> [!TIP]
> Want the canonical "DSA point of contact" page the regulation also asks for (Art. 11/12)? The same engine root is a fine place to host a short page that links to the form and lists your contact address — but that's content, not code, so we leave the copy to you. Eject the views and edit `new.html.erb`'s intro block.

---

## The controller / model boundary

We keep the split clean and obvious — the controller does HTTP, the model does Trust & Safety.

### `Moderate::Notice` — the model (does the real work)

`Moderate::Notice` is **not a fourth table**. It's a thin, kind-scoped wrapper over `moderate_reports` (the same table that backs in-app reports), distinguished by `kind: "dsa_notice"`. This is on purpose: a notice and a report share the same decision workflow, the same evidence snapshot, the same appeal window, the same transparency counters. One queue, one statement-of-reasons path, one Art. 24 aggregation — whether the flag came from a logged-in user tapping "Report" or an anonymous lawyer filling in the public form.

```ruby
# Conceptually (the real model lives in the gem; this is the contract you rely on):
notice = Moderate::Notice.new(
  legal_reason:     "ip_infringement",     # from the DSA taxonomy (see below)
  content_url:      "https://yourapp.com/p/123",
  explanation:      "This post reproduces my copyrighted photo without licence.",
  notifier_name:    "Jane Doe",
  notifier_email:   "jane@example.com",
  member_state:     "ES",                   # ISO-3166 EU/EEA selector
  good_faith:       true                    # the Art. 16(2)(d) attestation, must be checked
)
notice.save!     # → persisted as a moderate_reports row, kind: "dsa_notice", status: :pending
notice.reference # => "DSA-7Q2K-9F3X"  (opaque, shown on the receipt, emailed to the notifier)
```

The model owns: validations (every required DSA field, a real email, a same-origin/`http(s)` URL check, the good-faith checkbox being true), the evidence snapshot (it tries to resolve `content_url` to a reportable record and snapshot it, so evidence survives edits/deletes), `reference` generation, and dropping into `Moderate::Report.pending` so your admins act on it exactly like any other report. It fires the `notice_received` event through `config.notify` — that's your confirmation-of-receipt to the notifier **and** your admin alert, from one hook.

> [!NOTE]
> "Confirmation of receipt without undue delay" (Art. 16(4)) is satisfied by the `notice_received` event → your mailer. The gem emits the event; you wire it to [`goodmail`](https://github.com/rameerez/goodmail) (or any mailer) once, the same way you wire `report_received`. See [Notifications](../README.md#-notifications---audit--one-hook-each).

### `Moderate::NoticesController` — the controller (does HTTP only)

The controller is intentionally boring. It builds a blank `Moderate::Notice` for `new`, strong-params it on `create`, runs the **Turnstile gate** and the **rate-limit** as `before_action`s, and on success redirects to the receipt. On failure it re-renders `new` with `422` and the model's validation errors — standard Rails.

```ruby
# Conceptually (lives in the gem):
module Moderate
  class NoticesController < Moderate::ApplicationController
    before_action :enforce_notice_enabled!
    before_action :throttle_notices!,  only: :create   # config.notice_rate_limit
    before_action :verify_turnstile!,  only: :create   # config.notice_turnstile_* (no-ops if unconfigured)

    def new     = (@notice = Moderate::Notice.new)
    def show    = (@notice = Moderate::Notice.find_by!(reference: params[:id]))

    def create
      @notice = Moderate::Notice.new(notice_params)
      if @notice.save
        redirect_to notice_path(@notice.reference), notice: t("moderate.notices.received")
      else
        render :new, status: :unprocessable_entity
      end
    end

    private

    def notice_params
      params.require(:notice).permit(
        :legal_reason, :content_url, :explanation,
        :notifier_name, :notifier_email, :member_state, :good_faith
      )
    end
  end
end
```

`Moderate::ApplicationController` (the engine's base) inherits from `config.notice_parent_controller.constantize` (default `"::ActionController::Base"` so it works even on API-only apps, with `protect_from_forgery` applied when available) — exactly the `config.parent_controller` indirection `api_keys` and Devise use, so you can point it at your own base controller to inherit your layout, locale-setting, etc.

#### The Turnstile-gate hook

A public, unauthenticated form is a spam magnet. `moderate` ships a **Cloudflare Turnstile** gate as a `before_action` that:

- **No-ops when unconfigured.** If `notice_turnstile_site_key`/`secret_key` are blank, the gate is skipped entirely and the form just works (great for dev/test and for apps that gate at the edge instead).
- **Renders the widget** in the default view when the site key is present (the view checks `Moderate.configuration.notice_turnstile_site_key.present?`).
- **Verifies server-side** on `create` by POSTing the response token to Turnstile's `siteverify`; a failed/missing token re-renders `new` with `422` and a friendly error.
- **Is pluggable.** Prefer hCaptcha, reCAPTCHA, or your own check? Set `config.notice_captcha_verifier = ->(controller) { ... boolean ... }` and the built-in Turnstile path steps aside.

We default to Turnstile (not reCAPTCHA) because it's privacy-friendly, free, and the RailsFast house default — but the verifier is just a lambda, so you're never locked in.

#### The rate-limit hook

On Rails 7.2+ the controller uses the built-in `rate_limit` API; on 7.1 it falls back to a tiny cache-backed counter (`Rails.cache`, per-IP). Configure it once:

```ruby
config.notice_rate_limit = { max: 5, within: 1.hour }   # default
config.notice_rate_limit = false                        # disable (you throttle at the edge)
```

When tripped, `create` responds `429 Too Many Requests` with a retry-after message, rendered through the same (overridable) view. Both gates are deliberately **defense in depth** and both degrade to "off" gracefully, so the form never becomes a support burden in environments where you don't need them.

---

## The form fields (the DSA Art. 16 contract)

These are the fields the regulation requires, mirrored on the X / YouTube public forms. The default view renders exactly this set; if you eject and customize, **keep all of them** — they're what makes the notice legally valid (and they map 1:1 to the model's validations).

| Field | Param | Required | Notes |
| --- | --- | --- | --- |
| **Legal reason** | `legal_reason` | yes | A `<select>` from the **DSA statement-of-reasons taxonomy** (see below). This is the regulator-aligned set, *not* your in-app community-report categories. |
| **Exact URL** | `content_url` | yes | "the exact electronic location of that information" — Art. 16(2)(b). Validated as an `http(s)` URL; the model tries to resolve it to a reportable record for the evidence snapshot. |
| **Explanation** | `explanation` | yes | The "sufficiently substantiated explanation of the reasons why the individual or entity alleges the information to be illegal" — Art. 16(2)(a). Free text. |
| **Your name** | `notifier_name` | yes* | Art. 16(2)(c). *Optional only for notices alleging certain offences against minors, where the DSA permits anonymity — the view exposes this carve-out via a checkbox that hides the name field. |
| **Your email** | `notifier_email` | yes | Art. 16(2)(c) — where the confirmation of receipt and the decision go. Validated as a real address. |
| **EU member state** | `member_state` | yes | ISO-3166 `<select>` of EU/EEA states — establishes jurisdiction and routing. |
| **Good-faith statement** | `good_faith` | yes | A checkbox attesting "the information and allegations are accurate and complete" — Art. 16(2)(d). Must be checked; the model rejects the save otherwise. |

The legal-reason `<select>` is driven by a single constant so the taxonomy stays consistent across the form, the model, and the Art. 17 statement-of-reasons and Art. 24 transparency counters:

```ruby
Moderate::DSA_LEGAL_REASONS
# => [:illegal_hate_speech, :terrorism, :csam, :ip_infringement,
#     :data_protection, :consumer_protection, :defamation,
#     :counterfeit, :scams_fraud, :other_illegal_content]  # regulator-aligned
```

> [!NOTE]
> **Two taxonomies, on purpose.** The in-app **community report** categories (`:harassment`, `:spam`, …) are about *your* rules; the **DSA legal-reason** taxonomy here is about *the law*. `moderate` ships both and never conflates them — a public notice always carries a `legal_reason`, an in-app report always carries a community `category`. See [DSA & compliance](../README.md#️-dsa--app-store-compliance-out-of-the-box).

---

## The default view, and how to override it (the `moderate:views` generator)

### Out of the box

The gem ships these templates inside the engine, under `app/views/moderate/`:

```
app/views/
├── layouts/moderate/application.html.erb   # minimal, framework-agnostic layout (CSS-var themable)
└── moderate/notices/
    ├── new.html.erb                        # the form
    ├── show.html.erb                       # the receipt (reference number + "what happens next")
    └── _form.html.erb                      # the field partial (the part you'll most want to restyle)
```

They render with no CSS framework assumed, themable via CSS custom properties (the same `:root { --moderate-* }` approach `api_keys` uses for its dashboard), and they pull every label/hint through `I18n` (`moderate.notices.*`) so you can translate without touching markup. The layout inherits nothing from your app by default; point `config.notice_parent_controller` at your own base controller (and give it a `layout`) if you'd rather the form sit inside your site chrome.

### Ejecting the views

When you want full control of the markup, run the generator — **the Devise move**:

```bash
rails generate moderate:views
```

That copies the engine's templates into your app:

```
      create  app/views/moderate/notices/new.html.erb
      create  app/views/moderate/notices/show.html.erb
      create  app/views/moderate/notices/_form.html.erb
      create  app/views/layouts/moderate/application.html.erb
```

Now edit them freely. Because your `app/views` outranks the engine in Rails' view lookup, your copies **shadow** the gem's automatically — no config, no registration. Delete a file and the gem's default for that template comes back. Upgrade the gem and your ejected copies are untouched (you re-run the generator only if you *want* the new defaults).

Scope it if you only want some templates:

```bash
rails generate moderate:views --views form          # just _form.html.erb
rails generate moderate:views --views form layout    # the form + the layout
```

The generator itself is the boring, idiomatic Rails thing — a `Rails::Generators::Base` that copies from the engine's `app/views` into the host's `app/views`, mirroring `Devise::Generators::ViewsGenerator` and `api_keys`'s install generator:

```ruby
# lib/generators/moderate/views_generator.rb (lives in the gem)
module Moderate
  module Generators
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../app/views", __dir__)

      class_option :views, type: :array, default: %w[notices layout],
                   desc: "Which view groups to copy (notices, form, layout)"

      def copy_views
        directory "moderate/notices", "app/views/moderate/notices"   if include?("notices")
        copy_file "moderate/notices/_form.html.erb",
                  "app/views/moderate/notices/_form.html.erb"        if include?("form")
        directory "layouts/moderate", "app/views/layouts/moderate"   if include?("layout")
      end
    end
  end
end
```

> [!TIP]
> Generator naming follows the ecosystem: `moderate:install` (migration + initializer, like every other gem) and `moderate:views` (eject the form, like Devise). Nothing else is generated — we do **not** ship admin-view generators, because admin is BYOUI.

---

## Staying optional: ignore the engine entirely

The engine is a courtesy, not a contract. If you want to build the public notice page yourself — your own route, your own controller, your own styling — **don't mount it**, and talk to the model directly:

```ruby
class LegalController < ApplicationController
  def new_notice  = (@notice = Moderate::Notice.new)

  def create_notice
    @notice = Moderate::Notice.new(notice_params)
    if @notice.save
      # your own confirmation page / mailer
    else
      render :new_notice, status: :unprocessable_entity
    end
  end
end
```

You still get every Art. 16 validation, the evidence snapshot, the `reference`, the `notice_received` event, and the row landing in `Moderate::Report.pending` — you just bring the HTML. Mounting the engine is the fast path; using the model directly is the full-control path. Either way the compliance lives in the model, not the view.

And if you don't serve EU users at all? Skip both. Reporting, blocking, and filtering work standalone without ever touching `Moderate::Notice`.

---

## Configuration reference (notice form)

```ruby
Moderate.configure do |config|
  config.notice_form_enabled        = true                  # mount-able engine on/off (default: true)
  config.notice_parent_controller   = "::ActionController::Base"  # like Devise's config.parent_controller
  config.notice_rate_limit          = { max: 5, within: 1.hour }  # per-IP throttle, or false to disable

  # Bot gate (all optional — the gate no-ops when blank):
  config.notice_turnstile_site_key   = ENV["TURNSTILE_SITE_KEY"]
  config.notice_turnstile_secret_key = ENV["TURNSTILE_SECRET_KEY"]
  config.notice_captcha_verifier     = nil                  # ->(controller) { boolean } to swap Turnstile out
end
```

Every one of these has a sensible default, so `mount Moderate::Engine => "/legal"` with an otherwise-empty config gives you a working, compliant form. See the [main configuration reference](../README.md#configuration-reference) for the rest of `moderate`.

## See also

- [DSA & app-store compliance, out of the box](../README.md#️-dsa--app-store-compliance-out-of-the-box) — the full Art. 16/17/20/24 mapping
- [Notifications & audit](../README.md#-notifications---audit--one-hook-each) — wiring the `notice_received` confirmation-of-receipt
- [`docs/compliance.md`](compliance.md) — the App Store / Play / DSA checklist
- [Why the models](../README.md#-why-the-models) — why a notice and a report share one table
