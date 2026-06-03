# frozen_string_literal: true

# The dummy host's base model. The gem's own models inherit from
# Moderate::ApplicationRecord (defined in the engine), NOT from this — this is only
# the base for the host's User/Comment models, exactly like a real app.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
