# frozen_string_literal: true

require_relative "ffi/stubs"
require_relative "ffi/library"
require_relative "ffi/bindings"
require_relative "ffi/serde"
require_relative "ffi/callbacks"
require_relative "ffi/raw_object"
require_relative "ffi/type_builder"
require_relative "ffi/media"
require_relative "ffi/collector"
require_relative "ffi/runtime"
require_relative "ffi/function_result"
require_relative "ffi/function_result_stream"

module Baml
  module Ffi
    Bindings.load_library!
    Callbacks.register!
  end
end
