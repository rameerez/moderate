# Trust & Safety for [`chats`](https://github.com/rameerez/chats): report, block and filter messages

Messages between users are user-generated content. App Store Guideline 1.2, Google Play's UGC policy and the EU DSA all expect people to be able to **report** a message, **block** its sender, and the app to **filter** and **moderate** what's said. `chats` and `moderate` were built for each other, with no hard dependency either way. `chats` already speaks moderate's reportable contract, so the integration is a handful of lines in your app.

This is the moderate side of the recipe. It is the shape two production apps (CarHey and playscbw) converged on. chats' own README covers its half: the [Trust & Safety section](https://github.com/rameerez/chats#%EF%B8%8F-trust--safety-snaps-onto-the-moderate-gem).

## What chats already answers

`Chats::Message` (and `Chats::Conversation`) implement moderate's duck-typed reportable contract themselves:

| moderate asks | chats answers |
|---|---|
| `reported_owner` | `author \|\| sender`: the person who wrote it. For an unsigned support-desk reply that's the desk, which moderate treats as "nobody to reach" (`Moderate.responsible_user`): the report still files and the content can still be removed. There's nothing to override. |
| `moderation_snapshot(:body)` | the body, frozen into the report as evidence |
| `remove_reported_field!(:body)` | the soft-delete tombstone ("Message deleted"), which also works in a locked conversation |
| `report_visible_to?(viewer)` | participants only, never the author. moderate enforces it when the report is filed, not only when the link renders. |
| `moderation_content_type` | `"message"` (`"group"` for a conversation), stored on the report |

## 1. Make messages reportable and filtered

In an after-boot hook, so a code reload re-applies the macros to the engine's model:

```ruby
# config/initializers/chats_moderation.rb
Rails.application.config.to_prepare do
  Chats::Message.has_reportable_content :body, labels: { body: "Message" }
  Chats::Message.moderates :body, mode: :flag
  # with attachments on:
  # Chats::Message.has_reportable_content :body, :files, labels: { body: "Message", files: "Photo" }
  # Chats::Message.moderates :files, mode: :flag, with: :your_image_adapter
end
```

- **`:flag`, never `:block`.** A wordlist false positive must not gag someone mid-conversation. The message sends, and a pending `Moderate::Flag` lands in the queue.
- **Declare each filter once.** `moderates :body, mode: :flag` and `config.filter "Chats::Message", :body, mode: :flag` write the same policy. Keep one of them; the macro next to `has_reportable_content` reads best.
- **`labels:`** is what the queue, the statement of reasons and the appeal page call the field. Without it they print "Text" (the gem's generic label for `body`).

## 2. Blocks are moderate's, everywhere chats decides something

```ruby
# config/initializers/chats.rb
config.blocked_messager_ids = ->(messager) { messager.is_a?(User) ? Moderate.blocked_ids_for(messager) : [] }
```

A blocked pair can't open a conversation or send into one, and their direct thread leaves both inboxes. The thread is hidden, never deleted: unblocking brings it back. Group conversations are exempt from pair blocks. The `is_a?(User)` guard keeps non-person messagers (a support desk) out of the block table.

`Moderate.blocked_ids_for` always returns a relation of user ids, which chats turns into a subquery. If you compose it with ids of your own, call `.ids` first: `relation | array` gives you User records, not ids.

## 3. Report on a bubble

chats renders each bubble **once per broadcast** and shares it with every viewer, so the bubble can't ask who is looking. That rules out `moderate_report_link`, whose per-viewer check would vanish from live bubbles. Use the viewer-agnostic path in chats' `message_meta` slot, and hide the link on your own bubbles client-side:

```erb
<%# app/views/chats/slots/_message_meta.html.erb %>
<% if message.sender && !message.deleted? %>
  <%= link_to t("messages.report"), moderate_report_target_path(message, field: :body), class: "chats-report" %>
<% end %>
```

```css
.chats-message--own .chats-report { display: none; } /* cosmetic: the server refuses it anyway */
```

`moderate_report_target_path` builds your report form's path (`new_report_path`, or `new_moderate_report_path`, found through `main_app` from inside chats' views) with a signed, non-expiring target (`message.to_moderation_sgid`), so the URL is identical on every render. If your route has another name, build it yourself: `main_app.new_abuse_report_path(target: message.to_moderation_sgid, field: "body")`. Hiding the link is cosmetic. When the report is filed, moderate refuses anyone `report_visible_to?` rejects (a non-participant, the author) with an error on `:reportable`.

