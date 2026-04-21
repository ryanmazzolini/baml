# frozen_string_literal: true

require "baml/cffi/v1/baml_object_pb"
require "baml/cffi/v1/baml_object_methods_pb"

module Baml
  module Ffi
    # Base class wrapping a Rust-side CFFI object handle (Arc pointer).
    # Mirrors Go's raw_objects.RawObject: construct via protobuf, call methods
    # via protobuf, GC-clean via ~destructor method.
    #
    # All TypeBuilder/Collector/Media wrappers inherit or delegate to this.
    class RawObject
      Proto = Baml::Cffi::V1

      # BamlObjectType enum → BamlObjectHandle oneof field name
      HANDLE_FIELD = {
        :OBJECT_COLLECTOR             => :collector,
        :OBJECT_FUNCTION_LOG          => :function_log,
        :OBJECT_USAGE                 => :usage,
        :OBJECT_TIMING                => :timing,
        :OBJECT_STREAM_TIMING         => :stream_timing,
        :OBJECT_LLM_CALL              => :llm_call,
        :OBJECT_LLM_STREAM_CALL       => :llm_stream_call,
        :OBJECT_HTTP_REQUEST          => :http_request,
        :OBJECT_HTTP_RESPONSE         => :http_response,
        :OBJECT_HTTP_BODY             => :http_body,
        :OBJECT_SSE_RESPONSE          => :sse_response,
        :OBJECT_MEDIA_IMAGE           => :media_image,
        :OBJECT_MEDIA_AUDIO           => :media_audio,
        :OBJECT_MEDIA_PDF             => :media_pdf,
        :OBJECT_MEDIA_VIDEO           => :media_video,
        :OBJECT_TYPE_BUILDER          => :type_builder,
        :OBJECT_TYPE                  => :type,
        :OBJECT_ENUM_BUILDER          => :enum_builder,
        :OBJECT_ENUM_VALUE_BUILDER    => :enum_value_builder,
        :OBJECT_CLASS_BUILDER         => :class_builder,
        :OBJECT_CLASS_PROPERTY_BUILDER => :class_property_builder,
      }.freeze

      # Subclass registry: object_type → wrapper class.
      # Populated by requiring type_builder.rb, media.rb, collector.rb, etc.
      WRAPPER_CLASS = {}

      # Class macro: generates methods that delegate to call_method.
      # Usage: cffi_method :usage, :name, :logs
      def self.cffi_method(*names)
        names.each do |name|
          define_method(name) { call_method(name.to_s) }
        end
      end

      @shutting_down = false

      class << self
        def shutting_down?
          @shutting_down
        end

        # Construct a new CFFI object. Returns a RawObject (or subclass via block).
        # object_type: BamlObjectType symbol (e.g. :OBJECT_TYPE_BUILDER)
        # runtime_ptr: opaque FFI pointer to BamlRuntime (nil for primitives)
        # kwargs: Hash of constructor arguments
        def construct(object_type, runtime_ptr: nil, kwargs: {})
          invocation = Proto::BamlObjectConstructorInvocation.new(
            type: object_type,
            kwargs: Serde.encode_map_entries(kwargs)
          )
          bytes = Proto::BamlObjectConstructorInvocation.encode(invocation)
          response = invoke_constructor(bytes)
          decode_object_response(response, runtime_ptr)
        end

        private

        def invoke_constructor(encoded_bytes)
          ffi_call(encoded_bytes) { |ptr, len| Bindings.call_object_constructor(ptr, len) }
        end

        # Sends encoded protobuf bytes through an FFI call and decodes the response.
        # The block receives (pointer, length) and must return an FFI buffer.
        def ffi_call(encoded_bytes, &block)
          ptr = FFI::MemoryPointer.new(:char, encoded_bytes.bytesize)
          ptr.put_bytes(0, encoded_bytes)
          buf = block.call(ptr, encoded_bytes.bytesize)
          raw = Bindings.read_buffer(buf)
          Bindings.free_buffer(buf)
          Proto::InvocationResponse.decode(raw)
        end
      end

      attr_reader :pointer, :object_type, :runtime_ptr

      # Wrap an existing pointer returned from Rust.
      # object_type: BamlObjectType symbol
      # pointer: int64 raw pointer value
      # runtime_ptr: opaque FFI pointer to BamlRuntime
      def initialize(object_type, pointer, runtime_ptr)
        @object_type = object_type
        @pointer = pointer
        @runtime_ptr = runtime_ptr
        @mutex = Mutex.new

        register_finalizer
      end

      # Call a method on this CFFI object.
      # Returns: decoded Ruby value, RawObject, or Array of RawObjects.
      def call_method(method_name, kwargs = {})
        @mutex.synchronize do
          invocation = Proto::BamlObjectMethodInvocation.new(
            object: encode_handle,
            method_name: method_name,
            kwargs: Serde.encode_map_entries(kwargs)
          )
          bytes = Proto::BamlObjectMethodInvocation.encode(invocation)
          response = invoke_method(bytes)
          self.class.decode_object_response(response, @runtime_ptr)
        end
      end

      # Encode this object as a BamlObjectHandle protobuf message.
      def encode_handle
        field = HANDLE_FIELD.fetch(@object_type) do
          raise ArgumentError, "unknown object type: #{@object_type}"
        end
        Proto::BamlObjectHandle.new(
          field => Proto::BamlPointerType.new(pointer: @pointer)
        )
      end

      private

      def invoke_method(encoded_bytes)
        runtime_ptr = @runtime_ptr
        self.class.send(:ffi_call, encoded_bytes) { |ptr, len| Bindings.call_object_method(runtime_ptr, ptr, len) }
      end

      def register_finalizer
        destructor = RawObject.make_destructor(@object_type, @pointer, @runtime_ptr, @mutex)
        ObjectSpace.define_finalizer(self, destructor)
      end

      # Class method so the destructor proc doesn't capture `self` (preventing GC).
      # Always references RawObject directly so subclass finalizers check the right flag.
      def self.make_destructor(object_type, pointer, runtime_ptr, mutex)
        proc do
          next if RawObject.shutting_down?
          RawObject.destroy(object_type, pointer, runtime_ptr, mutex)
        end
      end

      def self.destroy(object_type, pointer, runtime_ptr, mutex)
        mutex.synchronize do
          field = HANDLE_FIELD[object_type]
          return unless field

          handle = Proto::BamlObjectHandle.new(
            field => Proto::BamlPointerType.new(pointer: pointer)
          )
          invocation = Proto::BamlObjectMethodInvocation.new(
            object: handle,
            method_name: "~destructor",
            kwargs: []
          )
          bytes = Proto::BamlObjectMethodInvocation.encode(invocation)
          ffi_call(bytes) { |ptr, len| Bindings.call_object_method(runtime_ptr, ptr, len) }
        end
      rescue => e
        # Swallow errors during finalization — can't raise from finalizer.
        $stderr.puts "[BAML] finalizer error: #{e.message}" if $DEBUG
      end

      # Decode an InvocationResponse into Ruby objects.
      def self.decode_object_response(response, runtime_ptr)
        case response.response
        when :error
          raise BamlError, response.error
        when :success
          decode_success(response.success, runtime_ptr)
        else
          raise BamlError, "unexpected InvocationResponse variant: #{response.response}"
        end
      end

      def self.decode_success(success, runtime_ptr)
        case success.result
        when :object
          decode_handle(success.object, runtime_ptr)
        when :objects
          success.objects.objects.map { |h| decode_handle(h, runtime_ptr) }
        when :value
          Serde.decode_value(success.value)
        else
          nil
        end
      end

      # Convert a BamlObjectHandle protobuf back into a RawObject (or subclass).
      # Prefers `_from_raw` when the subclass defines one (so its `.new` can stay
      # a user-facing kwarg constructor, e.g. Collector).
      def self.decode_handle(handle, runtime_ptr)
        field = handle.object  # oneof discriminator symbol
        ptr_msg = handle.send(field)
        object_type = HANDLE_FIELD.key(field)
        raise BamlError, "unknown handle field: #{field}" unless object_type
        klass = WRAPPER_CLASS.fetch(object_type, self)
        if klass.respond_to?(:_from_raw)
          klass._from_raw(object_type, ptr_msg.pointer, runtime_ptr)
        else
          klass.new(object_type, ptr_msg.pointer, runtime_ptr)
        end
      end
    end

    # at_exit: set shutting_down flag so GC finalizers skip FFI calls.
    # We don't explicitly destroy objects here — the BamlRuntime's own finalizer
    # may have already run (finalizers can fire during GC within at_exit), and
    # the OS reclaims all memory on process exit. Trace flushing is handled
    # separately via an explicit flush call (see Process Safety milestone).
    at_exit do
      RawObject.instance_variable_set(:@shutting_down, true)
    end
  end
end
