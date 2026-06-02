# Configuration reference

Everything `moderate` lets you configure lives in one initializer, written in the `Moderate.configure do |config|` block. `rails generate moderate:install` drops a fully-commented `config/initializers/moderate.rb` with every option present and annotated; this doc is the reference for what each one does, with copy-paste examples.

Every option has a sensible default, so the minimum viable config is a single line:

```ruby
# config/initializers/moderate.rb
Moderate.configure do |config|
  config.user_class = "User"
end
```

That alone gives you reporting, blocking, the default `:wordlist` filter in `:block` mode, and the moderation queue. Everything below is opt-in refinement.

> [!NOTE]
> Config is read at the point of use, not frozen at boot — class names are stored as strings and constantized lazily, so the initializer works no matter when your app loads. The block is validated at the end of `configure`, so a typo'd mode or unknown adapter raises a plain-English `ArgumentError` immediately instead of failing mysteriously later.

---

## The whole surface at a glance

```ruby
Moderate.configure do |config|
  # --- Identity -------------------------------------------------------------
  config.user_class          = "User"        # who reports / blocks / gets reported / gets banned

  # --- Filtering ------------------------------------------------------------
  config.default_filter_mode = :block        # :off / :block / :flag  (used by `moderates` w/o a mode)
  config.filter_adapter      = :wordlist     # default text adapter
  config.additional_words    = %w[…]         # extra :wordlist entries
  config.excluded_words      = %w[…]         # :wordlist false-positives to never flag
  config.report_categories   = %w[…]         # override the in-app community category list (no migration)

  config.register_adapter :openai, OpenAIModerationAdapter.new   # bring your own remote adapter
  config.filter "Message", :body, with: :wordlist, mode: :flag   # per-field policy in one place

  # --- Hooks (all no-op by default) ----------------------------------------
  config.audit       = ->(event) { … }                    # record important actions
  config.notify      = ->(event) { … }                    # fan out emails / alerts / push
  config.on_block    = ->(blocker:, blocked:, at:) { … }  # side effects when a block happens
  config.ban_handler = ->(user:, by:, reason:) { … }      # how a "ban" is applied in YOUR app

  # --- Misc -----------------------------------------------------------------
  config.locale = :en                        # locale for copy moderate generates itself
end
```

