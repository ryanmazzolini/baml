# frozen_string_literal: true

require "json"
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

      # Canonical media constructors
      def new_image(**kwargs) = Image.create(@ptr, **kwargs)
      def new_audio(**kwargs) = Audio.create(@ptr, **kwargs)
      def new_pdf(**kwargs) = Pdf.create(@ptr, **kwargs)
      def new_video(**kwargs) = Video.create(@ptr, **kwargs)

      def create_context_manager
        # TODO: implement via CFFI once context manager is exposed
        RuntimeContextManager.new
      end

      # Matches the 8-arg signature the generated client code calls:
      #   runtime.call_function(name, args, ctx, tb, client_registry, collectors, env_vars, tags)
      def call_function(function_name, args, ctx, tb, client_registry, collectors, env_vars, tags = {})
        call_id = Callbacks.next_id
        queue = Callbacks.create(call_id)

        encoded = Serde.encode_function_args(args, env_vars: env_vars || {}, type_builder: tb)
        encoded_bytes = Baml::Cffi::V1::HostFunctionArguments.encode(encoded)

        args_ptr = FFI::MemoryPointer.new(:char, encoded_bytes.bytesize)
        args_ptr.put_bytes(0, encoded_bytes)

        buf = Bindings.call_function_from_c(@ptr, function_name, args_ptr, encoded_bytes.bytesize, call_id)
        spawn_bytes = Bindings.read_buffer(buf)
        Bindings.free_buffer(buf)
        Serde.decode_spawn_response(spawn_bytes)

        result = queue.pop
        Callbacks.remove(call_id)

        raise BamlError, result[:error] if result[:error]
        FunctionResult.new(result[:bytes])
      end

      # Same 8-arg signature, returns a FunctionResultStream
      def stream_function(function_name, args, ctx, tb, client_registry, collectors, env_vars, tags = {})
        call_id = Callbacks.next_id
        queue = Callbacks.create(call_id)

        encoded = Serde.encode_function_args(args, env_vars: env_vars || {}, type_builder: tb)
        encoded_bytes = Baml::Cffi::V1::HostFunctionArguments.encode(encoded)

        args_ptr = FFI::MemoryPointer.new(:char, encoded_bytes.bytesize)
        args_ptr.put_bytes(0, encoded_bytes)

        buf = Bindings.call_function_stream_from_c(@ptr, function_name, args_ptr, encoded_bytes.bytesize, call_id)
        spawn_bytes = Bindings.read_buffer(buf)
        Bindings.free_buffer(buf)
        Serde.decode_spawn_response(spawn_bytes)

        FunctionResultStream.new(call_id, queue)
      end
    end
  end
end
