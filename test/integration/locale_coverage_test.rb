# frozen_string_literal: true

require "test_helper"

# Every refusal, validation message (`moderate.errors.*`) and controller-concern flash
# (`moderate.moderation.*`) the gem can show has English and Spanish copy in the
# gem's locale files, not only an inline English default.
class LocaleCoverageTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  def used_keys
    keys = Dir[File.join(ROOT, "{app,lib}", "**", "*.{rb,erb}")].flat_map do |file|
      File.read(file).scan(/"(moderate\.(?:errors|moderation)\.[a-z_]+)"/).flatten
    end
    flash = File.read(File.join(ROOT, "app/controllers/concerns/moderate/moderation.rb"))[/defaults = \{(.*?)\}/m, 1]
    keys + flash.scan(/(\w+):/).flatten.map { |key| "moderate.moderation.#{key}" }
  end

  %w[en es].each do |locale|
    test "#{locale} has copy for every moderate.errors and moderate.moderation key" do
      shipped = YAML.load_file(File.join(ROOT, "config/locales/#{locale}.yml"))[locale]
      missing = used_keys.uniq.reject { |key| shipped.dig(*key.split(".")).is_a?(String) }

      assert_empty missing.sort
    end
  end

  test "a refusal and a flash read in Spanish" do
    I18n.with_locale(:es) do
      assert_equal "Denuncia gestionada.", I18n.t("moderate.moderation.resolved")
      assert_equal "No se ha retirado nada: Comentario 1 no tiene nada que retirar (ya retirado, eliminado o no retirable). " \
                   "Resuelve sin retirar contenido, o descarta la denuncia.",
        I18n.t("moderate.errors.nothing_removed", content: "Comentario 1")
    end
  end
end
