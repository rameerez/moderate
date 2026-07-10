# frozen_string_literal: true

# The dummy host's CONTENT model — a piece of user-generated content that can be
# reported and whose text is filtered before save.
#
#   reportable :body  : only `:body` is a reportable field (the field whitelist).
#   moderates :body   : filter `:body` pre-publication. The dummy initializer pairs
#                       Comment#body with the :wordlist adapter in :block mode, so an
#                       objectionable body is rejected synchronously with a
#                       validation error (errors.add(:body, :objectionable_content)).
class Comment < ApplicationRecord
  has_reportable_content :body
  moderates :body

  # Every comment belongs to a user; that user is who a decision notifies and a ban
  # would apply to. Reportable has NO default #reported_owner (guessing wrong means
  # notifying/banning the wrong person), so a reportable model MUST define it.
  belongs_to :user

  # An optional image attachment, present so the image-field filtering tests have a
  # real Active Storage attachment to exercise a bring-your-own IMAGE adapter. The gem
  # ships only the offline text :wordlist; this host registers its own async image
  # adapter under the name :image (test/dummy/app/adapters/dummy_image_adapter.rb,
  # wired in config/initializers/moderate.rb), which flags every uploaded image for
  # human review. We declare the field as moderated and point it at that :image
  # adapter in :flag mode — it's async, so :block would be a config error; :flag lets
  # the save through and files a Moderate::Flag after commit.
  has_one_attached :image
  moderates :image, with: :image, mode: :flag

  # A SECOND attachment with NO seam overrides (the overrides below are scoped
  # to :image), so the suite exercises the concern's NATIVE Active Storage
  # support: the before_save attachment snapshot + attachment-aware blank check
  # mean `moderates <attachment>` needs zero extra wiring on the host.
  has_one_attached :photo
  moderates :photo, with: :image, mode: :flag

  # WHO is responsible for this content — required by Moderate::Reportable.
  def reported_owner
    user
  end

  # A queue-friendly label so the moderation queue and flag/report labels read
  # nicely instead of "#<Comment id: 1>".
  def moderation_label
    "Comment ##{id}"
  end

  # Immutable evidence snapshot for the reported field, captured at report time so
  # the report survives the comment being edited/deleted (DSA Art. 17 evidence).
  def moderation_snapshot(field)
    public_send(field) if field.to_s == "body"
  end

  # --- Attachment filtering seam --------------------------------------------
  #
  # ContentFilterable filters plain text columns out of the box; for the `:image`
  # attachment we override the three seam methods so the SAME concern can run the
  # image adapter against the attachment without the gem knowing about Active Storage.

  # The value handed to the adapter for `:image` is the attachment itself (the
  # registered :image adapter ignores the bytes and flags any present image for human
  # review); for `:body` it's the plain column value.
  def moderation_field_value(field)
    return image if field.to_s == "image"

    super
  end

  # ActiveRecord dirty tracking doesn't see an attachment change, so we report the
  # image as "changed for this commit" whenever one is attached. (A production host
  # would track a one-shot "image was replaced" flag and clear it in
  # moderation_field_committed; for the dummy, "present ⇒ consider it changed" is
  # enough to exercise the after_commit :flag path.)
  def moderation_field_changed_for_commit?(field)
    return image.attached? if field.to_s == "image"

    super
  end
end
