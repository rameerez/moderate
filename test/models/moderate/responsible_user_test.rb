# frozen_string_literal: true

require "test_helper"

module Moderate
  # A seat that speaks without being a person: a support desk, a bot. chats answers
  # `author || sender` for a message, which is a desk for an unsigned support reply.
  class TestDesk
    def id = 42
    def to_s = "Support desk"
  end

  # Content a desk said. Same table as Comment; only the owner differs.
  class DeskComment < ::Comment
    self.table_name = "comments"

    def reported_owner = TestDesk.new
  end

  # A reportable that forgot to say who is behind it.
  class OwnerlessComment < ::Comment
    self.table_name = "comments"

    def reported_owner = Moderate::Reportable.instance_method(:reported_owner).bind_call(self)
  end

  class ResponsibleUserTest < ActiveSupport::TestCase
    OBJECTIONABLE = "you are a bitch"

    setup do
      ModerateTestRecorder.clear
      @reporter = create_user
      @author = create_user
    end

    test "a person owner is the responsible user" do
      comment = Comment.create!(user: @author, body: "hi")

      assert_equal @author, Moderate.responsible_user(comment)
      assert_equal @author, Moderate.responsible_user(@author), "a user answers for themselves"
    end

    test "an owner that isn't the configured user class means nobody" do
      assert_nil Moderate.responsible_user(DeskComment.create!(user: @author, body: "On it"))
    end

    test "records without the contract, and nil, have nobody" do
      assert_nil Moderate.responsible_user(nil)
      assert_nil Moderate.responsible_user(Object.new)
    end

    test "a reportable that never defined reported_owner still fails loudly" do
      comment = OwnerlessComment.create!(user: @author, body: "hi")

      error = assert_raises(NotImplementedError) { Moderate.responsible_user(comment) }
      assert_match(/reported_owner/, error.message)
    end

    test "a report on desk-spoken content files with no reported user" do
      comment = DeskComment.create!(user: @author, body: "Automated notice")

      report = @reporter.report!(comment, category: :spam, details: "Not from a person", field: :body)

      assert_predicate report, :persisted?
      assert_nil report.reported_user
      assert_equal "Automated notice", report.snapshot["content_text"], "the evidence is still kept"
    end

    test "Flag.flag! drops an owner that isn't a person" do
      comment = DeskComment.create!(user: @author, body: "hi")

      flag = Moderate::Flag.flag!(
        flaggable: comment, field: "body", owner: comment.reported_owner, source: "manual", mode: "flag",
        excerpt: "hi", categories: [], scores: {}, context: {}
      )

      assert_nil flag.owner
    end

    test "a :flag filter on desk-spoken content files an unattributed flag" do
      Moderate.configure { |config| config.filter "Moderate::DeskComment", :body, with: :wordlist, mode: :flag }

      comment = DeskComment.create!(user: @author, body: OBJECTIONABLE)

      flag = Moderate::Flag.find_by!(flaggable: comment, field: "body")
      assert_nil flag.owner
    end

    private

    def create_user(**attributes)
      @user_seq ||= 0
      @user_seq += 1
      User.create!(name: "User #{@user_seq}", email: "user#{@user_seq}@example.com", **attributes)
    end
  end
end
