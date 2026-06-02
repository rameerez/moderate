# frozen_string_literal: true

# A tiny BRING-YOUR-OWN image adapter for the dummy host's test suite.
#
# `moderate` ships exactly ONE built-in adapter, the offline text `:wordlist`. Image
# moderation is bring-your-own (the gem deliberately bundles no NSFW/CSAM model and
# no network dependency — see examples/aws_rekognition_adapter.rb for a real one).
# The suite still needs to exercise the image-field filtering SEAM (the after-commit
# :flag path on an Active Storage attachment), so the dummy host registers this
# trivial stand-in under the name `:image` (a host may name its own adapter anything;
# the Comment model points `moderates :image, with: :image` at it).
#
# Behavior mirrors what an async image classifier looks like to the gem:
#   * It is ASYNC (`synchronous? == false`), so the spine routes it through
#     Moderate::ClassifyJob and the Configuration's validate! REFUSES it in :block
#     mode — :flag is the only valid mode, exactly like a real remote image API.
#   * It flags ANY present image for human review (it ignores the bytes — this is a
#     deterministic test double, not a real classifier), producing one Moderate::Flag
#     on the (record, field) after commit.
#   * `source` is "image_filter" — one of the four values the install migration's
#     moderate_flags_source_check constraint allows for a flag from an image backend.
#
# Host-agnostic on purpose: no domain concepts, just "an image was uploaded, queue it
# for review".
class DummyImageAdapter
  # The single adapter contract: classify(value) -> Moderate::Result. `value` is
  # whatever the Comment model's filtering seam hands us for the :image field (the
  # Active Storage attachment). A blank/absent attachment can't violate anything, so
  # we allow it; any present attachment is flagged for human review with score 1.0
  # (a "needs a human" signal, not a probability).
  def classify(value)
    return Moderate::Result.allowed(source: "image_filter") if value.blank?

    label = Moderate::Label.new(
      category: :sexual, # the conservative "needs review" bucket for an unclassified image
      subcategory: nil,
      score: 1.0,
      flagged: true,
      input: :image
    )
    Moderate::Result.new(allowed: false, labels: [label], source: "image_filter")
  end

  # Async: returning false is what makes the spine forbid :block mode and run this
  # through Moderate::ClassifyJob in :flag mode — the documented invariant ("`:block`
  # requires a synchronous adapter"). An adapter need not inherit from
  # Moderate::Filters::Base; answering this one predicate is enough.
  def synchronous?
    false
  end
end
