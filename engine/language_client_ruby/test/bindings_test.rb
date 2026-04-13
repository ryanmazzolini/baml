# frozen_string_literal: true

require "minitest/autorun"
require "minitest/reporters"
require_relative "../lib/baml/ffi/bindings"

class BindingsVersionCheckTest < Minitest::Test
  def setup
    @bindings = Baml::Ffi::Bindings
  end

  def test_verify_version_raises_on_mismatch
    fake_buffer = Object.new

    with_bindings_overrides(
      version: -> { fake_buffer },
      read_buffer: ->(_buf) { "0.0.0" },
      free_buffer: ->(_buf) { nil }
    ) do
      error = assert_raises(LoadError) { @bindings.send(:verify_version!) }
      assert_includes error.message, "gem expects #{Baml::Ffi::Library::VERSION}, library reports 0.0.0"
    end
  end

  def test_verify_version_accepts_matching_version
    fake_buffer = Object.new
    freed = false

    with_bindings_overrides(
      version: -> { fake_buffer },
      read_buffer: ->(_buf) { Baml::Ffi::Library::VERSION },
      free_buffer: ->(_buf) { freed = true }
    ) do
      assert_nil @bindings.send(:verify_version!)
    end

    assert freed, "expected verify_version! to free the version buffer"
  end

  private

  def with_bindings_overrides(overrides)
    singleton = class << @bindings; self; end
    previous = overrides.each_with_object({}) do |(name, _), memo|
      memo[name] = if singleton.method_defined?(name) || singleton.private_method_defined?(name) || singleton.protected_method_defined?(name)
                     {
                       defined: true,
                       method: singleton.instance_method(name),
                       visibility: method_visibility(singleton, name)
                     }
                   else
                     { defined: false }
                   end
    end

    overrides.each do |name, body|
      singleton.send(:define_method, name, &body)
    end

    yield
  ensure
    overrides.each_key do |name|
      if previous[name][:defined]
        singleton.send(:define_method, name, previous[name][:method])
        singleton.send(previous[name][:visibility], name)
      else
        singleton.send(:remove_method, name)
      end
    end
  end

  def method_visibility(singleton, name)
    return :private if singleton.private_method_defined?(name)
    return :protected if singleton.protected_method_defined?(name)

    :public
  end
end

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
