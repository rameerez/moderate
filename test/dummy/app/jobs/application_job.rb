# frozen_string_literal: true

# The dummy host's base job. The gem's own jobs (Moderate::ClassifyJob, used by the
# async :flag classify path) are namespaced under the engine and inherit from
# ActiveJob::Base directly; this base exists so the host has the conventional
# ApplicationJob the Rails app skeleton expects.
class ApplicationJob < ActiveJob::Base
end
