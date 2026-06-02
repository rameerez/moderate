# frozen_string_literal: true

require "rails/generators/base"

module Moderate
  module Generators
    # `rails generate moderate:views` — eject the engine's overridable templates
    # into the HOST app so they can be restyled. This is the Devise move
    # (`rails g devise:views`), and it works for the same boring Rails reason:
    # the host app's `app/views` sits AHEAD of any engine's view paths in the
    # lookup chain, so a file copied to `app/views/moderate/notices/new.html.erb`
    # SHADOWS the gem's bundled default automatically — no config, no registration.
    # Delete your copy and the gem's default comes back. Upgrade the gem and your
    # ejected copies are untouched (re-run only if you WANT the new defaults).
    #
    # `source_root` points at the engine's own `app/views`, so `copy_file` /
    # `directory` read the exact templates the engine renders.
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../app/views", __dir__)

      desc "Copy moderate's overridable notice-form views into your app so you can restyle them."

      # Which groups to eject. Default copies the notice views and the engine layout
      # (the full set). `--views form` copies just the field partial — the part a
      # host most often wants to restyle — and `--views form layout` adds the layout.
      class_option :views,
        type: :array,
        default: %w[notices layout],
        desc: "Which view groups to copy (notices, form, layout)"

      def copy_views
        # The whole notices directory (new/show + any partials that ship with it).
        directory "moderate/notices", "app/views/moderate/notices" if include?("notices")

        # Just the field partial, for the "I only want to restyle the fields" path.
        # Guarded by File.exist? so the generator doesn't fail if the partial isn't
        # part of the shipped set in a given version.
        if include?("form") && !include?("notices")
          partial = "moderate/notices/_form.html.erb"
          copy_file partial, "app/views/#{partial}" if engine_view_exists?(partial)
        end

        # The engine layout (only if one ships under layouts/moderate).
        if include?("layout")
          directory "layouts/moderate", "app/views/layouts/moderate" if engine_view_exists?("layouts/moderate")
        end
      end

      private

      # True when the user asked for a given view group (case-insensitive).
      def include?(group)
        options[:views].map(&:to_s).include?(group)
      end

      # Whether a given path exists under the engine's view source_root, so we only
      # try to copy templates that actually ship in this version.
      def engine_view_exists?(relative_path)
        File.exist?(File.join(self.class.source_root, relative_path))
      end
    end
  end
end
