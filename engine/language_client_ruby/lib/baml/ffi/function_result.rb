# frozen_string_literal: true

require_relative "serde"

module Baml
  module Ffi
    class FunctionResult
      def initialize(bytes)
        @parsed = Serde.decode_value_holder(bytes) if bytes
      end

      # The generated client calls: result.parsed_using_types(Types, PartialTypes, false)
      # In the CFFI path, Rust already parsed the result — the callback delivers the final value.
      # types/partial_types modules are unused here (they're for the magnus path's Ruby coercion).
      def parsed_using_types(_types, _partial_types, _allow_partials)
        FunctionResultParsed.new(@parsed)
      end
    end

    class FunctionResultParsed
      def initialize(value)
        @value = value
      end

      # Generated code calls: parsed.cast_to(BamlClient::Types::SomeClass)
      # With CFFI, the value is already the right Ruby type (String, Integer, Hash, etc.)
      def cast_to(_type)
        @value
      end
    end
  end
end
