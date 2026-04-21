# frozen_string_literal: true

require "json"
require "timeout"
require_relative "bindings"
require_relative "callbacks"
require_relative "serde"

module Baml
  module Ffi
    class BamlError < RuntimeError; end
    class BamlClientError < BamlError; end
    # TODO: parse Rust error strings into typed errors when Go does (ref: engine/language_client_go/pkg/callbacks.go:154)

    # Thread-safe default runtime pointer, strictly for backwards compatibility
    # with static factory APIs (e.g. Baml::Image.from_url). New code should use
    # the canonical runtime methods (e.g. runtime.new_image) instead.
    # Set during BamlRuntime#initialize; last-writer-wins (single runtime per process).
    @runtime_mutex = Mutex.new
    @default_runtime_ptr = nil

    class << self
      def default_runtime_ptr
        @runtime_mutex.synchronize { @default_runtime_ptr }
      end

      # Returns the default runtime pointer, raising if none has been registered.
      def default_runtime_ptr!
        ptr = default_runtime_ptr
        raise BamlError, "BamlRuntime must be initialized before creating media objects" unless ptr
        ptr
      end

      def register_runtime(ptr)
        @runtime_mutex.synchronize { @default_runtime_ptr = ptr }
      end
    end

    class BamlRuntime
      def initialize(runtime_ptr)
        @ptr = runtime_ptr
        Baml::Ffi.register_runtime(@ptr)

        ptr_to_free = @ptr
        ObjectSpace.define_finalizer(self, self.class.release_fn(ptr_to_free))
      end

      def self.release_fn(ptr)
        proc { Bindings.destroy_baml_runtime(ptr) }
      end

      def self.from_files(root_path, files, env_vars)
        # ENV is a special Hash-like object that doesn't serialize with JSON.generate;
        # convert it to a plain Hash first. Also accept any Hash-like (respond_to? :to_h).
        env_hash = env_vars.respond_to?(:to_h) ? env_vars.to_h : env_vars
        ptr = Bindings.create_baml_runtime(
          root_path,
          JSON.generate(files),
          JSON.generate(env_hash)
        )
        raise BamlError, "create_baml_runtime returned null" if ptr.null?
        new(ptr)
      end

      def self.from_directory(directory, env_vars)
        files = Dir.glob(File.join(directory, "**/*.baml")).each_with_object({}) do |path, hash|
          relative = path.sub("#{directory}/", "")
          hash[relative] = File.read(path)
        end
        from_files(directory, files, env_vars)
      end

      def new_type_builder
        TypeBuilder.create(@ptr)
      end

      # Canonical constructors
      def new_collector(name: "") = Collector.create(@ptr, name: name)
      def new_image(**kwargs) = Image.create(@ptr, **kwargs)
      def new_audio(**kwargs) = Audio.create(@ptr, **kwargs)
      def new_pdf(**kwargs) = Pdf.create(@ptr, **kwargs)
      def new_video(**kwargs) = Video.create(@ptr, **kwargs)

      def create_context_manager
        # TODO: implement via CFFI once context manager is exposed
        RuntimeContextManager.new
      end

      def call_function(function_name, args, ctx, tb, client_registry, collectors, env_vars, tags = {})
        result = spawn_and_wait(function_name, args, env_vars: env_vars, tb: tb,
          client_registry: client_registry, collectors: collectors, tags: tags) do |ptr, len, call_id|
          Bindings.call_function_from_c(@ptr, function_name, ptr, len, call_id)
        end
        FunctionResult.new(result[:bytes])
      end

      def stream_function(function_name, args, ctx, tb, client_registry, collectors, env_vars, tags = {})
        call_id, queue = spawn(function_name, args, env_vars: env_vars, tb: tb,
          client_registry: client_registry, collectors: collectors, tags: tags) do |ptr, len, id|
          Bindings.call_function_stream_from_c(@ptr, function_name, ptr, len, id)
        end
        FunctionResultStream.new(call_id, queue)
      end

      # Build an HTTP request without executing it. Returns an HTTPRequest RawObject.
      def request_function(function_name, args, ctx, tb, client_registry, env_vars, stream: false, tags: {})
        # Rust extracts and removes the stream flag from kwargs
        result = spawn_and_wait(function_name, args.merge("stream" => stream),
          env_vars: env_vars, tb: tb, client_registry: client_registry, tags: tags) do |ptr, len, call_id|
          Bindings.build_request_from_c(@ptr, function_name, ptr, len, call_id)
        end
        response = Baml::Cffi::V1::InvocationResponse.decode(result[:bytes])
        RawObject.decode_object_response(response, @ptr)
      end

      # Parse an LLM response string into a typed result. Returns a FunctionResult.
      def parse_function(function_name, llm_response, ctx, tb, client_registry, env_vars, allow_partials: false, tags: {})
        result = spawn_and_wait(function_name, { "text" => llm_response, "stream" => allow_partials },
          env_vars: env_vars, tb: tb, client_registry: client_registry, tags: tags) do |ptr, len, call_id|
          Bindings.call_function_parse_from_c(@ptr, function_name, ptr, len, call_id)
        end
        FunctionResult.new(result[:bytes])
      end

      private

      # Encode args, invoke FFI via block, return [call_id, queue] for streaming.
      def spawn(function_name, args, env_vars:, tb: nil, client_registry: nil, collectors: [], tags: {})
        call_id = Callbacks.next_id
        queue = Callbacks.create(call_id)

        encoded = Serde.encode_function_args(
          args, env_vars: env_vars || {}, type_builder: tb,
          client_registry: client_registry, collectors: collectors || [], tags: tags || {}
        )
        encoded_bytes = Baml::Cffi::V1::HostFunctionArguments.encode(encoded)

        args_ptr = FFI::MemoryPointer.new(:char, encoded_bytes.bytesize)
        args_ptr.put_bytes(0, encoded_bytes)

        buf = yield(args_ptr, encoded_bytes.bytesize, call_id)
        spawn_bytes = Bindings.read_buffer(buf)
        Bindings.free_buffer(buf)
        Serde.decode_spawn_response(spawn_bytes)

        [call_id, queue]
      end

      # Spawn, wait for single result, raise on error.
      # timeout: seconds to wait for the Rust callback (nil = no timeout).
      # On expiry, the call is removed and BamlError is raised — useful when
      # the Tokio task hangs or its future is dropped without ever firing back.
      def spawn_and_wait(function_name, args, timeout: nil, **opts, &block)
        call_id, queue = spawn(function_name, args, **opts, &block)
        result = pop_with_timeout(queue, timeout, call_id)
        Callbacks.remove(call_id)
        raise BamlError, result[:error] if result[:error]
        result
      end

      def pop_with_timeout(queue, timeout, call_id)
        return queue.pop if timeout.nil?
        Timeout.timeout(timeout) { queue.pop }
      rescue Timeout::Error
        Callbacks.remove(call_id)
        raise BamlError, "BAML call timed out after #{timeout}s"
      end
    end
  end
end
