# frozen_string_literal: true

require_relative "serde"

module Baml
  module Ffi
    class FunctionResult
      def initialize(bytes)
        @parsed = Serde.decode_value_holder(bytes) if bytes
      end

      # Coerces decoded hashes into T::Struct instances eagerly, like Go's serde.Decode.
      # Returns a FunctionResultParsed that delegates to the coerced value.
      def parsed_using_types(types_module, partial_types, allow_partials)
        coerce_module = allow_partials ? partial_types : types_module
        coerced = Serde.coerce_to_struct(@parsed, coerce_module)
        FunctionResultParsed.new(coerced)
      end
    end

    # Thin wrapper over the coerced value. Supports both usage patterns:
    #   - Sync generated client: parsed.cast_to(SomeType) — returns the value
    #   - Streaming path: partial.some_field — delegates to the value
    class FunctionResultParsed
      def initialize(value)
        @value = value
      end

      def cast_to(_type)
        @value
      end

      def method_missing(name, *args, &block)
        @value.send(name, *args, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @value.respond_to?(name, include_private) || super
      end
    end
  end
end
