# frozen_string_literal: true

# Load the in-memory recorder the four host hooks dispatch into. `require_relative`
# (not autoload): an initializer runs during boot, before the dummy's autoload
# paths are fully usable for an arbitrary non-`app/` constant, and the hooks below
# reference the recorder immediately.
require_relative "../support/moderate_test_recorder"

# Load the host's bring-your-own image adapter the SAME way, for the SAME reason: the
# block below registers it immediately (and config.filter "Comment", :image triggers
# validate!, which insists the :image adapter already exists), and a config
# initializer can run before app/adapters is autoloadable. require_relative sidesteps
# the autoload-timing question entirely.
require_relative "../../app/adapters/dummy_image_adapter"

# The dummy host's boot-time configuration — the same `Moderate.configure` block a
# real host writes in config/initializers/moderate.rb.
#
# IMPORTANT NUANCE for whoever writes the tests: test/test_helper.rb calls
# `Moderate.reset!` in `setup`, which wipes this config back to defaults, then
# re-applies only `config.user_class = "User"`. So the filter policies and the
# hook wiring declared HERE exist at BOOT (and for any code that runs before the
# first test's setup), but a test that needs the recorder hooks or a filter policy
# should re-establish them inside its own `Moderate.configure` block (the suite's
# shared setup is the natural place to re-point the hooks at ModerateTestRecorder).
# This file documents the canonical wiring; the suite mirrors it post-reset.
Moderate.configure do |config|
  # WHO ARE YOUR USERS — the actor model (include Moderate::Actor / has_moderation_capabilities).
  # Stored as a string, constantized lazily, so this works even though User isn't
  # loaded yet at boot.
  config.user_class = "User"

  # CONTENT FILTERING — a couple of per-field policies, declared here in the
  # initializer (the twin of `moderates :field, with:, mode:` on the model).
  #
  #   Comment#body  : :block — reject a save synchronously if the wordlist trips.
  #                   :wordlist is synchronous, so :block is valid (the spine's
  #                   validate! would raise if we paired :block with an async adapter).
  #   User#name     : :flag  — allow the save, then file a Moderate::Flag after commit
  #                   for review (useful for fields you never want to hard-block).
  config.filter "Comment", :body, with: :wordlist, mode: :block
  config.filter "User", :name, with: :wordlist, mode: :flag

  # IMAGE FILTERING — bring-your-own. The gem ships only the offline text :wordlist;
  # image moderation is a host-registered adapter. We register a trivial async image
  # adapter under the name :image (the Comment#image field points `with: :image` at
  # it). It's async, so it's only valid in :flag mode. (Tests that exercise this path
  # re-register it inside their own configure block, since the suite's setup calls
  # Moderate.reset!, which wipes registered adapters — see test/test_helper.rb.)
  config.register_adapter :image, DummyImageAdapter.new
  config.filter "Comment", :image, with: :image, mode: :flag

  # AUDIT — every important action is recorded into the in-memory recorder so tests
  # can assert `ModerateTestRecorder.audits` instead of reaching into a real audit
  # store. Signature: one Moderate::Event.
  config.audit = ->(event) { ModerateTestRecorder.audit(event) }

  # NOTIFY — every notifiable event is buffered so tests can assert what would have
  # been sent. Returns a truthy value so Moderate.notify reports "delivered" (the
  # DSA Art. 16(4) confirmation-of-receipt gate reads that return value).
  config.notify = ->(event) { ModerateTestRecorder.notify(event) }

  # ON BLOCK — keyword-arg side-effect hook, captured for assertions.
  config.on_block = ->(blocker:, blocked:, at:) { ModerateTestRecorder.on_block(blocker: blocker, blocked: blocked, at: at) }

  # BAN HANDLER — keyword-arg hook deciding what "banned" means. The recorder just
  # captures the request; a test can assert the gem asked for a ban without the
  # dummy owning a real user-suspension lifecycle.
  config.ban_handler = ->(user:, by:, reason:) { ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason) }
end
