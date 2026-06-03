# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Moderate
  module Generators
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

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
