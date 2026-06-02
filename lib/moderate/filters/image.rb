# frozen_string_literal: true

module Moderate
  module Filters    # The default, built-in IMAGE adapter. Registered by the spine under the name
    # :image (config seed "Moderate::Adapters::Image", aliased at the bottom of this
    # file).
    #
    # ── Why a "route everything to human review" default ──────────────────────────
    # Apple Guideline 1.2 and Google Play's UGC policy require a method for filtering
    # objectionable media before it's posted, not just text
    # (https://developer.apple.com/app-store/review/guidelines/#user-generated-content,
    # https://support.google.com/googleplay/android-developer/answer/9876937). But the
    # gem can't ship a real NSFW/CSAM image CLASSIFIER offline — that needs a model or
    # a hosted service. So the safe, honest default is: don't PRETEND to evaluate the
    # pixels; instead FLAG every uploaded image so a human sees it in the moderation
    # queue (Moderate::Flag.pending). That clears the store bar (there IS a review
    # path) without making a false claim that the bundled gem inspects image content.
    #
    # A host that wants automated image moderation swaps this out in one line — point
    # the field at the multimodal :openai adapter (which DOES inspect pixels), or
    # register their own SafeSearch / Rekognition / Hive backend:
    #     config.filter "Profile", :avatar, with: :openai, mode: :flag
    #     config.register_adapter :rekognition, MyRekognitionAdapter.new
    #
    # ── Asynchronous, :flag-only ─────────────────────────────────────────────────
    # `async? == true`, mirroring the documented behavior ("the :image adapter runs
    # async in :flag mode"). A real image backend does network I/O, so the contract
    # is async from day one; that also means the spine's validate! correctly REFUSES
    # to let :image be used in :block mode — you don't reject a save synchronously on
    # image review, you let the write succeed and queue the image for a look.
    class Image < Base
      def self.async?
        true
      end

      # We don't (and can't, offline) read the image. Every image is flagged for a
      # human to look at. We don't invent a category score — there's no probability,
      # this is "a person needs to check this", so it's the bare `sexual` top-level
      # canonical category at score 1.0 used as a conservative "needs review" signal,
      # with input :image so the queue shows it came from media, plus a context note
      # in `raw` recording that this is a human-review placeholder rather than a model
      # verdict. (A real backend returns true per-category scores instead.)
      def classify(_value)
        label = Moderate::Label.new(
          category: :sexual, subcategory: nil,
          score: 1.0, flagged: true, input: :image
        )

        flagged_result(
          labels: [label],
          raw: { human_review_required: true, deterministic: true,
                 note: "default image adapter flags all images for human review" }
        )
      end

      private

      # Image flags record source "image_filter" — one of the four values allowed by
      # the migration's `moderate_flags_source_check` constraint.
      def source_name
        "image_filter"
      end
    end
  end

  # Registry alias — see the note in wordlist.rb. The spine seeds the registry with
  # the STRING "Moderate::Adapters::Image"; this makes that string constantize to the
  # class defined here under `Moderate::Filters` (which is where its file path lives,
  # so Zeitwerk is satisfied).
  module Adapters; end
  Adapters::Image = Filters::Image
end
