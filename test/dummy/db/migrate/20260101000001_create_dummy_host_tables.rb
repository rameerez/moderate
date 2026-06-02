# frozen_string_literal: true

# The dummy HOST's own tables — the User (actor) and Comment (content) models the
# gem's macros are applied to. These are NOT part of the gem; they stand in for
# whatever a real host app already has. Kept deliberately tiny: just the columns
# the suite reads (name, email, display_name on User; body + user_id on Comment).
class CreateDummyHostTables < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      # `name` is User's single reportable field (User#reportable :name) and the
      # :flag-moderated field (config.filter "User", :name). `email`/`display_name`
      # are read by Moderate::Report#hydrate_reporter_contact via `try`.
      t.string :name
      t.string :email
      t.string :display_name

      t.timestamps
    end

    create_table :comments do |t|
      # `body` is Comment's reportable + :block-moderated field. `user_id` backs
      # Comment#reported_owner (who a decision notifies / a ban applies to).
      t.references :user, null: false, foreign_key: true
      t.text :body

      t.timestamps
    end
  end
end
