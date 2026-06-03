# frozen_string_literal: true

# ──────────────────────────────────────────────────────────────────────────────
# REFERENCE ADAPTER — NOT shipped, NOT loaded, NOT a dependency of `moderate`.
#
# `moderate` ships exactly ONE built-in adapter: the offline `:wordlist` (text).
# It does NOT bundle an image classifier — a real NSFW/CSAM model needs a hosted
# service or a model you can't ship offline. This file is a "bring your own" IMAGE
# adapter: copy it into your app, add the AWS SDK gem to YOUR Gemfile, and register
# it. The gem has no `aws-sdk-rekognition` dependency, so nothing here is pulled
# into a host that doesn't want it.
#
# ── How to use it ─────────────────────────────────────────────────────────────
#   1. Copy this file into your app (e.g. app/adapters/aws_rekognition_adapter.rb).
#   2. Add the runtime dependency to YOUR app's Gemfile:
#          gem "aws-sdk-rekognition"
#      and provide AWS credentials the usual way (ENV / IAM role / shared config).
#   3. Register the adapter and point an image field at it, in :flag mode:
#          Moderate.configure do |config|
#            config.register_adapter(:rekognition, AwsRekognitionAdapter.new)
#            config.filter "Profile", :avatar, with: :rekognition, mode: :flag
#          end
#      Hand the adapter the image BYTES (the value your model's filtering seam
#      passes for the field — e.g. an attachment's `download`), or pass an
#      { s3_object: { bucket:, name: } } hash to moderate an object already in S3.
#
# ── Why :flag, never :block ───────────────────────────────────────────────────
# `synchronous? == false` (below): a Rekognition call is blocking network I/O, so
# `moderate` runs it in `Moderate::ClassifyJob` (:flag mode) and refuses it in
# :block mode — you can't synchronously reject a save on an in-flight API call.
#
# ── Taxonomy mapping ──────────────────────────────────────────────────────────
# Rekognition has its OWN moderation taxonomy (top-level + second-level labels like
# "Explicit Nudity" / "Violence" / "Drugs"), NOT OpenAI's. Every adapter must map
# its provider labels onto the gem's ONE canonical taxonomy (Moderate::Label), so
# Moderate::Flag, the DSA statement of reasons, and the transparency counters all
# speak one vocabulary. CATEGORY_MAP below is that mapping — adjust it to taste.
# AWS DetectModerationLabels API:
#   https://docs.aws.amazon.com/rekognition/latest/APIReference/API_DetectModerationLabels.html
# Moderation label categories:
#   https://docs.aws.amazon.com/rekognition/latest/dg/moderation.html
# ──────────────────────────────────────────────────────────────────────────────
class AwsRekognitionAdapter
  # Only surface labels Rekognition is at least this confident about. Rekognition
  # confidence is 0..100; we also pass MIN_CONFIDENCE to the API so it doesn't even
  # return lower-confidence labels. Tune for your tolerance.
  MIN_CONFIDENCE = 60.0

  # Map Rekognition's top-level moderation categories onto the gem's canonical
  # Moderate::Label taxonomy. Rekognition's top-level names (left) are mapped to a
  # [category, subcategory] canonical pair (right). Unmapped/new Rekognition
  # categories fall back to plain :sexual as a conservative "needs review" bucket —
  # change that default if a different fallback fits your app.
  CATEGORY_MAP = {
    "Explicit Nudity" => [:sexual, nil],
    "Sexual"          => [:sexual, nil],
    "Non-Explicit Nudity of Intimate parts and Kissing" => [:sexual, nil],
    "Violence"        => [:violence, nil],
    "Visually Disturbing" => [:violence, :graphic],
    "Hate Symbols"    => [:hate, nil],
    "Drugs & Tobacco" => [:illicit, nil],
    "Gambling"        => [:illicit, nil]
  }.freeze

  def initialize(client: nil)
    # Lazily build the client so merely requiring this file doesn't construct an AWS
    # client (and doesn't error when the gem/creds are absent). Inject one in tests.
    @client = client
  end

  # classify(value) -> Moderate::Result. `value` is the image to inspect: raw bytes
  # (a String) for DetectModerationLabels' `image: { bytes: ... }`, or an
  # { s3_object: { bucket:, name: } } hash to point at an object already in S3.
  def classify(value)
    response = client.detect_moderation_labels(
      image: image_param(value),
      min_confidence: MIN_CONFIDENCE
    )

    labels = build_labels(response.moderation_labels)
    return Moderate::Result.allowed(source: "image_filter", raw: response.to_h) if labels.empty?

    Moderate::Result.new(
      allowed: false,
      labels: labels,
      # "image_filter" is one of the four values the install migration's
      # moderate_flags_source_check constraint allows. (The human-facing backend
      # name is the adapter NAME, :rekognition, which you register it under.)
      source: "image_filter",
      raw: response.to_h
    )
  rescue => error
    # FAIL OPEN on everything, same rationale as any network classifier: a moderation
    # API is defense-in-depth, not a gatekeeper that should block uploads on an AWS
    # blip. The image simply isn't auto-flagged this time; users can still report it.
    warn("[moderate] Rekognition moderation call failed (failing open): #{error.class}: #{error.message}")
    Moderate::Result.allowed(source: "image_filter", raw: { error: error.class.name, message: error.message })
  end

  # Background-only — see the header. This is what makes the spine route the adapter
  # through ClassifyJob in :flag mode and forbid it in :block mode.
  def synchronous?
    false
  end

  private

  # Build the API's `image` parameter from the host-agnostic value. A Hash is passed
  # through (so { s3_object: {...} } or { bytes: ... } both work); anything else is
  # treated as the raw image bytes.
  def image_param(value)
    return value if value.is_a?(Hash)

    { bytes: value }
  end

  # Rekognition returns a flat list of moderation labels, each with `name`,
  # `parent_name` (the top-level category, blank for a top-level label itself), and
  # `confidence` (0..100). We key the canonical mapping off the TOP-LEVEL category
  # (`parent_name` when present, else `name`) and emit one Moderate::Label per hit,
  # normalizing the 0..100 confidence to the gem's 0..1 score, with input :image.
  def build_labels(moderation_labels)
    Array(moderation_labels).filter_map do |label|
      top_level = label.parent_name.to_s.empty? ? label.name : label.parent_name
      category, subcategory = CATEGORY_MAP.fetch(top_level, [:sexual, nil])

      Moderate::Label.new(
        category: category,
        subcategory: subcategory,
        score: label.confidence.to_f / 100.0, # Rekognition 0..100 -> canonical 0..1
        flagged: true,
        input: :image
      )
    end
  end

  def client
    @client ||= Aws::Rekognition::Client.new
  end
end
