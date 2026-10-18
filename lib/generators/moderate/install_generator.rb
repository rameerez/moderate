# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Moderate
  module Generators
    # `rails generate moderate:install`: the adaptive migration and the initializer.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Install moderate migrations and initializer"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_moderate_tables.rb.erb", File.join(db_migrate_path, "create_moderate_tables.rb")
      end

      # The gem's own migrations (db/migrate: what changed since the tables above were
      # first shipped), copied AFTER create_moderate_tables and in their order, the way
      # `bin/rails moderate:install:migrations` copies them: "<number>_<name>.moderate.rb".
      # An app holding copies runs those, and the engine then leaves the gem's
      # db/migrate out of its paths (see the "moderate.migrations" initializer), so no
      # migration is ever found twice. One already in the app, by name, is skipped.
      def copy_gem_migrations
        dir = File.expand_path(db_migrate_path, destination_root)
        Dir[Moderate::Engine.root.join("db/migrate/[0-9]*_*.rb").to_s].each do |source|
          version, name = File.basename(source, ".rb").split("_", 2)
          next if Dir.glob(File.join(dir, "[0-9]*_#{name}{,.*}.rb")).any?

          number = self.class.next_migration_number(dir)
          create_file File.join(db_migrate_path, "#{number}_#{name}.moderate.rb"), copied_migration(source, version)
        end
      end

      def create_initializer
        template "initializer.rb", "config/initializers/moderate.rb"
      end

      def display_post_install_message
        say "\n🛡️  The `moderate` gem has been installed.", :green
        say "\nTo complete the setup:"

        say "  1. Run 'rails db:migrate' to create the moderation tables."
        say "     ⚠️  You must run migrations before starting your app!", :yellow

        say "  2. Tell `moderate` who your users are in config/initializers/moderate.rb:"
        say "       config.user_class = \"User\""

        say "  3. Add the mixins to your models:"
        say "       class User < ApplicationRecord"
        say "         include Moderate::Actor       # can report, block, and be blocked"
        say "       end"
        say ""
        say "       class Message < ApplicationRecord"
        say "         include Moderate::Reportable  # can be reported"
        say "         moderates :body               # and filtered before save"
        say "       end"

        say "\nYou now have reporting, blocking, filtering, and a moderation queue. 🚀\n", :green
      end

      private

      # As Rails' engine copy writes it: magic comments first, then where it came from.
      def copied_migration(source, version)
        body = File.read(source)
        magic = body[/\A(?:#.*\b(?:coding|frozen_string_literal):.*\n)+/].to_s
        "#{magic}# This migration comes from moderate (originally #{version})\n#{body.delete_prefix(magic)}"
      end

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
