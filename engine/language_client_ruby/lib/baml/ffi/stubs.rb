# frozen_string_literal: true

# Stub classes for types that will eventually be backed by the CFFI Rust library
# but currently need to exist as Ruby classes to satisfy the generated client's
# type references (Sorbet sigs, T.let assignments, etc.).
#
# These are deliberately minimal — just enough to prevent NameError.
# Full implementations belong in dedicated files (e.g. type_builder.rb).

module Baml
  # Referenced by generated globals.rb as Baml::Internal::FILE_MAP.
  # Builds path=>content hash from baml_src directory at runtime.
  # Tries common layouts: baml_src, ../baml_src (for integ-tests).
  module Internal
    def self._build_file_map
      %w[baml_src ../baml_src].each do |cand|
        dir = File.expand_path(cand, Dir.pwd)
        next unless File.directory?(dir)

        return Dir.glob(File.join(dir, "**/*.baml")).each_with_object({}) do |path, hash|
          rel = path.sub("#{dir}/", "")
          hash[rel] = File.read(path)
        end
      end
      {}
    end

    FILE_MAP = _build_file_map.freeze
  end

  module Ffi
    # Returned by BamlRuntime#create_context_manager and passed as the `ctx`
    # argument to call_function / stream_function. The CFFI path ignores it
    # (Rust constructs its own context internally), so an empty class suffices.
    class RuntimeContextManager; end

    # Passed through the generated resolve() helper as client_registry.
    # The CFFI runtime receives it but does not use it for MVP.
    # method_missing raises NotImplementedError for unimplemented methods
    # (e.g. add_llm_client) per locked decision.
    class ClientRegistry
      def method_missing(method_name, *args, **kwargs, &block)
        raise NotImplementedError, "#{self.class}##{method_name} is not yet implemented"
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end
    end


    # TypeBuilder, FieldType, ClassBuilder, EnumBuilder are now real
    # implementations in type_builder.rb (backed by CFFI RawObject handles).
  end
end
