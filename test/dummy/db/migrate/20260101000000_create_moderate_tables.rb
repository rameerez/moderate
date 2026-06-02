# frozen_string_literal: true

# CONCRETE rendering of lib/generators/moderate/templates/create_moderate_tables.rb.erb.
#
# This is the SAME schema the install generator copies into a real host — same
# tables, columns, indexes, and check-constraints — rendered to plain Ruby for the
# dummy app's test database. It is run by `rake db:migrate:reset` across all three
# CI database legs (sqlite / postgres / mysql), so the private helpers below are
# kept IDENTICAL to the template's: they branch on the connection adapter to emit
# jsonb-vs-json, MySQL's no-default-on-JSON caveat, and portable IN(...) checks.
#
# KEEP IN SYNC with the ERB template. If the template's column set / indexes /
# constraints change, this file must change too — the sqlite matrix leg runs the
# real migration path precisely to catch drift between the two (see
# .github/workflows/test.yml: "Exercise the real migration path in SQLite too so
# dummy/test schema drift is caught").
#
# The migration version is pinned to [7.1] — the gemspec floor and the lowest Rails
# in the test matrix. (The template renders this from ActiveRecord::VERSION at
# generate time; here we anchor to the floor, which every Rails in the matrix
# accepts.)
class CreateModerateTables < ActiveRecord::Migration[7.1]
  def change
    primary_key_type, foreign_key_type = primary_and_foreign_key_types

    # ---------------------------------------------------------------------------
    # moderate_reports
    #
    # A report/notice + an immutable evidence snapshot + decision metadata + the
    # appeal window. Serves both in-app community reports and public DSA legal
    # notices (distinguished by `intake_kind`).
    # ---------------------------------------------------------------------------
    create_table :moderate_reports, id: primary_key_type do |t|
      # Who reported (a user), and who they reported (a user). Nullable because
      # DSA public notices can come from non-users, and reported content does not
      # always resolve to a single account.
      t.references :reporter, type: foreign_key_type, null: true
      t.references :reported_user, type: foreign_key_type, null: true

      # The reported content (any Moderate::Reportable model), polymorphic.
      # `index: false` because the polymorphic index is declared explicitly below
      # (index_moderate_reports_on_reportable); otherwise `t.references` auto-creates
      # a second index on the same columns and the migration fails with
      # "index ... already exists". (Kept in sync with the generator template.)
      t.references :reportable, polymorphic: true, type: foreign_key_type, null: true, index: false

      # Which field of the reportable was reported (e.g. "description").
      t.string :reported_field

      # In-app community category vs. DSA legal taxonomy.
      t.string :intake_kind, null: false, default: "community"
      t.string :category, null: false
      t.string :content_type
      t.string :legal_reason
      t.string :legal_country_code

      # The reporter's substantiated reason.
      t.text :message, null: false
      t.boolean :anonymous, null: false, default: false
      t.boolean :good_faith_confirmed, null: false, default: false

      # DSA public-notice notifier identity (when not an authenticated user).
      t.string :notifier_name
      t.string :notifier_email
      t.string :reported_account_identifier
      t.string :subject_url
      t.send(json_column_type, :subject_urls, null: false, default: json_array_default)

      # Immutable evidence snapshot + automated-processing metadata.
      t.send(json_column_type, :snapshot, null: false, default: json_column_default)
      t.send(json_column_type, :automated_processing, null: false, default: json_column_default)

      # Lifecycle + decision.
      t.string :status, null: false, default: "open"
      t.datetime :acknowledged_at
      t.references :resolved_by, type: foreign_key_type, null: true
      t.datetime :resolved_at
      t.string :resolution_basis
      t.text :resolution_note
      t.send(json_column_type, :resolution_actions, null: false, default: json_column_default)

      # Statement-of-reasons / appeal window (DSA Art. 17 & 20).
      t.string :decision_visibility
      t.datetime :decision_notified_at
      t.datetime :affected_user_notified_at
      t.datetime :appeal_deadline_at

      t.timestamps
    end

    add_index :moderate_reports, [:reportable_type, :reportable_id], name: "index_moderate_reports_on_reportable"
    add_index :moderate_reports, [:reported_user_id, :status], name: "index_moderate_reports_on_reported_user_id_and_status"
    add_index :moderate_reports, [:reporter_id, :created_at], name: "index_moderate_reports_on_reporter_id_and_created_at"
    add_index :moderate_reports, [:status, :created_at], name: "index_moderate_reports_on_status_and_created_at"
    add_index :moderate_reports, [:intake_kind, :created_at], name: "index_moderate_reports_on_intake_kind_and_created_at"
    add_index :moderate_reports, [:legal_reason, :created_at], name: "index_moderate_reports_on_legal_reason_and_created_at"
    add_index :moderate_reports, :notifier_email, name: "index_moderate_reports_on_notifier_email"
    add_index :moderate_reports, :resolved_at, name: "index_moderate_reports_on_resolved_at"
    add_index :moderate_reports, :appeal_deadline_at, name: "index_moderate_reports_on_appeal_deadline_at"

    add_check_constraint :moderate_reports,
      in_list("intake_kind", %w[community dsa]),
      name: "moderate_reports_intake_kind_check"
    add_check_constraint :moderate_reports,
      in_list("status", %w[open actioned dismissed]),
      name: "moderate_reports_status_check"
    add_check_constraint :moderate_reports,
      in_list("category", %w[
        harassment hate threats sexual_content spam fraud unsafe_behavior
        illegal_content privacy child_safety other hate_abuse_harassment
        violent_speech graphic_violent_media illegal_regulated_behaviors
        impersonation adult_sexual_content private_non_consensual_content
        suicide_self_harm terrorism_violent_extremism scam_fraud
      ]),
      name: "moderate_reports_category_check"
    add_check_constraint :moderate_reports,
      nullable_in_list("content_type", %w[
        user_profile profile_avatar listing message conversation group other
      ]),
      name: "moderate_reports_content_type_check"
    add_check_constraint :moderate_reports,
      nullable_in_list("legal_reason", %w[
        animal_welfare consumer_information cyber_violence data_protection_privacy
        illegal_or_harmful_speech civic_elections non_consensual_behavior
        pornography_sexualized_content protection_of_minors public_security
        scams_fraud scope_of_platform_service self_harm unsafe_illegal_products
        violence intellectual_property other
      ]),
      name: "moderate_reports_legal_reason_check"
    add_check_constraint :moderate_reports,
      nullable_in_list("legal_country_code", %w[
        AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT
        RO SE SI SK EU
      ]),
      name: "moderate_reports_legal_country_code_check"
    add_check_constraint :moderate_reports,
      nullable_in_list("resolution_basis", %w[
        terms law law_and_terms insufficient_information no_violation
      ]),
      name: "moderate_reports_resolution_basis_check"
    add_check_constraint :moderate_reports,
      "#{char_length_fn}(message) <= 4000",
      name: "moderate_reports_message_length_check"

    # ---------------------------------------------------------------------------
    # moderate_blocks
    #
    # The bidirectional blocker/blocked edge, with a self-block check. This is the
    # single source of truth behind Moderate.blocked_ids_for.
    # ---------------------------------------------------------------------------
    create_table :moderate_blocks, id: primary_key_type do |t|
      t.references :blocker, type: foreign_key_type, null: false
      t.references :blocked, type: foreign_key_type, null: false

      t.timestamps
    end

    add_index :moderate_blocks, [:blocker_id, :blocked_id], unique: true, name: "index_moderate_blocks_on_blocker_id_and_blocked_id"
    add_index :moderate_blocks, :created_at, name: "index_moderate_blocks_on_created_at"

    add_check_constraint :moderate_blocks,
      "blocker_id <> blocked_id",
      name: "moderate_blocks_no_self_block"

    # ---------------------------------------------------------------------------
    # moderate_flags
    #
    # System/auto-filter flags (source: text_filter / image_filter /
    # external_classifier / manual). The queue both human admins and ML consumers
    # read via `pending`.
    # ---------------------------------------------------------------------------
    create_table :moderate_flags, id: primary_key_type do |t|
      # The flagged content (any Moderate::Reportable model), polymorphic.
      t.references :flaggable, polymorphic: true, type: foreign_key_type, null: false
      t.string :field, null: false

      # Who owns the flagged content (a user), inferred from the flaggable.
      t.references :owner, type: foreign_key_type, null: true

      # Where the flag came from, and what it would do (:flag allows, :block rejects).
      t.string :source, null: false
      t.string :mode, null: false, default: "flag"

      # Classifier output.
      t.send(json_column_type, :categories, null: false, default: json_array_default)
      t.send(json_column_type, :scores, null: false, default: json_column_default)
      t.send(json_column_type, :context, null: false, default: json_column_default)
      t.text :excerpt

      # Lifecycle + decision.
      t.string :status, null: false, default: "pending"
      t.references :reviewed_by, type: foreign_key_type, null: true
      t.datetime :reviewed_at
      t.text :resolution_note

      t.timestamps
    end

    add_index :moderate_flags, [:flaggable_type, :flaggable_id, :field], name: "index_moderate_flags_on_target_and_field"
    add_index :moderate_flags, [:owner_id, :status], name: "index_moderate_flags_on_owner_id_and_status"
    add_index :moderate_flags, [:status, :created_at], name: "index_moderate_flags_on_status_and_created_at"

    add_check_constraint :moderate_flags,
      in_list("mode", %w[flag block]),
      name: "moderate_flags_mode_check"
    add_check_constraint :moderate_flags,
      in_list("source", %w[text_filter image_filter external_classifier manual]),
      name: "moderate_flags_source_check"
    add_check_constraint :moderate_flags,
      in_list("status", %w[pending actioned dismissed]),
      name: "moderate_flags_status_check"

    # ---------------------------------------------------------------------------
    # moderate_appeals
    #
    # DSA Art. 20 internal complaints against a decision. Free, electronic, open
    # for at least 6 months, and decided by a human.
    # ---------------------------------------------------------------------------
    create_table :moderate_appeals, id: primary_key_type do |t|
      t.references :report, type: foreign_key_type, null: false, foreign_key: { to_table: :moderate_reports }

      # Who appealed: a user, or a named/emailed notifier for public notices.
      t.references :appellant, type: foreign_key_type, null: true
      t.string :appellant_name
      t.string :appellant_email
      t.string :source, null: false, default: "notifier"

      t.text :reason, null: false
      t.send(json_column_type, :snapshot, null: false, default: json_column_default)

      # Lifecycle + decision.
      t.string :status, null: false, default: "open"
      t.references :resolved_by, type: foreign_key_type, null: true
      t.datetime :resolved_at
      t.text :resolution_note
      t.datetime :decision_notified_at

      t.timestamps
    end

    add_index :moderate_appeals, [:report_id, :created_at], name: "index_moderate_appeals_on_report_id_and_created_at"
    add_index :moderate_appeals, [:status, :created_at], name: "index_moderate_appeals_on_status_and_created_at"
    add_index :moderate_appeals, :appellant_email, name: "index_moderate_appeals_on_appellant_email"

    add_check_constraint :moderate_appeals,
      in_list("source", %w[notifier affected_user admin other]),
      name: "moderate_appeals_source_check"
    add_check_constraint :moderate_appeals,
      in_list("status", %w[open upheld rejected]),
      name: "moderate_appeals_status_check"
  end

  private

  def primary_and_foreign_key_types
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    primary_key_type = setting || :primary_key
    foreign_key_type = setting || :bigint
    [primary_key_type, foreign_key_type]
  end

  def json_column_type
    return :jsonb if connection.adapter_name.downcase.include?("postgresql")

    :json
  end

  # MySQL 8+ doesn't allow default values on JSON columns.
  # Returns an empty-hash default for SQLite/PostgreSQL, nil for MySQL.
  # Models handle nil metadata gracefully by defaulting to {} in their accessors.
  def json_column_default
    return nil if connection.adapter_name.downcase.include?("mysql")

    {}
  end

  # Same MySQL caveat as `json_column_default`, but for list-shaped columns,
  # which default to an empty array on SQLite/PostgreSQL.
  def json_array_default
    return nil if connection.adapter_name.downcase.include?("mysql")

    []
  end

  # SQLite has no `char_length`; its `length(text)` already counts characters.
  # PostgreSQL & MySQL 8+ provide `char_length` (true char count). Kept in sync with
  # the generator template so the message-length cap is a real char cap everywhere.
  def char_length_fn
    connection.adapter_name.downcase.include?("sqlite") ? "length" : "char_length"
  end

  # Builds a portable `column IN ('a', 'b', ...)` check-constraint expression that
  # works across PostgreSQL, MySQL 8+, and SQLite (no Postgres-specific casts).
  def in_list(column, values)
    list = values.map { |value| connection.quote(value) }.join(", ")
    "#{column} IN (#{list})"
  end

  # Like `in_list`, but allows NULL (for optional columns).
  def nullable_in_list(column, values)
    "#{column} IS NULL OR #{in_list(column, values)}"
  end
end
