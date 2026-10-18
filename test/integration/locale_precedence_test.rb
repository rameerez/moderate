# frozen_string_literal: true

require "test_helper"

# The gem ships default copy in config/locales; the host must always be able to
# override it from its own config/locales. Rails guarantees that for an engine's
# locale files (they're loaded before the app's) — but only if the engine does
# NOT also append them to `config.i18n.load_path`, which is loaded AFTER the app
# and would make the gem's defaults silently clobber the host's translations.
class LocalePrecedenceTest < ActiveSupport::TestCase
  GEM_EN = File.expand_path("../../config/locales/en.yml", __dir__)
  HOST_EN = File.expand_path("../dummy/config/locales/en.yml", __dir__)

  test "the gem's locale files load once, before the host app's" do
    paths = I18n.load_path.map(&:to_s)

    assert_equal 1, paths.count(GEM_EN), "the gem's en.yml must be on the load path exactly once"
    assert_operator paths.index(GEM_EN), :<, paths.index(HOST_EN)
  end

  test "a host translation overrides the gem's shipped default" do
    assert_equal "Profile picture", I18n.t("moderate.reportable_fields.avatar")
    assert_equal "Profile picture", Moderate.reportable_field_label("Profile", :avatar)
  end

  test "keys the host doesn't override keep the gem's default" do
    assert_equal "Text", I18n.t("moderate.reportable_fields.body")
    I18n.with_locale(:es) { assert_equal "Foto de perfil", I18n.t("moderate.reportable_fields.avatar") }
  end
end
