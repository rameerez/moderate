# frozen_string_literal: true

require "test_helper"

module Moderate
  # Moderate.taxonomy_label and Report.category_options: the human names of the
  # gem's value lists, shipped in English and Spanish, overridable by the host.
  class TaxonomyLabelTest < ActiveSupport::TestCase
    # Every value the gem itself defines, by the kind that labels it.
    GEM_VALUES = {
      category: Moderate::Report::DEFAULT_CATEGORIES,
      legal_reason: Moderate::Report::DSA_LEGAL_REASONS,
      member_state: Moderate::Report::EU_COUNTRY_CODES,
      content_type: Moderate::Report::CONTENT_TYPES,
      resolution_basis: Moderate::Report::RESOLUTION_BASES,
      decision: %w[no_restriction no_action content_removed account_suspended other_restriction],
      intake_kind: Moderate::Report::INTAKE_KINDS,
      report_status: Moderate::Report::STATUSES,
      flag_status: Moderate::Flag::STATUSES,
      appeal_status: Moderate::Appeal::STATUSES,
      flag_source: Moderate::Flag::SOURCES + %w[wordlist],
      flag_mode: Moderate::Flag::MODES,
      appeal_source: Moderate::Appeal::SOURCES
    }.freeze

    test "every value the gem defines has an English and a Spanish label" do
      assert_equal Moderate::TAXONOMY_LABEL_SCOPES.keys.sort, GEM_VALUES.keys.sort,
        "a new kind needs its values listed here"

      %i[en es].each do |locale|
        GEM_VALUES.each do |kind, values|
          scope = Moderate::TAXONOMY_LABEL_SCOPES.fetch(kind)
          values.each do |value|
            assert I18n.exists?("moderate.#{scope}.#{value}", locale), "missing #{locale}: moderate.#{scope}.#{value}"
          end
        end
      end
    end

    test "labels read in the current locale" do
      assert_equal "Harassment", Moderate.taxonomy_label(:category, "harassment")
      assert_equal "Scams and fraud", Moderate.taxonomy_label(:legal_reason, :scams_fraud)
      assert_equal "Awaiting review", Moderate.taxonomy_label(:flag_status, "pending")
      assert_equal "Open", Moderate.taxonomy_label(:report_status, "open")

      I18n.with_locale(:es) do
        assert_equal "Acoso", Moderate.taxonomy_label(:category, "harassment")
        assert_equal "España", Moderate.taxonomy_label(:member_state, "ES")
        assert_equal "Desestimado", Moderate.taxonomy_label(:appeal_status, "rejected")
      end
    end

    test "a value the gem doesn't know is humanized, and a country code stays a code" do
      assert_equal "My custom label", Moderate.taxonomy_label(:category, "my_custom_label")
      assert_equal "Openai", Moderate.taxonomy_label(:flag_source, "openai")
      assert_equal "Hate threatening", Moderate.taxonomy_label(:category, "hate/threatening")
      assert_equal "XX", Moderate.taxonomy_label(:member_state, "XX")
    end

    test "blank in, nil out; an unknown kind raises" do
      assert_nil Moderate.taxonomy_label(:category, nil)
      assert_nil Moderate.taxonomy_label(:category, " ")

      error = assert_raises(ArgumentError) { Moderate.taxonomy_label(:categroy, "spam") }
      assert_match(/unknown taxonomy :categroy/, error.message)
    end

    test "a host translation wins over the gem's" do
      assert_equal "Junk", Moderate.taxonomy_label(:category, "spam")
    end

    test "category_options pairs labels with values and honors config.report_categories" do
      assert_equal Moderate::Report::DEFAULT_CATEGORIES, Moderate::Report.category_options.map(&:last)
      assert_includes Moderate::Report.category_options, %w[Harassment harassment]

      Moderate.config.report_categories = %w[spam cheating]
      assert_equal [%w[Junk spam], %w[Cheating cheating]], Moderate::Report.category_options
      I18n.with_locale(:es) { assert_equal %w[Spam spam], Moderate::Report.category_options.first }
    end
  end
end
