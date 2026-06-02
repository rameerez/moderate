# frozen_string_literal: true

# An in-memory recorder the dummy app wires the gem's four host hooks
# (audit / notify / on_block / ban_handler) into, so the test suite can ASSERT on
# what the gem dispatched without standing up real email, audit, or ban systems.
#
# WHY a plain class (not Mocha stubs) wired in the initializer: the hooks are set
# ONCE at boot in config/initializers/moderate.rb, but the test suite calls
# `Moderate.reset!` in `setup` (see test/test_helper.rb), which wipes those hooks
# back to the no-op defaults. So the suite's `setup` re-runs `Moderate.configure`
# and re-points the hooks at THIS recorder (a stable singleton), then clears it.
# A long-lived recorder object survives reset!, while a fresh `.clear` per test
# keeps assertions isolated. (Mocha expectations, by contrast, are torn down after
# each test and can't be set in a boot-time initializer.)
#
# Everything is host-AGNOSTIC: it just buffers the gem's Event envelopes and the
# block/ban callback args. No domain concepts leak in.
module ModerateTestRecorder
  # Each bucket is an Array we append to. They're module-level so any test can read
  # `ModerateTestRecorder.audits` etc. without threading an instance around.
  @audits = []
  @notifications = []
  @blocks = []
  @bans = []

  class << self
    # The recorded Moderate::Event envelopes for each hook, and the keyword-arg
    # captures for the side-effect hooks. Readers return the live arrays so a test
    # can do e.g. `ModerateTestRecorder.notifications.map(&:name)`.
    attr_reader :audits, :notifications, :blocks, :bans

    # Wipe every bucket. Called from the suite's `setup` so each test starts clean.
    def clear
      @audits.clear
      @notifications.clear
      @blocks.clear
      @bans.clear
      self
    end

    # --- The four hook bodies the initializer points at -----------------------

    # audit(event) — record the Event and return true (audit is observational; the
    # facade swallows audit-hook exceptions, but returning a value is harmless).
    def audit(event)
      @audits << event
      true
    end

    # notify(event) — record the Event and return a TRUTHY value. The truthiness is
    # load-bearing: Moderate.notify returns whether delivery happened (DSA Art. 16(4)
    # confirmation-of-receipt gating reads it), so a test recorder must report
    # "delivered" by returning truthy, exactly as a real mailer's deliver_later would.
    def notify(event)
      @notifications << event
      event # truthy, and lets a test inspect what was "delivered"
    end

    # on_block(blocker:, blocked:, at:) — record the pair and timestamp the gem handed us.
    def on_block(blocker:, blocked:, at:)
      @blocks << { blocker: blocker, blocked: blocked, at: at }
    end

    # ban_handler(user:, by:, reason:) — record the ban request. We DON'T mutate the
    # user here (the gem leaves "what banned means" entirely to the host); a test
    # that wants to assert a real suspension can swap in its own handler.
    def ban_handler(user:, by:, reason:)
      @bans << { user: user, by: by, reason: reason }
    end

    # --- Convenience matchers for assertions ----------------------------------

    # The recorded notification Events whose name matches `name`.
    def notifications_named(name)
      @notifications.select { |event| event.name == name.to_sym }
    end

    # The recorded audit Events whose name matches `name`.
    def audits_named(name)
      @audits.select { |event| event.name == name.to_sym }
    end
  end
end
