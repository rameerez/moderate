# frozen_string_literal: true

require_relative "lib/moderate/version"

Gem::Specification.new do |spec|
  spec.name = "moderate"
  spec.version = Moderate::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Trust & Safety for your Rails app: report, block, filter, and an EU DSA / App Store / Play compliant moderation queue"
  spec.description = "moderate is a complete, opinionated Trust & Safety layer for Rails apps with user-generated content. Let users report abusive content and other users, block each other (bidirectional, enforced everywhere), and filter objectionable text and images before they're posted (off/block/flag, with pluggable wordlist/image/LLM backends). Run a real moderation queue with audited resolve/dismiss/remove-content/ban actions, internal appeals, and statement-of-reasons notifications. Ships aligned with the EU Digital Services Act (notice-and-action, statement of reasons, appeals, transparency) and the Apple App Store and Google Play user-generated-content review guidelines. UI-agnostic primitives (models, services, helpers, controller concerns) that plug into madmin, goodmail, telegrama, and noticed."
  spec.homepage = "https://github.com/rameerez/moderate"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
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
  spec.add_dependency "globalid", ">= 1.0"
  spec.add_dependency "railties", ">= 7.1.0", "< 9.0"
end
