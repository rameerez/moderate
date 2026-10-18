# frozen_string_literal: true

require "test_helper"

# A ban, a host-side unban, then a second ban decision in the same episode: the
# earlier ban covers the new one only while the account is still banned, which the
# host says through `config.banned`. Without it, the earlier ban counts (as before).
class Moderate::BanAfterUnbanTest < ActiveSupport::TestCase
  setup do
    @suspended = Set.new
    suspended = @suspended
    Moderate.configure do |config|
      config.ban_handler = lambda do |user:, by:, reason:|
        suspended << user.id
        ModerateTestRecorder.ban_handler(user: user, by: by, reason: reason)
      end
    end
    ModerateTestRecorder.clear
    @reporter = User.create!(name: "Reporter", email: "reporter@example.com")
    @author = User.create!(name: "Author", email: "author@example.com")
    @moderator = User.create!(name: "Mod", email: "mod@example.com")
    # Two reports of one episode: both filed before the first decision.
    @first = @reporter.report!(Comment.create!(user: @author, body: "one"), category: :harassment, field: :body)
    @second = @reporter.report!(Comment.create!(user: @author, body: "two"), category: :harassment, field: :body)
  end

  def ban_twice_with_an_unban_between
    @first.resolve!(by: @moderator, note: "Harassment", ban_user: true)
    @suspended.delete(@author.id) # an admin lifts the ban in the host app
    @second.resolve!(by: @moderator, note: "Harassment again", ban_user: true)
    @second.reload
  end

  test "with config.banned, a person unbanned since is banned again, and the statement is true" do
    suspended = @suspended
    Moderate.config.banned = ->(user) { suspended.include?(user.id) }

    ban_twice_with_an_unban_between

    assert_equal 2, ModerateTestRecorder.bans.size, "the ban_handler ran again"
    assert_includes @suspended, @author.id
    assert_nil @second.resolution_actions["ban_already_applied_by"]
    assert_equal "account_suspended", @second.decision_visibility
  end

  test "with config.banned, a person still banned is covered by the earlier ban" do
    Moderate.config.banned = ->(_user) { true }

    @first.resolve!(by: @moderator, note: "Harassment", ban_user: true)
    @second.resolve!(by: @moderator, note: "Harassment again", ban_user: true)

    assert_equal 1, ModerateTestRecorder.bans.size
    assert_equal @first.id, @second.reload.resolution_actions["ban_already_applied_by"]
  end

  test "without config.banned, the earlier ban counts, as before" do
    ban_twice_with_an_unban_between

    assert_equal 1, ModerateTestRecorder.bans.size
    assert_equal @first.id, @second.resolution_actions["ban_already_applied_by"]
  end

  test "config.banned must be callable" do
    assert_raises(ArgumentError) { Moderate.config.banned = "yes" }
  end
end