The public legal-form options (`parent_controller`, `notice_form_enabled`, `notice_rate_limit`, `notice_guard`, `appeal_form_enabled`, `appeal_rate_limit`, `appeal_guard`, `appeal_return_path`) are documented in their own guide — see [The DSA notice form](dsa-notice-form.md#configuration-reference-notice-form). They're omitted here to keep this focused on the core T&S surface.

---

## Identity

### `user_class`

```ruby
config.user_class = "User"   # default: "User"
```

The model that **acts** in your Trust & Safety system: it reports, it blocks, it gets reported, and it gets banned. This is the model where you add the actor macro:

```ruby
class User < ApplicationRecord
  participates_in_moderation # gains report!/block!/blocks?/blocked_with?…
  # include Moderate::Actor # the documented, exactly-equivalent include form
end
```

Stored as a **string** and constantized lazily, so it doesn't matter whether the class is loaded yet when the initializer runs. It's usually `"User"`, but it can be anything that represents "a person who acts" — `"Account"`, `"Member"`, etc. `moderate` deliberately doesn't own auth or current-user; you tell it the class, your auth gem (Devise, etc.) tells it who's logged in.

---

## Filtering

`moderate` filters text and images **before they're saved**, declared per field with the `moderates` macro. The three config options below set the *defaults* that macro uses; you can always override per field.

### `default_filter_mode`

```ruby
config.default_filter_mode = :block   # default: :block  (:off / :block / :flag)
```

The mode a bare `moderates :field` uses when you don't pass `mode:`:

- **`:off`** — no check. (Useful as a global default if you want filtering opt-in per field.)
- **`:block`** — the write is **rejected** with a validation error if the filter trips. Best for public, high-trust fields (a profile bio, a listing title).
- **`:flag`** — the write **succeeds**, and a `Moderate::Flag` is created **after commit** for review. Best for DMs and chat, where blocking mid-conversation is hostile UX.

```ruby
class Message < ApplicationRecord
  moderates :body                  # uses default_filter_mode
end

class Profile < ApplicationRecord
  moderates :bio,    mode: :block  # override: reject the save
  moderates :avatar, mode: :flag, with: :image   # `:image` is a registered adapter — see examples/ (only :wordlist is built in)
end
```

> [!IMPORTANT]
> `:flag` never lives in a validator. Validators must be side-effect-free, and a flag created inside a rolled-back transaction would silently vanish — so `moderate` creates the flag **after commit**, correctly, for you. This is the whole reason `:flag` is a `moderates` mode and not something you can hand-roll with `validates`.

### `filter_adapter`

```ruby
config.filter_adapter = :wordlist   # default: :wordlist
```

The default **text** adapter used by `moderates :field` and `Moderate.classify`. Every adapter — built-in or yours — implements the same tiny contract, so they're interchangeable per field:

```ruby
adapter.classify(value)  # => Moderate::Result(allowed:, categories:, scores:)
```

Exactly **one** adapter ships built in:

| Adapter | Use it for | Notes |
| --- | --- | --- |
| `:wordlist` (default) | text | Fast, multilingual, **offline**, zero-dependency. Unicode + leetspeak + spacing-evasion resistant. Ships `en`/`es` lists; extend with `additional_words` / `excluded_words`. |

For anything nuanced — context-aware text, images, a hosted moderation API — you **bring and name your own adapter** with `register_adapter` (next section). Two ready-to-copy reference adapters live under [`examples/`](../examples/): `examples/openai_moderation_adapter.rb` (OpenAI `omni-moderation-latest`, text + image, via the `ruby_llm` gem) and `examples/aws_rekognition_adapter.rb` (image moderation via `aws-sdk-rekognition`). They are **not shipped, loaded, or a dependency** — copy one into your app, add its gem to *your* Gemfile, and register it. `moderate` intentionally does **not** ship a built-in "LLM" or image adapter: the contract is `classify(value) → Result`, and whether the backend behind your adapter is an LLM, a hosted endpoint, or a regex is your call, not the gem's.

### `register_adapter` — bring your own backend

An adapter is just an object that responds to `classify` and returns a `Moderate::Result`. Register it once under a name you choose, then reference it anywhere by that name:

```ruby
class OpenAIModerator
  def classify(value)
    resp = OpenAI.moderate(value)   # your call
    Moderate::Result.new(
      allowed:    !resp.flagged?,
      categories: resp.categories,                 # e.g. [:hate, :harassment]
      scores:     resp.category_scores             # { hate: 0.92, harassment: 0.13 }  (0..1)
    )
  end
end

Moderate.configure do |config|
  config.register_adapter :openai, OpenAIModerator.new

  # now use it by name, per field:
  config.filter "Comment", :body, with: :openai, mode: :flag
end
```

```ruby
# or right on the model:
class Comment < ApplicationRecord
  moderates :body, with: :openai, mode: :flag
end
```

The name is **yours** — `:openai`, `:replicate`, `:hive`, `:my_classifier`, whatever reads well in your models. The `source` recorded on resulting `Moderate::Flag`s is that name, so your moderation queue shows exactly which backend flagged each item.

> [!TIP]
> You don't have to write the adapter from scratch. Two production-shaped reference adapters ship under [`examples/`](../examples/) — `examples/openai_moderation_adapter.rb` (OpenAI, text + image, via `ruby_llm`) and `examples/aws_rekognition_adapter.rb` (image moderation via `aws-sdk-rekognition`). Copy one in, add its gem to *your* Gemfile, and `register_adapter` it. They're reference code, not a gem dependency, so nothing is pulled into an app that doesn't want it.

### `additional_words` / `excluded_words`

```ruby
config.additional_words = %w[customword anotherword]   # default: []
config.excluded_words   = %w[scunthorpe assangea]      # default: []
```

Two layers on top of the built-in `:wordlist`:

- **`additional_words`** — domain-specific terms you want caught that aren't in the shipped lists.
- **`excluded_words`** — false positives you never want flagged (the classic "Scunthorpe problem" — legitimate words that contain a substring of a banned one).

Both apply only to the `:wordlist` adapter. (The old `0.x` `additional_words`/`excluded_words` config keys carry over unchanged — see [Upgrading from 0.x](../README.md#upgrading-from-0x).)

### `report_categories` — customize the in-app community category list

```ruby
config.report_categories = %w[harassment hate spam fraud my_custom_label]   # default: nil
```

The in-app **community report** category set a user picks from when they tap "Report" (`harassment`, `spam`, …). Leave it `nil` (the default) to use the gem's `Moderate::Report::DEFAULT_CATEGORIES`; set an Array to replace the list with your own. The `category` value is validated **in the model** (a frozen constant + an ActiveModel `inclusion` validation), **not** by a database `CHECK` constraint, so **adding or narrowing a category never requires a migration** — change this one config line and you're done.

```ruby
Moderate::Report.report_categories
# => your config.report_categories if set, else Moderate::Report::DEFAULT_CATEGORIES
```

> [!NOTE]
> This is the **community** taxonomy only. The separate, regulator-aligned **DSA legal-reason** taxonomy (`Moderate::Report::DSA_LEGAL_REASONS`) and the EU member-state list are **not** host-overridable — they're defined by the regulation, so widening them is a gem change, not host config.

### `filter` — per-field policy in the initializer

If you'd rather keep all your Trust & Safety policy in one place instead of sprinkling `moderates` across models, declare per-field filters in the initializer. Same effect, same arguments:

```ruby
config.filter "Message", :body,   with: :wordlist,    mode: :flag
config.filter "Profile", :bio,    with: :wordlist,    mode: :block
config.filter "Profile", :avatar, with: :rekognition, mode: :flag   # a reference adapter you registered
```

`config.filter "Class", :field, with:, mode:` is the initializer twin of `moderates :field, with:, mode:` on the model. Use whichever fits your taste; you can mix both. (Reportable classes themselves are auto-discovered from the reportable macro — there's no separate registry to maintain.)

---

## Hooks

`moderate` never sends an email, writes to *your* audit log, or decides what "banned" means in your app. It **emits events** and **calls handlers** you wire once. All four hooks default to a no-op, so the gem works untouched — wire them as you need them.

### `audit` — record important actions

```ruby
config.audit = ->(event) { AuditLog.record!(event_type: event.name, data: event.payload) }
```

Called for **every important action** so you can write it to your own audit system. The gem never touches your audit log directly. The event carries a stable envelope:

```ruby
event.name        # Symbol, e.g. :report_decision
event.subject     # the record acted on (a Report, Block, Flag, Appeal…)
event.actor       # who took the action (a moderator, a user, or nil for system)
event.recipients  # who should be notified (Array)
event.payload     # Hash of event-specific context (includes :summary)
event.to_h        # the whole envelope as a Hash
```

### `notify` — fan out anywhere

```ruby
config.notify = ->(event) do
  case event.name
  when :report_received, :report_decision, :affected_user_decision
    ModerationMailer.with(event: event).public_send(event.name).deliver_later   # goodmail
  when :content_flagged
    Telegrama.send_message("🚩 #{event.payload[:summary]}")                      # admin alert
  end
end
```

Called for **every notifiable event**. One hook drives them all — `goodmail` for user emails, `telegrama` for admin alerts, `noticed` for in-app feed + push — because every event shares the same envelope. The full vocabulary:

```
report_received   report_decision   affected_user_decision
appeal_received   appeal_decision
user_blocked      user_unblocked    user_banned
content_flagged   content_removed
```

> [!IMPORTANT]
> Keep `notify` (and `audit`) **fast** — use background jobs (`deliver_later`, `perform_later`). These hooks run inside the moderation action's flow; slow work here slows down every decision and every block.

### `on_block` — side effects when a block happens

```ruby
config.on_block = ->(blocker:, blocked:, at:) { CancelPendingInvites.call(blocker, blocked, at: at) }
```

Optional teardown when one user blocks another — cancel a pending invite, leave a shared room, drop a follow. Signature is **keyword args** (`blocker:`, `blocked:`, `at:`), where `at` is the created block row's timestamp. No-op by default. (A `user_blocked` event also fires through `notify`; use `on_block` for *domain side effects* and `notify` for *messaging*.)

### `ban_handler` — what "banned" means in your app

```ruby
config.ban_handler = ->(user:, by:, reason:) { user.suspend!(reason: reason) }
```

`moderate` doesn't own your user lifecycle, so it **never bans a user itself**. When a moderator resolves a report with `ban_user: true` (see [the madmin queue](madmin.md#step-3--the-controller-call-the-gems-decision-methods)), this proc decides what "banned" means in your domain — `suspend!`, soft-delete, flip a flag, revoke sessions, whatever. Signature is **keyword args** (`user:`, `by:`, `reason:`). No-op by default — the decision still audits and notifies even if you haven't wired a ban yet, so you're never silently dropping the action.

---

## Misc

### `locale`

```ruby
config.locale = :en   # default: your app's I18n.default_locale
```

The locale for copy `moderate` generates on its own — filter validation messages, the DSA statement-of-reasons taxonomy labels, the notice-form strings. Leave it unset to follow `I18n.default_locale`.

---

## How the macros relate to config

Config sets defaults; the model macros consume them. The two halves of the API:

| In the model | In the initializer | What it controls |
| --- | --- | --- |
| `participates_in_moderation` (or `include Moderate::Actor`) | `config.user_class` | Who can report/block and be reported/banned |
| `reportable :title, :description` (or `include Moderate::Reportable`) | — (auto-discovered) | Which content is reportable, and which fields |
| `moderates :body, with:, mode:` | `config.default_filter_mode`, `config.filter_adapter`, `config.filter "…"` | Pre-publication filtering per field |

Both sugar macros have an exactly-equivalent `include` form for include-purists — `participates_in_moderation` ⇔ `include Moderate::Actor`, `reportable` ⇔ `include Moderate::Reportable`. They compile to the same thing.

---

## Validation & errors

`moderate` validates your config at the end of `configure` and raises a plain-English `ArgumentError` on a bad value:

```ruby
config.default_filter_mode = :reject
# => ArgumentError: default_filter_mode must be one of: off, block, flag

config.filter "Message", :body, with: :gpt5, mode: :flag
# => ArgumentError: unknown filter adapter :gpt5 — the only built-in is :wordlist;
#    register your own with `config.register_adapter :gpt5, MyAdapter.new`
```

Modes and adapter names are normalized (`to_s.strip.downcase.to_sym`), so `"Block"`, `:block`, and `" block "` all mean the same thing. This matches the validating-setter convention across the ecosystem (`usage_credits` `default_currency=`, `wallets` `default_asset=`).

## See also

- [Admin & the moderation queue](madmin.md) — wiring `ban_handler` / `notify` / `audit` into a real admin
- [The DSA notice form](dsa-notice-form.md) — the notice-form-specific config keys
- [Notifications & audit](../README.md#-notifications---audit--one-hook-each) — the event vocabulary in full
- [Content filtering](../README.md#-content-filtering-off--block--flag) — the `moderates` macro and the adapter contract
- [Upgrading from 0.x](../README.md#upgrading-from-0x) — what carries over from the profanity-validator era
