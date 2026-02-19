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
    class ClientRegistry; end

    # Aliased as Baml::Image. Referenced in generated type signatures.
    class Image; end

    # Aliased as Baml::Audio. Referenced in generated type signatures.
    class Audio; end

    # Aliased as Baml::Collector. Wrapped in an array by the generated resolve()
    # helper before passing to call_function / stream_function.
    class Collector; end

    # Referenced in the generated type_builder.rb as Baml::Ffi::TypeBuilder.
    # Full dynamic type-builder support will be wired to CFFI in a later phase.
    # method_missing raises NotImplementedError per locked decision.
    class TypeBuilder
      def method_missing(method_name, *args, **kwargs, &block)
        raise NotImplementedError, "#{self.class}##{method_name} is not yet implemented"
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end
    end

    # Returned by TypeBuilder methods (string, int, list, union, …) and accepted
    # by ClassBuilder#type, EnumBuilder#type, etc.
    # method_missing raises NotImplementedError per locked decision.
    class FieldType
      def method_missing(method_name, *args, **kwargs, &block)
        raise NotImplementedError, "#{self.class}##{method_name} is not yet implemented"
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end
    end

    # Returned by TypeBuilder#class_(name). Generated code calls
    # ClassBuilder#field and ClassBuilder#property(name).type(field_type).
    # method_missing raises NotImplementedError per locked decision.
    class ClassBuilder
      def method_missing(method_name, *args, **kwargs, &block)
        raise NotImplementedError, "#{self.class}##{method_name} is not yet implemented"
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end
    end

    # Returned by TypeBuilder#enum(name). Generated code calls
    # EnumBuilder#field and EnumBuilder#value(name).
    # method_missing raises NotImplementedError per locked decision.
    class EnumBuilder
      def method_missing(method_name, *args, **kwargs, &block)
        raise NotImplementedError, "#{self.class}##{method_name} is not yet implemented"
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end
    end
  end
end
