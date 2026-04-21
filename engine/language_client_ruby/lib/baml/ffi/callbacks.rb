# frozen_string_literal: true

require_relative "bindings"
require_relative "serde"

module Baml
  module Ffi
    # Manages async callback dispatch between Rust and Ruby.
    # Rust calls these procs from a Tokio worker thread; we push results
    # into per-call queues that the calling thread blocks on.
    #
    # Mirrors: language_client_go/pkg/callbacks.go
    module Callbacks
      module_function

      @mutex = Mutex.new
      @pending = {} # call_id => Queue
      # Monotonic counter matches Go's atomic.Uint32 in language_client_go/pkg/callbacks.go
      # and keeps log output ordered by call sequence.
      @next_id = 0
      CALL_ID_MODULO = 1 << 32

      def register!
        on_result = proc do |call_id, is_done, content_ptr, length|
          bytes = (length > 0 && !content_ptr.null?) ? content_ptr.read_bytes(length) : nil
          push(call_id, { is_done: is_done, bytes: bytes })
        end

        on_error = proc do |call_id, _is_done, content_ptr, length|
          msg = (length > 0 && !content_ptr.null?) ? content_ptr.read_string(length) : "(empty)"
          push(call_id, { error: msg })
        end

        on_tick = proc do |_call_id|
          # streaming heartbeat — not used yet
        end

        # prevent GC from collecting the procs while Rust holds the function pointers
        @prevent_gc = [on_result, on_error, on_tick]

        Bindings.register_callbacks(on_result, on_error, on_tick)
      end

      def create(call_id)
        queue = Queue.new
        @mutex.synchronize { @pending[call_id] = queue }
        queue
      end

      def remove(call_id)
        @mutex.synchronize { @pending.delete(call_id) }
      end

      def next_id
        @mutex.synchronize do
          @next_id = (@next_id + 1) % CALL_ID_MODULO
          @next_id
        end
      end

      def push(call_id, result)
        queue = @mutex.synchronize { @pending[call_id] }
        queue&.push(result)
      end
    end
  end
end
