# frozen_string_literal: true

module Admin
  class FlagsController < DecisionsController
    MODEL = Moderate::Flag
  end
end
