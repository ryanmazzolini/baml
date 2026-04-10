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
      #
      # If defer_after_partials is true, errors that arrive after at least one
      # partial was delivered are stored instead of raised — the caller can
      # retrieve them via the returned object. Errors before any partial still
      # raise immediately (connection failures, auth errors, etc.).
      def done(_ctx, defer_after_partials: false, &on_partial)
        partials_delivered = false

        loop do
          result = @queue.pop

          if result[:error]
            Callbacks.remove(@call_id)
            if defer_after_partials && partials_delivered
              return DeferredError.new(result[:error])
            end
            raise BamlError, result[:error]
          end

          if result[:bytes]
            is_final = result[:is_done] == 1

            if is_final
              Callbacks.remove(@call_id)
              return FunctionResult.new(result[:bytes])
            end

            if on_partial
              partials_delivered = true
              partial = FunctionResult.new(result[:bytes])
              on_partial.call(partial)
            end
          end
        end
      end
    end

    # Sentinel returned by done() when a post-partial error is deferred.
    class DeferredError
      attr_reader :message

      def initialize(message)
        @message = message
      end

      def parsed_using_types(*, **)
        raise BamlError, @message
      end
    end
  end
end
