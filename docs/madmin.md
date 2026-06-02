# Admin & the moderation queue — wiring `moderate` into `madmin` (BYOUI)

Most of Trust & Safety lives in *admin*: a human (or a script) looking at a queue of reports, flags, and appeals and making a call. `moderate` deliberately does **not** ship admin chrome — it ships the **primitives** (the `Moderate::Report` / `Moderate::Flag` / `Moderate::Appeal` / `Moderate::Block` models, the `resolve!` / `dismiss!` / `uphold!` / `reject!` decision methods, the queue scopes, the controller concern), and lets you **bring your own UI**.

This guide is the full walkthrough for the most common BYOUI choice: [`madmin`](https://github.com/excid3/madmin). It's the exact recipe a real production app uses, distilled. If you're on ActiveAdmin, Avo, Trestle, or a hand-rolled admin, the *shape* is identical — generate a screen against the model, add two buttons, POST to a custom action that calls the gem's decision method. Only the framework glue changes.

> [!NOTE]
> Why no built-in admin? Trust & Safety UI is the part every app wants to own — your branding, your auth, your layout, your extra columns. The decision *logic* (atomic content removal, ban, notify, audit) is the part nobody should reimplement. `moderate` draws the line exactly there: the gem owns the `resolve!`/`dismiss!`/`uphold!`/`reject!` transaction; you own the screen that calls it. See [What `moderate` does and doesn't do](../README.md#what-moderate-does-and-doesnt-do).

---

## TL;DR

```bash
# 1. Generate one madmin resource per moderation model
rails generate madmin:resource Moderate::Report
rails generate madmin:resource Moderate::Flag
rails generate madmin:resource Moderate::Appeal
rails generate madmin:resource Moderate::Block
```

```ruby
# 2. Add member routes for the decisions (config/routes.rb, inside your madmin namespace)
resources :reports, only: [:index, :show] do
  member { post :resolve; post :dismiss }
end
resources :flags, only: [:index, :show] do
  member { post :resolve; post :dismiss }
end
resources :appeals, only: [:index, :show] do
  member { post :uphold; post :reject }
end
resources :blocks, only: [:index, :show]
```

```ruby
# 3. Subclass the madmin resource controller and call the gem's decision methods
module Madmin
  class ReportsController < Madmin::ResourceController
    def resolve
      @record.resolve!(by: current_user, remove_content: params[:remove_content],
                       ban_user: params[:ban_user], note: params[:note])
      redirect_to main_app.madmin_report_path(@record), notice: "Report resolved.", status: :see_other
    rescue => e
      redirect_to main_app.madmin_report_path(@record), alert: "Could not resolve: #{e.message}", status: :see_other
    end

    def dismiss
      @record.dismiss!(by: current_user, note: params[:note])
      redirect_to main_app.madmin_report_path(@record), notice: "Report dismissed.", status: :see_other
    rescue => e
      redirect_to main_app.madmin_report_path(@record), alert: "Could not dismiss: #{e.message}", status: :see_other
    end
  end
end
```

That's the whole pattern. The rest of this doc fills in the resource definitions, the queue, the decision buttons, and the gotchas.

---

## The model primitives `madmin` points at

`moderate`'s models are **plain ActiveRecord**, so they show up in `madmin` like any other model — no special integration. Here's what you're admining and the queue scope on each:

| Model | What it is | The queue scope | Decide with |
| --- | --- | --- | --- |
| `Moderate::Report` | In-app reports **and** public DSA notices (one table, distinguished by `intake_kind`) | `Moderate::Report.pending` | `report.resolve!` / `report.dismiss!` |
| `Moderate::Flag` | Auto-filter flags from `:flag`-mode `moderates` (source: `text_filter` / `image_filter` / `external_classifier` / `manual`) | `Moderate::Flag.pending` | `flag.resolve!` / `flag.dismiss!` |
| `Moderate::Appeal` | DSA Art. 20 internal complaints against a decision | `Moderate::Appeal.pending` | `appeal.uphold!` / `appeal.reject!` |
| `Moderate::Block` | The bidirectional `blocker`/`blocked` safety edge | (no decision — read-only) | n/a |

The same `pending` scope is what a **human admin** reads in `madmin` *and* what an **automated ML consumer** reads in a background job — one queue, two readers. (More on that in [Automated review](#automated-review-the-same-pending-queue).)

> [!IMPORTANT]
> Decisions are **only** ever made by calling the gem's methods (`resolve!`, `dismiss!`, `uphold!`, `reject!`). Don't let madmin's stock edit form mutate `status` directly. Every decision is atomic, requires a moderator + a note, runs your enforcement (content removal via the reportable's own `remove_reported_field!`, bans via your `ban_handler`), fires the `notify` / `audit` hooks, and stamps the appeal window. A raw `status = "resolved"` update skips all of that and leaves you non-compliant. Keep the models **read-only** in madmin (`form: false`) and route every change through a custom member action — exactly what this guide does.

---

## Step 1 — Generate the resources

`madmin`'s generator works against namespaced models out of the box:

```bash
rails generate madmin:resource Moderate::Report
rails generate madmin:resource Moderate::Flag
rails generate madmin:resource Moderate::Appeal
rails generate madmin:resource Moderate::Block
```

Each creates `app/madmin/resources/moderate/<model>_resource.rb` and a flat controller stub. Now edit the resources to make them a real moderation queue — read-only columns, queue scopes, and a useful index order.

### `Moderate::ReportResource`

```ruby
# app/madmin/resources/moderate/report_resource.rb
class Moderate::ReportResource < Madmin::Resource
  model Moderate::Report

  # Everything is read-only (form: false): decisions go through the custom
  # member actions below, never through madmin's stock edit form.
  attribute :id,          index: true, form: false
  attribute :status,      index: true, form: false   # pending / resolved / dismissed
  attribute :kind,        index: true, form: false   # "report" (in-app) or "dsa_notice"
  attribute :category,    index: true, form: false   # community category OR DSA legal_reason
  attribute :reportable,  :polymorphic, index: true, form: false, label: "Target"
  attribute :reported_field, index: true, form: false, label: "Field"
  attribute :reported_user,  index: true, form: false
  attribute :reporter,       index: true, form: false
  attribute :notifier_email, index: true, form: false, label: "Notifier"  # DSA notices
  attribute :details,        index: false, form: false
  attribute :snapshot,       index: false, form: false   # the immutable evidence snapshot
  attribute :resolution_note, index: false, form: false
  attribute :created_at,  index: true, form: false, label: "Received"
  attribute :resolved_at, index: true, form: false

  # Queue scopes — these are the gem's own scopes, surfaced as madmin filters.
  scope :pending
  scope :resolved
  scope :dismissed

  menu label: "Reports", parent: "Trust & Safety"

  def self.display_name(record) = "Report ##{record.id.to_s.first(8)}"
  def self.default_sort_column = "created_at"
  def self.default_sort_direction = "desc"
end
```

### `Moderate::FlagResource`

```ruby
# app/madmin/resources/moderate/flag_resource.rb
class Moderate::FlagResource < Madmin::Resource
  model Moderate::Flag

  attribute :id,         index: true, form: false
  attribute :status,     index: true, form: false   # pending / resolved / dismissed
  attribute :source,     index: true, form: false   # wordlist / image / <your adapter> / manual
  attribute :flaggable,  :polymorphic, index: true, form: false, label: "Target"
  attribute :field,      index: true, form: false
  attribute :owner,      index: true, form: false
  attribute :categories, index: false, form: false  # e.g. [:hate, :threats]
  attribute :scores,     index: false, form: false  # { hate: 1.0 } (0..1 for ML adapters)
  attribute :resolution_note, index: false, form: false
  attribute :created_at, index: true, form: false
  attribute :reviewed_at, index: true, form: false

  scope :pending
  scope :resolved
  scope :dismissed

  menu label: "Flags", parent: "Trust & Safety"

  def self.display_name(record) = "Flag ##{record.id.to_s.first(8)}"
  def self.default_sort_column = "created_at"
  def self.default_sort_direction = "desc"
end
```

### `Moderate::AppealResource`

```ruby
# app/madmin/resources/moderate/appeal_resource.rb
class Moderate::AppealResource < Madmin::Resource
  model Moderate::Appeal

  attribute :id,     index: true, form: false
  attribute :status, index: true, form: false   # pending / upheld / rejected
  attribute :report, index: true, form: false   # the decision being appealed
  attribute :appellant_email, index: true, form: false
  attribute :reason, index: false, form: false
  attribute :resolution_note, index: false, form: false
  attribute :created_at,  index: true, form: false, label: "Received"
  attribute :resolved_at, index: true, form: false

  scope :pending
  scope :upheld
  scope :rejected

  menu label: "Appeals", parent: "Trust & Safety"

  def self.display_name(record) = "Appeal ##{record.id.to_s.first(8)}"
  def self.default_sort_column = "created_at"
  def self.default_sort_direction = "desc"
end
```

### `Moderate::BlockResource` (read-only)

Blocks have no decision — they're a user safety edge, so they're a plain read-only list for support visibility:

```ruby
# app/madmin/resources/moderate/block_resource.rb
class Moderate::BlockResource < Madmin::Resource
  model Moderate::Block

  attribute :id,      index: true, form: false
  attribute :blocker, index: true, form: false
  attribute :blocked, index: true, form: false
  attribute :created_at, index: true, form: false

  menu label: "Blocks", parent: "Trust & Safety"

  def self.display_name(record) = "Block ##{record.id.to_s.first(8)}"
end
```

> [!TIP]
> Group all four under one `parent:` (here `"Trust & Safety"`) so they sit together in the madmin sidebar — that grouping *is* your moderation queue's navigation.

---

## Step 2 — Routes for the decisions

`madmin` gives you `index`/`show` for free. The decisions are custom **member** actions you add yourself, the standard Rails way. Inside your madmin namespace:

```ruby
# config/routes.rb
namespace :madmin do
  resources :reports, only: [:index, :show] do
    member do
      post :resolve
      post :dismiss
    end
  end

  resources :flags, only: [:index, :show] do
    member do
      post :resolve
      post :dismiss
    end
  end

  resources :appeals, only: [:index, :show] do
    member do
      post :uphold
      post :reject
    end
  end

  resources :blocks, only: [:index, :show]   # read-only
end
```

This gives you `resolve_madmin_report_path(report)`, `dismiss_madmin_report_path(report)`, `uphold_madmin_appeal_path(appeal)`, and friends — the URLs your decision buttons POST to.

> [!NOTE]
> Keep `only: [:index, :show]`. There's no `:edit`/`:update`/`:destroy` because **the only legitimate way to change a moderation record is a decision method**, and those live behind the member actions, not the stock REST update.

---

## Step 3 — The controller (call the gem's decision methods)

This is the heart of the integration, and it's tiny. Subclass `Madmin::ResourceController`, add one action per decision, and have each action call the matching `moderate` method. `@record` is set for you by `madmin` (it's the report/flag/appeal the member route resolved).

```ruby
# app/controllers/madmin/reports_controller.rb
module Madmin
  class ReportsController < Madmin::ResourceController
    def resolve
      @record.resolve!(
        by:             current_user,                 # the moderator (required)
        remove_content: params[:remove_content],       # runs reportable#remove_reported_field!
        ban_user:       params[:ban_user],             # runs your config.ban_handler
        note:           params[:note]                  # required — the decision rationale
      )
      redirect_to main_app.madmin_report_path(@record),
        notice: "Report resolved.", status: :see_other
    rescue => error
      redirect_to main_app.madmin_report_path(@record),
        alert: "Could not resolve report: #{error.message}", status: :see_other
    end

    def dismiss
      @record.dismiss!(by: current_user, note: params[:note])
      redirect_to main_app.madmin_report_path(@record),
        notice: "Report dismissed.", status: :see_other
    rescue => error
      redirect_to main_app.madmin_report_path(@record),
        alert: "Could not dismiss report: #{error.message}", status: :see_other
    end

    private

    # Eager-load the associations the index/show touch, so the queue page
    # doesn't N+1 across reporter / reported_user / target.
    def scoped_resources
      super.includes(:reporter, :reported_user, :reportable)
    end
  end
end
```

```ruby
# app/controllers/madmin/flags_controller.rb
module Madmin
  class FlagsController < Madmin::ResourceController
    def resolve
      @record.resolve!(by: current_user, note: params[:note])
      redirect_to main_app.madmin_flag_path(@record), notice: "Flag actioned.", status: :see_other
    rescue => error
      redirect_to main_app.madmin_flag_path(@record), alert: "Could not action flag: #{error.message}", status: :see_other
    end

    def dismiss
      @record.dismiss!(by: current_user, note: params[:note])
      redirect_to main_app.madmin_flag_path(@record), notice: "Flag dismissed.", status: :see_other
    rescue => error
      redirect_to main_app.madmin_flag_path(@record), alert: "Could not dismiss flag: #{error.message}", status: :see_other
    end

    private

    def scoped_resources
      super.includes(:flaggable, :owner)
    end
  end
end
```

```ruby
# app/controllers/madmin/appeals_controller.rb
module Madmin
  class AppealsController < Madmin::ResourceController
    def uphold
      @record.uphold!(by: current_user, note: params[:note])   # overturns the original decision
      redirect_to main_app.madmin_appeal_path(@record), notice: "Appeal upheld.", status: :see_other
    rescue => error
      redirect_to main_app.madmin_appeal_path(@record), alert: "Could not uphold appeal: #{error.message}", status: :see_other
    end

    def reject
      @record.reject!(by: current_user, note: params[:note])   # confirms the original decision
      redirect_to main_app.madmin_appeal_path(@record), notice: "Appeal rejected.", status: :see_other
    rescue => error
      redirect_to main_app.madmin_appeal_path(@record), alert: "Could not reject appeal: #{error.message}", status: :see_other
    end

    private

    def scoped_resources
      super.includes(:report, :appellant)
    end
  end
end
```

Notice what's **not** here: no content-removal SQL, no `user.suspend!`, no email sending, no audit write. All of that is the gem's job, triggered atomically inside `resolve!` / `dismiss!` / `uphold!` / `reject!`. Your controller is pure HTTP — params in, decision method called, redirect out. (That's why every action is a four-liner with a `rescue` for the flash.)

> [!IMPORTANT]
> Use `status: :see_other` on the redirects. The decision actions are `POST`s, and Turbo needs a 303 to follow a redirect after a non-GET. This is the same convention madmin's own create/update use.

### Reuse from the standard `Moderate::Moderation` concern instead

If you'd rather not hand-write the four controllers, `moderate` ships a controller concern that gives you the `resolve`/`dismiss` (and appeal `uphold`/`reject`) actions, strong params, and redirects already wired — you just bring auth:

```ruby
module Madmin
  class ReportsController < Madmin::ResourceController
    include Moderate::Moderation   # resolve!/dismiss! actions, strong params, redirects
  end
end
```

Hand-rolling (above) is the right call when your redirects/flashes need to match the rest of your madmin app; the concern is the right call when you want zero boilerplate. They do the same thing.

---

## Step 4 — The decision buttons (the show view)

`madmin`'s stock `show` template lists attributes; add a small panel with the decision forms. The cleanest move is a custom show view at `app/views/madmin/reports/show.html.erb` that renders madmin's default attributes and then a "Decide" sidebar. The load-bearing part is just two forms that POST to the member routes — render them only while the record is still `pending`:

```erb
<%# app/views/madmin/reports/show.html.erb (decision panel; render alongside madmin's default attribute list) %>
<% report = @record %>

<% if report.pending? %>
  <section>
    <h2>Resolve</h2>
    <%= form_with url: resolve_madmin_report_path(report), method: :post do %>
      <label><%= check_box_tag :remove_content, "1" %> Remove reported content</label>
      <label><%= check_box_tag :ban_user, "1" %> Ban reported user</label>
      <%= text_area_tag :note, nil, placeholder: "Decision note", required: true %>
      <%= submit_tag "Resolve", data: { turbo_confirm: "Resolve and notify the parties?" } %>
    <% end %>

    <h2>Dismiss</h2>
    <%= form_with url: dismiss_madmin_report_path(report), method: :post do %>
      <%= text_area_tag :note, nil, placeholder: "Decision note", required: true %>
      <%= submit_tag "Dismiss", data: { turbo_confirm: "Dismiss and notify the reporter?" } %>
    <% end %>
  </section>
<% else %>
  <p>This report is closed.</p>
<% end %>
```

The appeal show view is the same shape with `uphold`/`reject`:

```erb
<% appeal = @record %>
<% if appeal.pending? %>
  <%= form_with url: uphold_madmin_appeal_path(appeal), method: :post do %>
    <%= text_area_tag :note, nil, placeholder: "Why the original decision is overturned", required: true %>
    <%= submit_tag "Uphold appeal", data: { turbo_confirm: "Overturn the original decision?" } %>
  <% end %>
  <%= form_with url: reject_madmin_appeal_path(appeal), method: :post do %>
    <%= text_area_tag :note, nil, placeholder: "Why the original decision stands", required: true %>
    <%= submit_tag "Reject appeal", data: { turbo_confirm: "Confirm the original decision?" } %>
  <% end %>
<% end %>
```

Two details worth copying:

- **Gate on `pending?`.** Show the decision forms only while the record is open; render "closed" once it isn't. The decision methods are also guarded server-side (calling `resolve!` on an already-resolved report raises), but hiding the buttons is the better UX.
- **Require the note.** `required: true` on the textarea, and the gem requires it too — every decision must carry a rationale (that's what feeds the DSA Art. 17 statement of reasons). Belt and suspenders.

The evidence snapshot (`report.snapshot`) is plain JSON on the record — render it in a `<pre>` so the moderator sees exactly what was reported, even if the original content was since edited or deleted. That immutability is the whole point of the snapshot.

---

## The moderation-queue pattern (the index)

Your `index` *is* the queue. Three things make it usable:

1. **Default to pending.** The `scope :pending` you declared on each resource gives madmin a one-click filter; make it the landing view by sorting `created_at desc` and pointing your "Moderation" nav link at `madmin_reports_path(scope: :pending)`.
2. **One sidebar group.** All four resources under one `parent:` menu (`"Trust & Safety"`) so reports, flags, appeals, and blocks read as a single workspace.
3. **A queue-depth dashboard tile.** The same scopes power an at-a-glance count on your admin home:

```ruby
# app/controllers/madmin/dashboard_controller.rb
def show
  @pending_reports = Moderate::Report.pending.count
  @pending_flags   = Moderate::Flag.pending.count
  @pending_appeals = Moderate::Appeal.pending.count
end
```

```erb
<%= link_to "#{@pending_reports} reports awaiting review", madmin_reports_path(scope: :pending) %>
<%= link_to "#{@pending_flags} flags awaiting review",     madmin_flags_path(scope: :pending) %>
<%= link_to "#{@pending_appeals} appeals awaiting review", madmin_appeals_path(scope: :pending) %>
```

That's the whole moderation queue: pending-first lists, grouped nav, and a count on the dashboard — all built from the gem's `pending` scopes and your existing madmin.

---

## Automated review: the same `pending` queue

The headline trick of the model design: **a human admin and an ML/automation consumer read the *same* `Moderate::Flag.pending` (or `Moderate::Report.pending`) scope.** Your madmin screen is one reader; a background job is another. To auto-action high-confidence flags before a human ever sees them, drain the same queue in a job and call the same decision method:

```ruby
class AutoModerationJob < ApplicationJob
  def perform
    Moderate::Flag.pending.find_each do |flag|
      next unless flag.scores[:csam].to_f >= 0.99   # only the unambiguous ones
      flag.resolve!(by: Moderate.system_actor, note: "Auto-removed: high-confidence CSAM")
    end
  end
end
```

Because the job calls `resolve!` (not a raw `update`), the auto-decision is identical to a human one — atomic enforcement, `notify`/`audit` hooks, statement-of-reasons, appeal window. Whatever the job doesn't touch stays in `pending` for a human in madmin. One queue, two consumers, zero divergence.

---

## What `moderate` ships vs. what you build

To be explicit about the boundary this guide sits on:

| `moderate` ships (the primitives) | You build (the UI chrome) |
| --- | --- |
| The models (`Report`/`Flag`/`Appeal`/`Block`) | The madmin resources (columns, labels, fields) |
| The queue scopes (`.pending`, `.resolved`, …) | The index/show screens & nav grouping |
| The decision methods (`resolve!`/`dismiss!`/`uphold!`/`reject!`) — atomic enforcement + notify + audit + appeal window | The buttons/forms that call them |
| The optional `Moderate::Moderation` controller concern | Auth (`current_user`, admin gate) |
| Helpers + the evidence snapshot on each record | Your branding, layout, extra columns |

You wire it once and you have a real, compliant moderation queue, in your own admin, in an afternoon.

## See also

- [Admin & the moderation queue](../README.md#️-admin--the-moderation-queue) — the short version in the README
- [Configuration reference](configuration.md) — `ban_handler`, `notify`, `audit`, filter policies
- [Notifications & audit](../README.md#-notifications---audit--one-hook-each) — what fires when you call a decision method
- [The DSA notice form](dsa-notice-form.md) — the public Art. 16 intake that lands in the same `Moderate::Report.pending` queue
- [`madmin`](https://github.com/excid3/madmin) — the admin framework this guide targets
