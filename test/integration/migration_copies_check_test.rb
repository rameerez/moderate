# frozen_string_literal: true

require "test_helper"

# An app holding copies of the gem's migrations (*.moderate.rb) runs only those, so a
# copy missed after an upgrade must not be silent: the boot check names it.
class MigrationCopiesCheckTest < ActiveSupport::TestCase
  GEM_MIGRATIONS = Dir[Moderate::Engine.root.join("db/migrate/[0-9]*_*.rb").to_s].map do |file|
    File.basename(file, ".rb").split("_", 2).last
  end

  def with_copies(names)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "20250101000000_create_moderate_tables.rb"), "")
      names.each_with_index do |name, index|
        File.write(File.join(dir, "2026010100000#{index}_#{name}.moderate.rb"), "")
      end
      yield [dir]
    end
  end

  def not_under_rake(&)
    Moderate::Engine.stub(:running_rake_task?, false, &)
  end

  test "an app without copies has nothing to miss (it gets the gem's own path)" do
    with_copies([]) { |dirs| assert_empty Moderate::Engine.missing_migration_copies(dirs) }
  end

  test "an app with every copy passes" do
    with_copies(GEM_MIGRATIONS) do |dirs|
      assert_empty Moderate::Engine.missing_migration_copies(dirs)
      not_under_rake { assert_nil Moderate::Engine.check_migration_copies!(dirs) }
    end
  end

  test "a missing copy raises at boot, naming it and the command" do
    with_copies(GEM_MIGRATIONS.first(1)) do |dirs|
      assert_equal GEM_MIGRATIONS.drop(1), Moderate::Engine.missing_migration_copies(dirs)

      error = not_under_rake do
        assert_raises(Moderate::ConfigurationError) { Moderate::Engine.check_migration_copies!(dirs) }
      end
      GEM_MIGRATIONS.drop(1).each { |name| assert_includes error.message, name }
      assert_includes error.message, "bin/rails moderate:install:migrations"
    end
  end

  test ":log logs instead of raising, :off says nothing, and a rake task only logs" do
    with_copies(GEM_MIGRATIONS.first(1)) do |dirs|
      _, err = capture_io { not_under_rake { Moderate::Engine.check_migration_copies!(dirs, mode: :log) } }
      assert_includes err, "moderate:install:migrations"

      _, err = capture_io { not_under_rake { Moderate::Engine.check_migration_copies!(dirs, mode: :off) } }
      assert_empty err

      _, err = capture_io do
        Moderate::Engine.stub(:running_rake_task?, true) { Moderate::Engine.check_migration_copies!(dirs, mode: :raise) }
      end
      assert_includes err, "moderate:install:migrations", "the fix itself is a rake task: it must still run"
    end
  end

  test "migration_copies_check accepts raise, log or off" do
    Moderate.config.migration_copies_check = "log"
    assert_equal :log, Moderate.config.migration_copies_check
    assert_raises(ArgumentError) { Moderate.config.migration_copies_check = :sometimes }
  end
end
