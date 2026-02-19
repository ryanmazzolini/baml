# frozen_string_literal: true

require_relative "callbacks"
require_relative "serde"
require_relative "function_result"

module Baml
  module Ffi
    class FunctionResultStream
      def initialize(call_id, queue)
        @call_id = call_id
        @queue = queue
      end

      # The generated client calls: stream.done(ctx) { |partial| ... }
      # Drains partial callbacks, yields each to the block, returns the final FunctionResult.
      def done(_ctx, &on_partial)
        loop do
          result = @queue.pop

          if result[:error]
            Callbacks.remove(@call_id)
            raise BamlError, result[:error]
          end

          if result[:bytes]
            is_final = result[:is_done] == 1

            if is_final
              Callbacks.remove(@call_id)
              return FunctionResult.new(result[:bytes])
            end

            if on_partial
              partial = FunctionResult.new(result[:bytes])
              on_partial.call(partial)
            end
          end
        end
      end
    end
  end
end
