# frozen_string_literal: true

# The dummy app boots against the gem's own Gemfile (set by Bundler / the CI
# matrix's BUNDLE_GEMFILE), NOT a Gemfile inside test/dummy — there isn't one.
# We point Bundler at the engine root's Gemfile (two levels up from this file) so
# the dummy shares the gem's locked dependency set and the Appraisal gemfiles work.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

# bootsnap is an OPTIONAL boot accelerator (it's in the gem's :test group). Require
# it only if present so the dummy still boots if a slimmer bundle omits it.
begin
  require "bootsnap/setup"
rescue LoadError
  # bootsnap not installed — fine, just a slower boot.
end
