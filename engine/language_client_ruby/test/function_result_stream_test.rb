# frozen_string_literal: true

require "minitest/autorun"
require "minitest/reporters"
require_relative "../lib/baml"

# Exercises FunctionResultStream#done without touching Rust.
# The queue is populated with synthetic callback payloads that mimic what
# Callbacks.push produces; FunctionResult.new on partial bytes is only
# materialized lazily via decode, so we never need real protobuf bytes.
class FunctionResultStreamTest < Minitest::Test
  FAKE_CALL_ID = 0xDEADBEEF

  def stub_function_result
    stub = Class.new do
      attr_reader :bytes
      def initialize(bytes) = @bytes = bytes
    end
    original = Baml::Ffi.send(:remove_const, :FunctionResult)
    Baml::Ffi.const_set(:FunctionResult, stub)
    yield stub
  ensure
    Baml::Ffi.send(:remove_const, :FunctionResult)
    Baml::Ffi.const_set(:FunctionResult, original)
  end

  def test_defer_after_partials_returns_deferred_error_and_raises_on_parse
    stub_function_result do
      queue = Queue.new
      queue.push({ bytes: "partial-1", is_done: 0 })
      queue.push({ error: "rust exploded after partial" })

      stream = Baml::Ffi::FunctionResultStream.new(FAKE_CALL_ID, queue)

      seen = []
      result = stream.done(nil, defer_after_partials: true) do |partial|
        seen << partial.bytes
      end

      assert_equal ["partial-1"], seen
      assert_instance_of Baml::Ffi::DeferredError, result
      assert_equal "rust exploded after partial", result.message

      error = assert_raises(Baml::Ffi::BamlError) { result.parsed_using_types }
      assert_equal "rust exploded after partial", error.message
    end
  end

  def test_error_before_any_partial_raises_immediately
    stub_function_result do
      queue = Queue.new
      queue.push({ error: "auth failed" })

      stream = Baml::Ffi::FunctionResultStream.new(FAKE_CALL_ID, queue)

      error = assert_raises(Baml::Ffi::BamlError) do
        stream.done(nil, defer_after_partials: true) { |_| }
      end
      assert_equal "auth failed", error.message
    end
  end

  def test_timeout_raises_baml_error
    stub_function_result do
      queue = Queue.new # never populated
      stream = Baml::Ffi::FunctionResultStream.new(FAKE_CALL_ID, queue)

      error = assert_raises(Baml::Ffi::BamlError) do
        stream.done(nil, timeout: 0.01) { |_| }
      end
      assert_match(/timed out/, error.message)
    end
  end

  def test_final_chunk_returns_function_result
    stub_function_result do |stub|
      queue = Queue.new
      queue.push({ bytes: "final-bytes", is_done: 1 })

      stream = Baml::Ffi::FunctionResultStream.new(FAKE_CALL_ID, queue)
      result = stream.done(nil) { |_| }

      assert_instance_of stub, result
      assert_equal "final-bytes", result.bytes
    end
  end
end

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
