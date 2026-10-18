# frozen_string_literal: true

module Admin
  # The dummy host's admin decision endpoints: one controller per queue, each just
  # `include Moderate::Moderation` (the drop-in resolve/dismiss/uphold/reject actions)
  # plus the two things the concern leaves to the host — loading the record and saying
  # who the moderator is. Real hosts put this behind their admin auth; the dummy names
  # the moderator in a param so the integration test can act as one.
  class DecisionsController < ActionController::Base
    include Moderate::Moderation

    # A real admin keeps its CSRF protection; the dummy's test posts without a form.
    skip_forgery_protection

    before_action { @record = self.class::MODEL.find(params[:id]) }

    private

    def current_user = User.find(params[:moderator_id])

    def moderation_redirect_path(_record) = "/"
  end
end
