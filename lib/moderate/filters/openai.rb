# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Moderate
  module Filters
    # The OpenAI `omni-moderation-latest` adapter — the recommended "real" backend.
    # Free, multimodal (text AND image in one call), and it returns the canonical
    # taxonomy this gem standardized on, so its output maps 1:1 onto Moderate::Label
    # with no lossy translation. Cited throughout to:
    # https://developers.openai.com/api/docs/guides/moderation
    #
    # ── Zero new gem dependencies ────────────────────────────────────────────────
    # We hit the HTTP endpoint with the stdlib `Net::HTTP` rather than pulling in the
    # `openai` gem. The moderation endpoint is one POST with a tiny JSON body; a SDK
    # would be a heavy dependency for a single call, and `moderate` keeps its runtime
    # deps minimal and host-agnostic on purpose (see the gemspec note).
    #
    # ── Asynchronous ─────────────────────────────────────────────────────────────
    # `async? == true`: this adapter does blocking network I/O, so it must NEVER run
    # inline in a request/validation. The spine's Configuration#validate! enforces
    # that a :block-mode filter can't use an async adapter (you can't reject a save on
    # a result that's still in flight). In :flag mode the gem runs it inside
    # Moderate::ClassifyJob and files a Moderate::Flag with the labels.
    #
    # ── Fail OPEN, never block on a network blip ─────────────────────────────────
    # A moderation API is best-effort defense-in-depth, not a gatekeeper that should
    # take down user posting when OpenAI has a hiccup. On ANY error (timeout, non-2xx,
    # malformed body, missing key) we log and return an ALLOWED result. The content
    # simply isn't auto-flagged this time; users can still report it, and a :block
    # field is anyway backed by the synchronous wordlist, not this. Failing closed
    # (rejecting saves on an upstream outage) would be a far worse outage of its own.
    class OpenAI < Base
      ENDPOINT = URI("https://api.openai.com/v1/moderations")

      # omni-moderation-latest is the multimodal model (text + image). The older
      # text-only "text-moderation-*" models don't accept images and don't return
      # `category_applied_input_types`, so we pin the omni model explicitly.
      MODEL = "omni-moderation-latest"

      # Conservative network timeouts. This runs in a background job, but a hung
      # socket shouldn't pin a worker indefinitely — bail and fail open.
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      # This adapter is background-only — see the class header. Flipping this one flag
      # is what makes the spine route it through ClassifyJob and forbid it in :block.
      def self.async?
        true
      end

      def classify(value)
        key = api_key
        # No key configured ⇒ nothing to call. Fail open (allowed) rather than raise,
        # so a half-configured app doesn't break content creation.
        return allowed_result if key.nil? || key.strip.empty?

        body = request_body(value)
        response = post(body, key)
        parse(response, raw_request: body)
      rescue => error
        # Fail open on EVERYTHING (Net::HTTP errors, JSON errors, timeouts, ...).
        log("[moderate] OpenAI moderation call failed (failing open): #{error.class}: #{error.message}")
        allowed_result(raw: { error: error.class.name, message: error.message })
      end

      private

      # External classifiers all record source "external_classifier" — one of the
      # four values the migration's `moderate_flags_source_check` allows. (The
      # human-facing "which backend" detail is the adapter NAME, e.g. :openai, which
      # the spine stamps onto the Result separately.)
      def source_name
        "external_classifier"
      end

      # Build the `input` array OpenAI expects. We accept several host-agnostic shapes
      # so callers don't have to know the wire format:
      #   - a String                        -> one text part (a URL/data-URI String is
      #                                         still treated as text; pass an image
      #                                         explicitly via the hash form below)
      #   - { text:, image_url: }           -> the parts that are present
      #   - { type:, ... } / array thereof  -> passed through (already wire-shaped)
      #   - an Array of any of the above    -> flattened into the parts list
      # Each part is { "type" => "text", "text" => ... } or
      # { "type" => "image_url", "image_url" => { "url" => ... } } per the API docs.
      def request_body(value)
        # NOTE: do NOT use `Array(value)` to normalize the input — Ruby's Kernel#Array
        # turns a Hash into an array of [key, value] PAIRS (`Array({text: "x"})` =>
        # [[:text, "x"]]), which would shatter the `{ text:, image_url: }` convenience
        # shape. Only an actual Array is treated as a list of parts; a Hash/String is a
        # single item.
        items = value.is_a?(Array) ? value : [value]
        parts = items.flat_map { |item| parts_for(item) }.compact
        { model: MODEL, input: parts }
      end

      def parts_for(item)
        case item
        when String
          [text_part(item)]
        when Hash
          hash_parts(item)
        else
          # Anything that can stringify (e.g. an object with #to_s) -> text part.
          [text_part(item.to_s)]
        end
      end

      def hash_parts(hash)
        h = hash.transform_keys(&:to_sym)

        # Already a wire-shaped part? Pass it straight through.
        return [stringify_keys(hash)] if h.key?(:type)

        parts = []
        parts << text_part(h[:text]) if h[:text]
        if (image = h[:image_url] || h[:image] || h[:url])
          parts << image_part(image)
        end
        parts
      end

      def text_part(text)
        { "type" => "text", "text" => text.to_s }
      end

      def image_part(image)
        # Accept a bare URL/data-URI String, or a nested { url: } hash.
        url = image.is_a?(Hash) ? (image[:url] || image["url"]) : image.to_s
        { "type" => "image_url", "image_url" => { "url" => url } }
      end

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end

      def post(body, key)
        http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
        http.use_ssl = true
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        request = Net::HTTP::Post.new(ENDPOINT)
        request["Authorization"] = "Bearer #{key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        http.request(request)
      end

      # Turn the API response into a Moderate::Result. The wire shape (verified
      # against the docs) is, per result:
      #   { "flagged": Bool,
      #     "categories":                   { "<slug>": Bool, ... },   # 13 keys
      #     "category_scores":              { "<slug>": Float, ... },
      #     "category_applied_input_types": { "<slug>": ["text"|"image", ...] } }
      # The slug keys ARE our canonical slugs ("hate", "hate/threatening",
      # "self-harm/intent", "sexual/minors", "illicit/violent", ...) — that's why we
      # adopted OpenAI's taxonomy as the gem's canonical one (Moderate::Label).
      def parse(response, raw_request:)
        unless response.is_a?(Net::HTTPSuccess)
          log("[moderate] OpenAI moderation HTTP #{response&.code} (failing open)")
          return allowed_result(raw: { http_status: response&.code, body: safe_body(response) })
        end

        payload = JSON.parse(response.body)
        # We send one input array = one moderation "item", so we read results[0].
        # (results is an array because the endpoint can batch multiple items.)
        result = Array(payload["results"]).first
        return allowed_result(raw: payload) if result.nil?

        labels = build_labels(result)

        # Trust OpenAI's own top-level `flagged` for the verdict, but only surface
        # the categories it actually flagged as labels (a non-flagged category still
        # carries a score; we don't want every near-zero category in the Flag).
        return allowed_result(raw: payload) unless result["flagged"]

        flagged_result(labels: labels, raw: payload)
      end

      # One Moderate::Label per FLAGGED category, carrying its 0..1 score and which
      # input(s) tripped it. `category_applied_input_types` is a per-category array
      # like ["image"] or ["text","image"]; we emit one label per applied input so a
      # multimodal hit ("violence" from both the caption and the photo) is fully
      # attributed. When a category is flagged but the applied-types array is empty
      # (rare), we record it as input :unknown so the verdict isn't lost.
      def build_labels(result)
        categories = result["categories"] || {}
        scores = result["category_scores"] || {}
        applied = result["category_applied_input_types"] || {}

        categories.each_with_object([]) do |(slug, flagged), labels|
          next unless flagged

          category, subcategory = slug.split("/", 2)
          score = scores[slug]
          inputs = Array(applied[slug])
          inputs = [:unknown] if inputs.empty?

          inputs.each do |input|
            labels << Moderate::Label.new(
              category: category, subcategory: subcategory,
              score: score, flagged: true, input: input
            )
          end
        end
      end

      # API key precedence: explicit config wins, else the conventional ENV var.
      # We read it lazily at call time (in the job), never at boot, so rotating the
      # key or setting it after the initializer runs both work.
      def api_key
        from_config = Moderate.config.respond_to?(:openai_api_key) ? Moderate.config.openai_api_key : nil
        from_config || ENV["OPENAI_API_KEY"]
      end

      def safe_body(response)
        response&.body.to_s[0, 500]
      rescue
        nil
      end

      def log(message)
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn(message)
        end
      end
    end
  end

  # Registry alias — see the note in wordlist.rb. The OpenAI adapter is NOT seeded by
  # the spine (a host opts in via `config.register_adapter :openai, ...` or
  # `config.filter ..., with: :openai`), but we still expose it under the
  # `Moderate::Adapters` namespace for symmetry and so docs that reference
  # `Moderate::Adapters::OpenAI` resolve.
  module Adapters; end
  Adapters::OpenAI = Filters::OpenAI
end
