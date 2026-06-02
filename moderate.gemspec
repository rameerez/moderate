# frozen_string_literal: true

require_relative "lib/moderate/version"

Gem::Specification.new do |spec|
  spec.name = "moderate"
  spec.version = Moderate::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Trust & Safety and content moderation for Rails: report abusive content, block users, filter objectionable text and images, and run an audited moderation queue — with DSA-aligned and App Store / Google Play UGC primitives."
  spec.description = "moderate is a complete Trust & Safety and content moderation engine for Ruby on Rails apps with user-generated content (UGC) — social apps, marketplaces, dating, communities, forums, comments, reviews, and chat. It bundles the four things every UGC app needs behind one data model and one set of hooks: abuse reporting (report posts, comments, profiles, listings, messages, and other users), bidirectional user blocking behind a single enforced source of truth, pre-publication content filtering for profanity, slurs, hate, spam, harassment, and objectionable or NSFW text and images in off/block/flag modes, and an audited moderation queue with locked resolve/dismiss/remove-content/ban decisions, internal appeals, and statement-of-reasons notifications. Filtering uses a tiny classify(value) => Result adapter contract: a fast, offline, multilingual wordlist/profanity/bad-word blocklist ships as the zero-dependency default, and you bring your own classifier (OpenAI omni-moderation, AWS Rekognition image/NSFW detection, Google Perspective, or self-hosted) as an optional reference adapter, never a forced dependency. moderate also ships primitives aligned with the EU Digital Services Act (DSA notice-and-action, statement of reasons, appeals, transparency) and with the Apple App Store (Guideline 1.2) and Google Play user-generated-content review rules that get apps rejected without report/block/filter — the mechanisms, not a compliance certificate. It is a mountable, UI-agnostic Rails engine with no hard dependencies beyond ActiveRecord, ActiveSupport, Railties, and GlobalID, and optionally auto-integrates with madmin, goodmail, telegrama, noticed, and rails_cloudflare_turnstile — a modern, full-stack alternative to single-purpose Rails profanity filters like obscenity and profanity-filter."
  spec.homepage = "https://github.com/rameerez/moderate"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  # NOTE: `homepage_uri` is derived from `spec.homepage` automatically — setting it
  # here too only triggers a "same URI for multiple keys" warning, so we don't.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies — kept minimal and host-agnostic on purpose.
  # Notifications (goodmail/noticed/telegrama), image/LLM moderation backends,
  # and the admin UI (madmin) are OPTIONAL integrations wired via hooks, never
  # hard dependencies, so `moderate` runs standalone in any Rails app.
  spec.add_dependency "activerecord", ">= 7.1.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1.0", "< 9.0"
  spec.add_dependency "globalid", "~> 1.0"
  spec.add_dependency "railties", ">= 7.1.0", "< 9.0"
end
