# frozen_string_literal: true

require "test_helper"
require "generators/moderate/install_generator"

module Moderate
  # The migrations of a fresh install: the generator writes create_moderate_tables, then
  # copies the gem's own migrations after it, in order, so AddPendingKeyToModerateFlags
  # is the one migration that creates pending_key in a fresh app as in an upgraded one,
  # and rolling it back leaves the install migration's schema intact.
  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Moderate::Generators::InstallGenerator
    destination Rails.root.join("tmp/generators")
    setup :prepare_destination
    self.use_transactional_tests = false # one test migrates a database of its own

    # Where the generated migrations are evaluated, away from the gem's own classes.
    module FreshInstall; end

    GEM_MIGRATION = Moderate::Engine.root.join("db/migrate/20261018200000_add_pending_key_to_moderate_flags.rb")
    # Every migration the gem ships, in order: a fresh install copies them all.
    GEM_MIGRATION_NAMES = Dir[Moderate::Engine.root.join("db/migrate/[0-9]*_*.rb").to_s].map do |file|
      File.basename(file, ".rb").split("_", 2).last.camelize
    end

    test "a fresh install gets create_moderate_tables, then the gem's migrations, copied in order" do
      run_generator

      create, upgrade, *later = migrations
      assert_equal GEM_MIGRATION_NAMES.size - 1, later.size, "every gem migration is copied"
      assert_match(/\A\d{14}_create_moderate_tables\.rb\z/, File.basename(create))
      assert_match(/\A\d{14}_add_pending_key_to_moderate_flags\.moderate\.rb\z/, File.basename(upgrade))
      assert_operator File.basename(create).to_i, :<, File.basename(upgrade).to_i, "runs after the tables exist"

      code = File.read(create).lines.grep_v(/\A\s*#/).join
      assert_no_match(/pending_key/, code, "the template leaves pending_key to the gem")
      assert_no_match(/redacted_at|held_until|covered_by_report_id|moderate_classifications/, code, "and the 1.0 columns and table")
      # As `bin/rails moderate:install:migrations` writes it: the magic comment and its
      # blank line, then where it came from, then the migration.
      header = "# frozen_string_literal: true\n\n# This migration comes from moderate (originally 20261018200000)\n"
      gem_migration = File.read(GEM_MIGRATION).delete_prefix("# frozen_string_literal: true\n\n")
      assert_equal header + gem_migration, File.read(upgrade)
    end

    test "run again, it copies nothing twice" do
      run_generator
      run_generator

      assert_equal 1 + GEM_MIGRATION_NAMES.size, migrations.size
    end

    # What `bin/rails db:migrate` finds: the app's own db/migrate plus what the engine
    # adds to it (Moderate::Engine.migration_paths_for).
    test "delivery: a fresh install runs its copies, in order, and nothing from the gem's path" do
      run_generator
      host = File.join(destination_root, "db/migrate")

      assert_empty Moderate::Engine.migration_paths_for([host])
      assert_equal ["CreateModerateTables", *GEM_MIGRATION_NAMES], migration_names([host])
    end

    test "delivery: an app installed before the copies (beta3) gets the gem's path: only what it lacks" do
      Dir.mktmpdir do |host|
        File.write(File.join(host, "20250101000000_create_moderate_tables.rb"), "")

        paths = [host] + Moderate::Engine.migration_paths_for([host])
        assert_equal [Moderate::Engine.root.join("db/migrate").to_s], paths.drop(1)
        assert_equal ["CreateModerateTables", *GEM_MIGRATION_NAMES], migration_names(paths)
      end
    end

    test "a fresh install migrates to pending_key; rolling the gem's migration back leaves the install's schema" do
      run_generator
      create, upgrade, = migrations

      with_fresh_database do
        [create, upgrade].each { |file| FreshInstall.module_eval(File.read(file), file) }
        install = FreshInstall::CreateModerateTables.new.tap { |m| m.verbose = false }
        pending_key = FreshInstall::AddPendingKeyToModerateFlags.new.tap { |m| m.verbose = false }

        install.migrate(:up)
        installed = schema_of(:moderate_flags)
        pending_key.migrate(:up)

        assert connection.column_exists?(:moderate_flags, :pending_key)
        assert connection.index_exists?(:moderate_flags, :pending_key, unique: true,
          name: "index_moderate_flags_on_pending_key")

        pending_key.migrate(:down)
        assert_equal installed, schema_of(:moderate_flags)
        %i[moderate_reports moderate_blocks moderate_flags moderate_appeals].each do |table|
          assert connection.table_exists?(table), "#{table} still there"
        end
      end
    end

    test "a fresh install migrates to the 1.0 columns and table; rolling that migration back leaves the rest" do
      run_generator
      files = migrations

      with_fresh_database do
        files.each { |file| FreshInstall.module_eval(File.read(file), file) }
        install, pending_key, retention = %w[CreateModerateTables AddPendingKeyToModerateFlags
                                             AddRetentionAndClassificationsToModerateTables].map do |name|
          FreshInstall.const_get(name).new.tap { |m| m.verbose = false }
        end
        install.migrate(:up)
        pending_key.migrate(:up)
        before = %i[moderate_reports moderate_flags moderate_appeals].to_h { |table| [table, schema_of(table)] }

        retention.migrate(:up)
        assert connection.column_exists?(:moderate_reports, :held_until)
        assert connection.table_exists?(:moderate_classifications)

        retention.migrate(:down)
        assert_not connection.table_exists?(:moderate_classifications)
        before.each { |table, schema| assert_equal schema, schema_of(table), table }
      end
    end

    private

    def migrations
      Dir[File.join(destination_root, "db/migrate/*.rb")]
    end

    def connection = ActiveRecord::Base.connection

    def migration_names(paths)
      ActiveRecord::MigrationContext.new(paths).migrations.map(&:name)
    end

    # A new, empty SQLite database for the block, as a fresh app's; then the suite's own.
    def with_fresh_database
      original = ActiveRecord::Base.connection_db_config
      Dir.mktmpdir do |dir|
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(dir, "fresh.sqlite3"))
        yield
      ensure
        ActiveRecord::Base.establish_connection(original)
      end
    end

    def schema_of(table)
      {
        columns: connection.columns(table).map { |c| [c.name, c.sql_type, c.null, c.default] },
        indexes: connection.indexes(table).map { |i| [i.name, i.columns, i.unique] }.sort,
        checks: connection.check_constraints(table).map { |c| [c.name, c.expression] }.sort
      }
    end
  end
end
