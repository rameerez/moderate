# frozen_string_literal: true

module Admin
  class AppealsController < DecisionsController
    MODEL = Moderate::Appeal
  end
end
