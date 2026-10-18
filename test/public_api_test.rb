# frozen_string_literal: true

require "test_helper"

# The README's "What is public" section is the 1.0 API freeze. This test reads it,
# so the list and the code can't drift apart silently:
#
#   * every name the section lists exists (a constant, a class method or scope, an
#     instance method — including the private seams a host overrides — or a
#     configuration key);
#   * every public `Moderate.*` method and every configuration key is listed,
#     unless its source is tagged `@api private`;
#   * the notify and audit event lists are exactly Moderate::Event::NOTIFY_NAMES /
#     AUDIT_NAMES, and those are exactly the names the gem's code emits;
#   * every `Moderate…` name the README and docs/ mention anywhere exists.
class PublicApiTest < ActiveSupport::TestCase
  ROOT = File.expand_path("..", __dir__)
  README = File.read(File.join(ROOT, "README.md"))
  SECTION = README[/^## What is public\n(.*?)(?=^## )/m, 1] or raise "README has no '## What is public' section"

  # Host models that include the gem's concerns, for checking what a concern adds
  # through `included do` (associations, callbacks).
  HOSTS = -> { [User, Comment, PhotoPost] }

  test "every name the section lists exists" do
    missing = listed_names.reject { |name| resolves?(name) }.map { |name| describe(name) }

    assert_empty missing, "README 'What is public' lists names that don't exist"
  end

  test "every public Moderate.* method is listed, or tagged @api private" do
    listed = listed_names.filter_map { |owner, kind, name| name if owner == Moderate && kind == "." }
    public_methods = Moderate.singleton_methods(false).select { |name| gem_source?(Moderate.method(name)) }
    unlisted = public_methods.reject { |name| listed.include?(name.to_s) || api_private?(Moderate.method(name)) }

    assert_empty unlisted.sort, "public Moderate methods missing from README 'What is public' (or tag them @api private)"
  end

  test "every configuration key is listed" do
    listed = SECTION.scan(/`config\.(\w+[?!]?)/).flatten
    keys = Moderate::Configuration.public_instance_methods(false).map(&:to_s).reject { |name| name.end_with?("=") }
    keys.select! { |name| gem_source?(Moderate::Configuration.instance_method(name)) }

    assert_empty keys - listed, "configuration keys missing from README 'What is public'"
    assert_empty listed - keys, "README 'What is public' lists configuration keys that don't exist"
  end

  test "the event lists are the vocabulary constants, and the gem emits exactly those" do
    assert_equal Moderate::Event::NOTIFY_NAMES, section_symbols("Notify events")
    assert_equal Moderate::Event::AUDIT_NAMES, section_symbols("Audit events")

    emitted = emitted_event_names
    assert_equal Moderate::Event::NOTIFY_NAMES.sort, emitted[:notify].sort, "notify names in lib/ and app/"
    assert_equal Moderate::Event::AUDIT_NAMES.sort, emitted[:audit].sort, "audit names in lib/ and app/"
  end

  test "the README's full event vocabulary line matches the notify names" do
    line = README[/^The full event vocabulary: (.*)$/, 1]
    assert line, "README lost its 'The full event vocabulary:' line"
    assert_equal Moderate::Event::NOTIFY_NAMES.map(&:to_s), line.scan(/`(\w+)`/).flatten
  end

  test "every Moderate name in the README and docs/ exists" do
    missing = []
    (["README.md"] + Dir[File.join(ROOT, "docs", "*.md")].map { |path| path.delete_prefix("#{ROOT}/") }).each do |path|
      text = File.read(File.join(ROOT, path))
      host_defined = text.scan(/(?:class|module)\s+(Moderate::[A-Z][\w:]*)/).flatten
      text.scan(/\b(Moderate(?:::[A-Z]\w*)*)(?:([.#])([a-z_]\w*[?!]?))?/).uniq.each do |path_name, kind, method|
        next if host_defined.any? { |name| path_name.start_with?(name) }

        owner = constant(path_name)
        ok = owner && (method.nil? || responds?(owner, kind, method))
        missing << "#{path}: #{path_name}#{kind}#{method}" unless ok
      end
    end

    assert_empty missing, "the docs name Moderate constants or methods that don't exist"
  end

  private

  # [owner, kind, name] triples for every name the section lists. Relative names
  # (`.pending`, `#resolve!`, `::STATUSES`) belong to the constant named most
  # recently in the section (a heading or a plain `Moderate::X` mention).
  def listed_names
    @listed_names ||= begin
      owner = nil
      SECTION.each_line.flat_map do |line|
        owner = nil if line.start_with?("#### ")
        line.scan(/`([^`]+)`/).flatten.filter_map do |token|
          if (match = token.match(/\A(Moderate(?:::[A-Z]\w*)*)(?:([.#])([a-z_]\w*[?!]?))?/))
            target = constant(match[1])
            owner = target if match[2].nil? && target.is_a?(Module)
            match[2] ? [target, match[2], match[3], match[1]] : [target, "::", nil, match[1]]
          elsif (match = token.match(/\A(\.|#|::)([A-Za-z_]\w*[?!]?)/))
            [owner, match[1], match[2], owner&.name || "(no owner)"]
          end
        end
      end
    end
  end

  def resolves?((owner, kind, name, _label))
    return false if owner.nil?
    return true if kind == "::" && name.nil?
    return owner.const_defined?(name, false) if kind == "::"

    responds?(owner, kind, name)
  end

  def responds?(owner, kind, name)
    if kind == "."
      owner.respond_to?(name)
    elsif owner.is_a?(Class) || !owner.is_a?(Module)
      instance_method?(owner, name)
    else
      instance_method?(owner, name) || HOSTS.call.any? { |host| host.include?(owner) && instance_method?(host, name) }
    end
  end

  def instance_method?(owner, name)
    owner.method_defined?(name) || owner.private_method_defined?(name)
  end

  def describe((owner, kind, name, label))
    "#{label}#{kind unless kind == "::" && name.nil?}#{name}#{" (unknown owner)" if owner.nil?}"
  end

  def constant(path)
    path.safe_constantize
  end

  def gem_source?(method)
    file = method.source_location&.first
    file&.start_with?(File.join(ROOT, "lib")) || file&.start_with?(File.join(ROOT, "app"))
  end

  # The comment block right above the method's `def` says `@api private`.
  def api_private?(method)
    file, line = method.source_location
    lines = File.readlines(file)
    index = line - 2
    while index >= 0 && lines[index].strip.start_with?("#")
      return true if lines[index].include?("@api private")

      index -= 1
    end
    false
  end

  def section_symbols(label)
    line = SECTION[/^#{label} .*$/] or raise "README 'What is public' lost its #{label} line"
    line.scan(/`:(\w+)`/).flatten.map(&:to_sym)
  end

  # Every event name the gem's own code hands to Moderate.notify / Moderate.audit,
  # read from the source with the comments stripped.
  def emitted_event_names
    code = Dir[File.join(ROOT, "{lib,app}", "**", "*.rb")].sort.map do |path|
      File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
    end.join("\n")

    {
      notify: (code.scan(/\bnotify\(\s*(?:name:\s*)?:(\w+)/) + code.scan(/\bannounce,\s*:(\w+)/)).flatten.uniq.map(&:to_sym),
      audit: code.scan(/\baudit\(\s*(?:name:\s*)?:(\w+)/).flatten.uniq.map(&:to_sym)
    }
  end
end
