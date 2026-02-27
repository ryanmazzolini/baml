# frozen_string_literal: true

require "ffi"
require_relative "library"

module Baml
  module Ffi
    module Bindings
      extend FFI::Library

      # language_client_cffi/src/ffi/objects.rs — #[repr(C)] struct Buffer
      class Buffer < FFI::Struct
        layout :ptr, :pointer, :len, :size_t
      end

      callback :callback_fn, [:uint32, :int32, :pointer, :size_t], :void
      callback :on_tick_fn, [:uint32], :void

      class << self
        def load_library!
          ffi_lib Library.find
          attach_functions!
          verify_version!
        end

        def read_buffer(buf)
          return "".b if buf[:len] == 0 || buf[:ptr].null?
          buf[:ptr].read_bytes(buf[:len])
        end

        private

        def attach_functions!
          attach_function :version, [], Buffer.by_value
          attach_function :free_buffer, [Buffer.by_value], :void
          attach_function :create_baml_runtime, [:string, :string, :string], :pointer
          attach_function :destroy_baml_runtime, [:pointer], :void
          attach_function :register_callbacks, [:callback_fn, :callback_fn, :on_tick_fn], :void
          attach_function :call_function_from_c,
            [:pointer, :string, :pointer, :size_t, :uint32], Buffer.by_value
          attach_function :call_function_stream_from_c,
            [:pointer, :string, :pointer, :size_t, :uint32], Buffer.by_value
          attach_function :call_object_constructor,
            [:pointer, :size_t], Buffer.by_value
          attach_function :call_object_method,
            [:pointer, :pointer, :size_t], Buffer.by_value
        end

        def verify_version!
          buf = version
          lib_version = read_buffer(buf)
          free_buffer(buf)

          return if lib_version == Library::VERSION

          raise LoadError,
            "BAML version mismatch: gem expects #{Library::VERSION}, library reports #{lib_version}"
        end
      end
    end
  end
end
