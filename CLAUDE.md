# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Please read the `README.md` for a full overview of the gem's API and philosophy, and the `docs/` directory (`docs/configuration.md`, `docs/notifications.md`, `docs/compliance.md`, `docs/madmin.md`, `docs/dsa-notice-form.md`) for the detailed integration guides.

This gem is part of a coherent ecosystem (`railsfast`, `goodmail`, `telegrama`, `usage_credits`, `pricing_plans`, `wallets`, `api_keys`). Match the ecosystem conventions exactly: a single `Moderate.configure do |config| … end` block, `has_*`/verb-style class macros, adapter objects + no-op-default hook procs, string class names constantized lazily, adaptive install migrations, Minitest with a `test/dummy` app, SimpleCov, and the README/docs voice.
