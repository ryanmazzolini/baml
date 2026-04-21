# frozen_string_literal: true

module Baml
  module Ffi
    class Collector < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_COLLECTOR] = self

      # Canonical factory: construct via an explicit runtime pointer.
      def self.create(runtime_ptr, name: "")
        construct(:OBJECT_COLLECTOR, runtime_ptr: runtime_ptr, kwargs: { name: name })
      end

      # Convenience: Baml::Collector.new(name: "foo") uses the default runtime.
      def self.new(name: "")
        create(Baml::Ffi.default_runtime_ptr!, name: name)
      end

      # Internal: wrap an existing pointer returned from Rust. Called by
      # RawObject.decode_handle, which prefers this over .new so .new can stay
      # user-facing.
      def self._from_raw(object_type, pointer, runtime_ptr)
        obj = allocate
        obj.send(:initialize, object_type, pointer, runtime_ptr)
        obj
      end

      cffi_method :usage, :name, :logs, :last, :clear

      def id(function_id)
        call_method("id", { id: function_id })
      end
    end

    class FunctionLog < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_FUNCTION_LOG] = self
      cffi_method :id, :function_name, :log_type, :timing, :usage,
                  :raw_llm_response, :calls, :metadata, :tags, :selected_call
    end

    class Usage < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_USAGE] = self
      cffi_method :input_tokens, :output_tokens, :cached_input_tokens
    end

    class Timing < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_TIMING] = self
      cffi_method :start_time_utc_ms, :duration_ms
    end

    class StreamTiming < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_STREAM_TIMING] = self
      cffi_method :start_time_utc_ms, :duration_ms
    end

    class LLMCall < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_LLM_CALL] = self
      cffi_method :client_name, :provider, :selected, :timing, :usage,
                  :http_request_id, :http_request, :http_response
    end

    class LLMStreamCall < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_LLM_STREAM_CALL] = self
      cffi_method :client_name, :provider, :selected, :timing, :usage,
                  :http_request, :http_response, :http_request_id, :sse_chunks
    end

    class HTTPRequest < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_HTTP_REQUEST] = self
      cffi_method :id, :url, :method, :headers, :body
    end

    class HTTPResponse < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_HTTP_RESPONSE] = self
      cffi_method :id, :status, :headers, :body
    end

    class HTTPBody < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_HTTP_BODY] = self
      cffi_method :text, :json
    end

    class SSEEvent < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_SSE_RESPONSE] = self
      cffi_method :text, :json
    end
  end
end