Your `ReportsController` stays yours (moderate is UI-agnostic):

```ruby
def create
  reportable = Moderate::Report.locate_signed_reportable(params[:target]) or return head(:not_found)
  current_user.report!(reportable, category: params.dig(:report, :category), details: params.dig(:report, :message),
                       field: params[:field], block: params.dig(:report, :block) == "1")
  redirect_back fallback_location: root_path, notice: t(".filed")
rescue ActiveRecord::RecordInvalid => error
  # …render the form with error.record.errors
end
```

- **The category select:** `f.select :category, Moderate::Report.category_options`. It honors `config.report_categories` and prints labels in the reader's language (English and Spanish ship with the gem).
- **"Report and block":** `block: true` blocks the message's author once the report is filed.

## 4. Block from the thread menu

Put a Block action in chats' `conversation_header_actions` slot, posting to a small controller of yours. Blocking hides the very thread the user is standing in, so land on the inbox, not back:

```ruby
class BlocksController < ApplicationController
  before_action :authenticate_user!

  def create
    current_user.block!(User.find(params[:user_id]))
    redirect_to chats.root_path, status: :see_other
  end

  def destroy
    other = User.find(params[:user_id])
    current_user.unblock!(other)
    redirect_to profile_path(other), status: :see_other # there's no thread to go back to while blocked
  end
end
```

If your inbox badges or notification bell should catch up on both players' screens when a block is placed or lifted, do it from moderate's `user_blocked` / `user_unblocked` events rather than from the controller. They fire after the block commits, and also for blocks placed elsewhere (`report!(…, block: true)`, a console):

```ruby
# config/initializers/moderate.rb
config.notify = lambda do |event|
  case event.name
  when :user_blocked, :user_unblocked
    InboxSettler.call(event.subject.blocker, event.subject.blocked) # your code, refreshing both sides
  end
  # …
end
```

## 5. The admin side

Reports and flags about messages land in moderate's queues (`Moderate::Report.pending`, `Moderate::Flag.pending`) with no chat-specific branches:

- **Open the message in context.** Define `moderation_admin_path(routes)` on `Chats::Message`, in the same `to_prepare`, pointing at your admin transcript, anchored at the line.
- **Decide.** `include Moderate::Moderation` in your admin's reports and flags controllers (see [the madmin guide](madmin.md)). Resolving with `remove_content` removes the message through chats' tombstone. On a flag, `remove_content` / `ban_user` escalate to a report, so the author gets the statement of reasons and the appeal window. A ban needs `config.ban_handler`.
- **"Flag for review" from the transcript:**

  ```ruby
  flag = Moderate::Flag.flag_for_review!(message, field: :body, by: current_user)
  flag.previously_new_record? # => false when one was already waiting
  ```

  It's idempotent under the message's row lock: two moderators pressing it at once file one flag. Skip deleted or system messages yourself; there's nothing left to review.

## Launch checklist

- [ ] `Chats::Message.has_reportable_content :body` (and `:files`), with `labels:`
- [ ] one `:flag` filter per field (macro *or* `config.filter`, not both)
- [ ] `config.blocked_messager_ids` → `Moderate.blocked_ids_for`, for people only
- [ ] Report on every bubble via `moderate_report_target_path`, hidden on your own
- [ ] Block in the thread menu, landing on the inbox; Unblock where the person still is (their profile)
- [ ] `moderation_admin_path` on `Chats::Message`
- [ ] admin decisions wired (`Moderate::Moderation`), and `config.ban_handler` set before anyone can press "ban"
- [ ] `config.notify` for at least `report_received`, `report_decision`, `affected_user_decision` (see [notifications](notifications.md))
