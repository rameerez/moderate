# frozen_string_literal: true

# A second host model on the comments table whose `photo` attachment is declared
# ABOVE its first `moderates` call — the opposite order to Comment — so Active
# Storage's upload callback runs before the filter's; its `photos` (many) come
# after it, so the filter's runs first there. test/integration/attachment_upload_test.rb
# checks that every order classifies an attachment exactly once, after its upload.
class PhotoPost < ApplicationRecord
  self.table_name = "comments"

  belongs_to :user

  has_one_attached :photo
  moderates :photo, with: :image, mode: :flag

  has_many_attached :photos
  moderates :photos, with: :image, mode: :flag

  def reported_owner
    user
  end
end
