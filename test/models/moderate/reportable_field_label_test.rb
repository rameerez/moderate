# frozen_string_literal: true

require "test_helper"

# Moderate.reportable_field_label — what humans call a reported field.
#
# The bug this exists for: a host's queue printed «Body» for every report of a
# chat message, because the gem only ever knew the column name. The host then
# kept a hand-written field → label map in its admin helper. These tests pin the
# resolution order that replaces that map:
#
#   labels: on the declaration > model i18n > field i18n > field.humanize
# A real namespace for the namespaced-model test (ActiveModel derives the i18n key
# from the class's module parents, which must exist — as `Chats` does in a host).
module LabelChats; end

module Moderate
  class ReportableFieldLabelTest < ActiveSupport::TestCase
    teardown do
      # store_translations below writes straight into the backend; reload! drops
      # it so the next test sees only the shipped + dummy locale files again.
      I18n.backend.reload!
    end

    # --- Precedence -----------------------------------------------------------

    test "a label declared on the field beats model i18n, field i18n and humanize" do
      klass = reportable_class("LabelPrecedenceNote", :body, labels: { body: "Chat message" })
      store(reportable_fields: { body: "Field i18n", label_precedence_note: { body: "Model i18n" } })

      assert_equal "Chat message", Moderate.reportable_field_label(klass, :body)
    end

    test "model-scoped i18n beats the field-wide key" do
      klass = reportable_class("ModelI18nNote", :body)
      store(reportable_fields: { body: "Field i18n", model_i18n_note: { body: "Model i18n" } })

      assert_equal "Model i18n", Moderate.reportable_field_label(klass, :body)
    end

    test "the field-wide i18n key beats humanize" do
      klass = reportable_class("FieldI18nNote", :summary_line)
      store(reportable_fields: { summary_line: "Field i18n" })

      assert_equal "Field i18n", Moderate.reportable_field_label(klass, :summary_line)
    end

    test "an unlabeled, untranslated field falls back to humanize" do
      klass = reportable_class("HumanizeNote", :pickup_point)

      assert_equal "Pickup point", Moderate.reportable_field_label(klass, :pickup_point)
    end

    test "the gem's shipped generic labels replace the raw column name" do
      klass = reportable_class("GenericNote", :body, :avatar, :files)

      assert_equal "Text", Moderate.reportable_field_label(klass, :body)
      assert_equal "Files", Moderate.reportable_field_label(klass, :files)

      I18n.with_locale(:es) do
        assert_equal "Texto", Moderate.reportable_field_label(klass, :body)
        assert_equal "Foto de perfil", Moderate.reportable_field_label(klass, :avatar)
      end
    end

    test "a blank field has no label (a whole-record report names no field)" do
      assert_nil Moderate.reportable_field_label(Comment, nil)
      assert_nil Moderate.reportable_field_label(Comment, "")
      assert_nil Moderate.reportable_field_label(Comment, "  ")
    end

    # --- Declaration forms ------------------------------------------------------

    test "the macro and the explicit-include form both take labels:" do
      via_macro = reportable_class("MacroLabelNote", :body, labels: { body: "Via macro" })
      via_include = Class.new(ApplicationRecord) do
        self.table_name = "comments"
        def self.name = "IncludeLabelNote"
        include Moderate::Reportable
        reportable_fields :body, labels: { "body" => "Via include" }
      end

      assert_equal "Via macro", via_macro.reportable_field_label(:body)
      assert_equal "Via include", via_include.reportable_field_label("body")
      assert_equal ["body"], via_include.reportable_fields
    end

    test "a callable label is evaluated at read time, under the current locale" do
      store(custom_labels: { body: "Message" })
      I18n.backend.store_translations(:es, moderate: { custom_labels: { body: "Mensaje" } })
      label = -> { I18n.t("moderate.custom_labels.body") }
      klass = reportable_class("CallableLabelNote", :body, labels: { body: label })

      assert_equal "Message", klass.reportable_field_label(:body)
      I18n.with_locale(:es) { assert_equal "Mensaje", klass.reportable_field_label(:body) }
    end

    test "labels stay optional and per field: unlabeled fields still fall through" do
      klass = reportable_class("PartialLabelNote", :body, :pickup_point, labels: { body: "Chat message" })

      assert_equal "Chat message", klass.reportable_field_label(:body)
      assert_equal "Pickup point", klass.reportable_field_label(:pickup_point)
    end

    test "a declaration without labels keeps the pre-labels behavior" do
      klass = reportable_class("NoLabelsNote", :body)

      assert_equal ["body"], klass.reportable_fields
      assert_equal({}, klass.moderation_reportable_field_labels)
    end

    test "redeclaring fields replaces the labels too (last declaration wins)" do
      klass = reportable_class("RedeclaredNote", :body, labels: { body: "Old label" })
      klass.reportable_fields :body

      assert_equal "Text", klass.reportable_field_label(:body)
    end

    test "a label for a field that isn't reportable raises, naming it" do
      error = assert_raises(ArgumentError) do
        reportable_class("TypoLabelNote", :body, labels: { bdoy: "Chat message" })
      end

      assert_match(/bdoy/, error.message)
      assert_match(/TypoLabelNote/, error.message)
    end

    test "labels: without the fields it labels raises" do
      assert_raises(ArgumentError) { reportable_class("FieldlessLabelNote", labels: { body: "Chat message" }) }
    end

    # --- Class resolution -----------------------------------------------------

    test "records, classes and stored class-name strings resolve the same label" do
      comment = Comment.new(body: "hi")

      assert_equal "Comment text", Moderate.reportable_field_label(comment, :body)
      assert_equal "Comment text", Moderate.reportable_field_label(Comment, :body)
      assert_equal "Comment text", Moderate.reportable_field_label("Comment", "body")
      assert_equal "Comment text", comment.reportable_field_label(:body)
    end

    test "an unknown class name still tries its model key, then the generic one" do
      store(reportable_fields: { "retired/post": { body: "Retired post text" } })

      assert_equal "Retired post text", Moderate.reportable_field_label("Retired::Post", :body)
      assert_equal "Text", Moderate.reportable_field_label("Retired::Gone", :body)
    end

    test "namespaced models use their i18n_key (chats/message)" do
      klass = reportable_class("LabelChats::Message", :body)
      store(reportable_fields: { "label_chats/message": { body: "Chat message" } })

      assert_equal "Chat message", klass.reportable_field_label(:body)
    end

    test "a class whose namespace doesn't resolve still gets its model key, never an error" do
      klass = reportable_class("UnloadedNamespace::Message", :body)
      store(reportable_fields: { "unloaded_namespace/message": { body: "Still labeled" } })

      assert_equal "Still labeled", klass.reportable_field_label(:body)
    end

    test "a declared label that raises falls back instead of breaking the page" do
      klass = reportable_class("RaisingLabelNote", :body, labels: { body: -> { raise "boom" } })

      assert_equal "Text", klass.reportable_field_label(:body)
    end

    test "an STI child inherits declared labels and its reportable parent's i18n" do
      parent = reportable_class("StiParentNote", :body, :pickup_point, labels: { body: "Parent label" })
      child = Class.new(parent) { def self.name = "StiChildNote" }
      store(reportable_fields: { sti_parent_note: { pickup_point: "Parent pickup" } })

      assert_equal "Parent label", child.reportable_field_label(:body)
      assert_equal "Parent pickup", child.reportable_field_label(:pickup_point)

      store(reportable_fields: { sti_child_note: { pickup_point: "Child pickup" } })
      assert_equal "Child pickup", child.reportable_field_label(:pickup_point)
    end

    test "a field named like a model with scoped labels is never labeled with a Hash" do
      # `listing` is both a reportable field here and, via the store below, a
      # model-scoped key. The generic lookup reads a Hash and must ignore it.
      klass = reportable_class("CollisionNote", :listing)
      store(reportable_fields: { listing: { description: "Driver note" } })

      assert_equal "Listing", klass.reportable_field_label(:listing)
    end

    # --- Report / Flag readers ------------------------------------------------

    test "Report#reported_field_label and Flag#field_label survive the record's deletion" do
      reporter = create_user
      comment = Comment.create!(user: create_user, body: "a normal comment")
      report = reporter.report!(comment, category: :harassment, reported_field: "body", details: "abusive")
      flag = flag!(comment)

      assert_equal "Comment text", report.reported_field_label
      assert_equal "Comment text", flag.field_label

      comment.destroy!
      assert_equal "Comment text", report.reload.reported_field_label
      assert_equal "Comment text", Moderate::Flag.find(flag.id).field_label
    end

    test "a whole-record report has no field label" do
      report = create_user.report!(Comment.create!(user: create_user, body: "hi"), category: :spam, details: "spam")

      assert_nil report.reported_field_label
    end

    # --- Event payloads -------------------------------------------------------

    test "events carry the label next to the raw field, and summaries print the label" do
      Moderate.configure do |config|
        config.audit = ->(event) { ModerateTestRecorder.audit(event) }
        config.notify = ->(event) { ModerateTestRecorder.notify(event) }
      end
      ModerateTestRecorder.clear

      moderator = create_user
      comment = Comment.create!(user: create_user, body: "a normal comment")
      report = create_user.report!(comment, category: :harassment, reported_field: "body", details: "abusive")

      received = ModerateTestRecorder.notifications_named(:report_received).first
      assert_equal "body", received.payload[:reported_field]
      assert_equal "Comment text", received.payload[:reported_field_label]
      assert_equal "New harassment report on Comment ##{comment.id} · Comment text", received.summary

      report.resolve!(by: moderator, remove_content: true, note: "Abusive")
      statement = ModerateTestRecorder.notifications_named(:affected_user_decision).first
      assert_equal "body", statement.payload[:reported_field]
      assert_equal "Comment text", statement.payload[:reported_field_label]
      assert_equal "body", ModerateTestRecorder.audits_named(:report_decision).first.payload[:reported_field]

      flag = flag!(comment)
      flagged = ModerateTestRecorder.notifications_named(:content_flagged).first
      assert_equal "Comment text", flagged.payload[:field_label]
      assert_equal "content flagged (manual) on Comment ##{comment.id} · Comment text", flagged.summary
      refute_match(/#body/, flagged.summary)

      Moderate::Services::ResolveFlag.new(flag, by: moderator).dismiss!(note: "Fine")
      assert_equal "Comment text", ModerateTestRecorder.audits_named(:flag_decision).first.payload[:field_label]
    end

    private

    def create_user
      @user_seq = (@user_seq || 0) + 1
      User.create!(name: "Label User #{@user_seq}", email: "label-user-#{@user_seq}-#{SecureRandom.hex(3)}@example.com")
    end

    def flag!(comment)
      Moderate::Flag.flag!(
        flaggable: comment, field: "body", owner: comment.user, source: "manual", mode: "flag",
        excerpt: "x", categories: ["harassment"], scores: {}, context: {}
      )
    end

    # A throwaway reportable model on the comments table. `def self.name` comes
    # first so the macro registers (and model_name derives) the intended name.
    def reportable_class(class_name, *fields, labels: nil)
      Class.new(ApplicationRecord) do
        self.table_name = "comments"
        define_singleton_method(:name) { class_name }
        has_reportable_content(*fields, labels: labels)
      end
    end

    def store(**translations)
      I18n.backend.store_translations(:en, moderate: translations)
    end
  end
end
