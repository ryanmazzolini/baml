require_relative "baml/ffi"
require_relative "stream"
require_relative "struct"
require_relative "checked"

module Baml
  ClientRegistry = Baml::Ffi::ClientRegistry
  Image = Baml::Ffi::Image
  Audio = Baml::Ffi::Audio
  Collector = Baml::Ffi::Collector

  # Reexport Checked types.
  Checked = Baml::Checks::Checked
  Check = Baml::Checks::Check

  # Convenience accessor: Baml.Client returns the singleton BamlSyncClient from
  # the generated BamlClient module. Delegating dynamically so baml.rb does not
  # need a direct reference to BamlClient (which lives in generated code).
  def self.Client
    ::BamlClient.b
  end

  # Lazy accessors for generated BamlClient constants.
  # These delegate to BamlClient::{Foo} so that baml.rb does not hard-depend
  # on generated code. By the time these are referenced, the caller has already
  # required the baml_client which defines the BamlClient module.
  #
  # Supported:
  #   Baml::TypeBuilder -> BamlClient::TypeBuilder
  #   Baml::Types       -> BamlClient::Types
  def self.const_missing(name)
    baml_client_name = "BamlClient::#{name}"
    if ::Object.const_defined?(baml_client_name)
      ::Object.const_get(baml_client_name)
    else
      super
    end
  end


  # Dynamically + idempotently define Baml::TypeConverter
  # NB: this does not respect raise_coercion_error = false
  def self.convert_to(type)
    if !Baml.const_defined?(:TypeConverter)
      Baml.const_set(:TypeConverter, Class.new(TypeCoerce::Converter) do
        def initialize(type)
          super(type)
        end
        
        def _convert(value, type, raise_coercion_error, coerce_empty_to_nil)
          # make string handling more strict
          if type == String
            if value.is_a?(String)
              return value
            end

            raise TypeCoerce::CoercionError.new(value, type)
          end

          # add unions
          if type.is_a?(T::Types::Union)
            type.types.each do |t|
              # require raise_coercion_error on the recursive union call,
              # so that we can suppress the error if it fails
              converted = _convert(value, t, true, coerce_empty_to_nil)
              return converted
            rescue
              # do nothing - try every instance of the union
            end

            raise TypeCoerce::CoercionError.new(value, type)
          end

          super(value, type, raise_coercion_error, coerce_empty_to_nil)
        end
      end)
    end

    Baml.const_get(:TypeConverter).new(type)
  end
end
