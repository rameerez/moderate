# frozen_string_literal: true

require "test_helper"

# Tests for the OpenAI omni-moderation-latest adapter, Moderate::Filters::OpenAI —
# the recommended "real", multimodal (text + image) backend whose wire taxonomy IS
# the gem's canonical Moderate::Label taxonomy:
# https://developers.openai.com/api/docs/guides/moderation
#
# NO NETWORK. Every test STUBS Net::HTTP (via Mocha, already loaded by test_helper)
# so the request never leaves the process — we assert on (a) what the adapter sends
# and (b) how it parses a canned response. The adapter is documented to "fail OPEN"
# on any error (a moderation API is defense-in-depth, not a gatekeeper that should
# take down posting on an upstream blip), so we also assert the fail-open paths.
#
# The adapter reads its key from config.openai_api_key (not defined on the stock
# Configuration) OR ENV["OPENAI_API_KEY"]; we set the ENV var so the request path is
# exercised, and restore it in teardown so other tests see a clean environment.
# NOTE: top-level test class (not nested under `Moderate::Filters`) — same reasoning
# as WordlistFilterTest: opening the explicit `Moderate::Filters` class to hang a
# *_test on it would force its Zeitwerk autoload at class-definition time. The
# `Moderate::Filters::OpenAI` references inside the methods autoload lazily at call time.
class OpenAIFilterTest < ActiveSupport::TestCase
  setup do
    @previous_key = ENV["OPENAI_API_KEY"]
    ENV["OPENAI_API_KEY"] = "sk-test-key"
  end

  teardown do
    if @previous_key.nil?
      ENV.delete("OPENAI_API_KEY")
    else
      ENV["OPENAI_API_KEY"] = @previous_key
    end
  end

  # Build a fake Net::HTTPSuccess wrapping the given JSON body, and stub the HTTP
  # client so `http.request(...)` returns it. We capture the outgoing request so a
  # test can assert on the request body (the `input` parts we built).
  #
  # Returns the captured request object (after the block runs) so the caller can
  # inspect request.body. We stub at the Net::HTTP instance level: `Net::HTTP.new`
  # returns a stubbed client whose #request yields the canned response.
  def stub_openai(response_body, status: "200")
    response = build_http_response(response_body, status: status)
    captured = { request: nil }

    http = mock("http")
    http.stubs(:use_ssl=)
    http.stubs(:open_timeout=)
    http.stubs(:read_timeout=)
    # Capture the request the adapter built, then return our canned response. Mocha's
    # block parameter-matcher (`.with { |arg| ... }`) returns truthy to match ANY
    # request while letting us stash it for later assertions. Braces (not do/end) so
    # the block binds tightly to `.with` and `.returns` chains off the same expectation.
    http.stubs(:request).with { |request| captured[:request] = request; true }.returns(response)

    Net::HTTP.stubs(:new).returns(http)

    yield if block_given?
    captured[:request]
  end

  # Construct a real Net::HTTPResponse subclass instance (HTTPOK / a generic error)
  # carrying the body, so `response.is_a?(Net::HTTPSuccess)` and `response.body`
  # behave exactly as the adapter expects — no need to mock the response duck type.
  def build_http_response(body, status:)
    # Net::HTTPOK is a Net::HTTPSuccess (the adapter's success branch);
    # Net::HTTPBadRequest is NOT (the adapter's fail-open branch). Stubbing #body
    # directly sidesteps Net::HTTP's "body already read" bookkeeping entirely.
    klass = status.to_s.start_with?("2") ? Net::HTTPOK : Net::HTTPBadRequest
    response = klass.new("1.1", status.to_s, "Status")
    response.stubs(:body).returns(body.is_a?(String) ? body : JSON.generate(body))
    response
  end

  # A representative flagged response: a multimodal item where "hate" tripped on the
  # text, "hate/threatening" on the text, and "sexual/minors" on the image — exactly
  # the kind of mixed verdict that exercises subcategory parsing AND per-input
  # attribution (category_applied_input_types).
  def flagged_payload
    {
      "id" => "modr-abc123",
      "model" => "omni-moderation-latest",
      "results" => [
        {
          "flagged" => true,
          "categories" => {
            "hate" => true,
            "hate/threatening" => true,
            "sexual" => false,
            "sexual/minors" => true,
            "violence" => false
          },
          "category_scores" => {
            "hate" => 0.97,
            "hate/threatening" => 0.81,
            "sexual" => 0.01,
            "sexual/minors" => 0.66,
            "violence" => 0.02
          },
          "category_applied_input_types" => {
            "hate" => ["text"],
            "hate/threatening" => ["text"],
            "sexual/minors" => ["image"]
          }
        }
      ]
    }
  end

  def classify(value)
    Moderate::Filters::OpenAI.classify(value)
  end

  # --- Response parsing: labels with subcategories ---------------------------

  test "parses a flagged response into canonical labels with subcategories" do
    stub_openai(flagged_payload) do
      result = classify("hateful threatening text")

      refute result.allowed?
      assert result.flagged?
      # Only FLAGGED categories surface as labels — the scored-but-not-flagged
      # "sexual"/"violence" entries must NOT appear.
      assert_includes result.categories, :hate
      assert_includes result.categories, :"hate/threatening"
      assert_includes result.categories, :"sexual/minors"
      refute_includes result.categories, :sexual
      refute_includes result.categories, :violence
    end
  end

  test "carries the 0..1 provider scores onto the labels" do
    stub_openai(flagged_payload) do
      result = classify("hateful text")

      assert_in_delta 0.97, result.scores["hate"]
      assert_in_delta 0.81, result.scores["hate/threatening"]
      assert_in_delta 0.66, result.scores["sexual/minors"]
    end
  end

  test "attributes each label to the input type(s) that tripped it" do
    stub_openai(flagged_payload) do
      result = classify([{ text: "caption" }, { image_url: "https://example.com/x.jpg" }])

      hate = result.labels.find { |l| l.slug == "hate" }
      minors = result.labels.find { |l| l.slug == "sexual/minors" }

      assert_equal :text, hate.input, "hate tripped on the text input"
      assert_equal :image, minors.input, "sexual/minors tripped on the image input"
    end
  end

  test "emits one label per applied input for a multimodal hit" do
    # When a single category trips on BOTH text and image, the adapter emits one
    # label per applied input so the verdict is fully attributed (not collapsed).
    payload = {
      "results" => [
        {
          "flagged" => true,
          "categories" => { "violence" => true },
          "category_scores" => { "violence" => 0.9 },
          "category_applied_input_types" => { "violence" => ["text", "image"] }
        }
      ]
    }

    stub_openai(payload) do
      result = classify([{ text: "t" }, { image_url: "u" }])

      violence_inputs = result.labels.select { |l| l.category == :violence }.map(&:input)
      assert_equal [:text, :image], violence_inputs
      # categories de-duplicates the slug even though there are two labels.
      assert_equal [:violence], result.categories
    end
  end

  test "records source 'external_classifier' to satisfy the flags source constraint" do
    stub_openai(flagged_payload) do
      result = classify("hateful text")
      assert_equal "external_classifier", result.source
    end
  end

  test "a not-flagged response is allowed even when scores are present" do
    payload = {
      "results" => [
        {
          "flagged" => false,
          "categories" => { "hate" => false },
          "category_scores" => { "hate" => 0.12 },
          "category_applied_input_types" => {}
        }
      ]
    }

    stub_openai(payload) do
      result = classify("perfectly fine text")
      assert result.allowed?
      assert_empty result.categories
    end
  end

  # --- Request shaping (host-agnostic input shapes) --------------------------

  test "sends a wire-shaped text part for a plain String, with the omni model" do
    request = stub_openai(flagged_payload) do
      classify("some text")
    end

    body = JSON.parse(request.body)
    assert_equal "omni-moderation-latest", body["model"]
    assert_equal [{ "type" => "text", "text" => "some text" }], body["input"]
    assert_equal "Bearer sk-test-key", request["Authorization"]
    assert_equal "application/json", request["Content-Type"]
  end

  test "builds text + image_url parts from a convenience hash" do
    request = stub_openai(flagged_payload) do
      classify({ text: "a caption", image_url: "https://example.com/p.jpg" })
    end

    body = JSON.parse(request.body)
    assert_equal(
      [
        { "type" => "text", "text" => "a caption" },
        { "type" => "image_url", "image_url" => { "url" => "https://example.com/p.jpg" } }
      ],
      body["input"]
    )
  end

  test "flattens an array of mixed parts into the input list" do
    request = stub_openai(flagged_payload) do
      classify(["first", { image_url: "https://example.com/p.jpg" }, "second"])
    end

    body = JSON.parse(request.body)
    types = body["input"].map { |part| part["type"] }
    assert_equal ["text", "image_url", "text"], types
  end

  # --- Fail OPEN (defense-in-depth, never a gatekeeper) ----------------------

  test "fails open (allowed) when no API key is configured" do
    ENV.delete("OPENAI_API_KEY")
    # No HTTP stub needed — the adapter short-circuits before any network call.
    Net::HTTP.expects(:new).never

    result = classify("anything")
    assert result.allowed?, "a missing key must fail open, not raise or block"
  end

  test "fails open on a non-2xx HTTP status" do
    stub_openai({ "error" => "bad request" }, status: "400") do
      result = classify("some text")
      assert result.allowed?, "an HTTP 400 must fail open"
    end
  end

  test "fails open on a network exception (timeout, reset, ...)" do
    Net::HTTP.stubs(:new).raises(Timeout::Error.new("execution expired"))

    result = classify("some text")
    assert result.allowed?, "a network blip must never block a save — fail open"
    # The fail-open Result records the error class in raw for audit/debugging.
    assert_equal "Timeout::Error", result.raw[:error]
  end

  test "fails open on a malformed (non-JSON) response body" do
    stub_openai("this is not json", status: "200") do
      result = classify("some text")
      assert result.allowed?, "an unparseable body must fail open"
    end
  end

  # --- Async contract (forbidden in :block) ----------------------------------

  test "declares itself asynchronous (background-only)" do
    # This is the flag the spine reads to (a) route the adapter through ClassifyJob in
    # :flag mode and (b) FORBID it in :block mode — you can't reject a save on a
    # result that's still in flight.
    assert Moderate::Filters::OpenAI.async?
    refute Moderate::Filters::OpenAI.synchronous?
  end

  test "pairing :openai with mode :block is a configuration error" do
    # The README rule: ":block requires a synchronous adapter". The spine's
    # configure -> validate! must raise when a :block filter names the async OpenAI
    # adapter. We register :openai (it isn't seeded by default) and declare a :block
    # filter, then assert configure raises a ConfigurationError mentioning :block.
    error = assert_raises(Moderate::ConfigurationError) do
      Moderate.configure do |config|
        config.user_class = "User"
        config.register_adapter :openai, Moderate::Filters::OpenAI
        config.filter "Comment", :body, with: :openai, mode: :block
      end
    end

    assert_match(/block/, error.message)
  end

  test "pairing :openai with mode :flag validates cleanly" do
    # The correct pairing for an async adapter: :flag (allow the write, classify in a
    # job, file a Moderate::Flag). This must NOT raise.
    assert Moderate.configure { |config|
      config.user_class = "User"
      config.register_adapter :openai, Moderate::Filters::OpenAI
      config.filter "Comment", :body, with: :openai, mode: :flag
    }
  end
end
