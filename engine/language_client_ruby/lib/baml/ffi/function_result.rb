# frozen_string_literal: true

require_relative "serde"

module Baml
  module Ffi
    class FunctionResult
      def initialize(bytes)
        @parsed = Serde.decode_value_holder(bytes) if bytes
      end

      # Coerces decoded hashes into T::Struct instances using the appropriate types module.
      def parsed_using_types(types_module, partial_types, allow_partials)
        coerce_module = allow_partials ? partial_types : types_module
        Serde.coerce_to_struct(@parsed, coerce_module)
      end
    end
  end
end
