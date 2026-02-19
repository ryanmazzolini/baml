# frozen_string_literal: true

require "baml/cffi/v1/baml_inbound_pb"
require "baml/cffi/v1/baml_outbound_pb"
require "baml/cffi/v1/baml_object_methods_pb"

module Baml
  module Ffi
    module Serde
      Proto = Baml::Cffi::V1

      module_function

      def encode_value(value)
        case value
        when NilClass    then Proto::HostValue.new
        when String      then Proto::HostValue.new(string_value: value)
        when Integer     then Proto::HostValue.new(int_value: value)
        when Float       then Proto::HostValue.new(float_value: value)
        when true, false then Proto::HostValue.new(bool_value: value)
        when Array
          Proto::HostValue.new(
            list_value: Proto::HostListValue.new(values: value.map { |v| encode_value(v) })
          )
        when Hash
          entries = value.map do |k, v|
            Proto::HostMapEntry.new(string_key: k.to_s, value: encode_value(v))
          end
          Proto::HostValue.new(map_value: Proto::HostMapValue.new(entries: entries))
        when Baml::Ffi::Image, Baml::Ffi::Audio
          # Image/Audio require BamlObjectHandle (CFFI object pointers) which are
          # implemented in a later phase. For now, raise a clear error rather than
          # silently producing wrong results.
          raise NotImplementedError,
            "#{value.class} encoding via CFFI is not yet implemented. " \
            "Image/Audio object handles will be supported in a future phase."
        else
          raise ArgumentError, "unsupported type for BAML encoding: #{value.class}"
        end
      end

      def encode_function_args(kwargs, env_vars: {})
        entries = kwargs.map do |key, val|
          Proto::HostMapEntry.new(string_key: key.to_s, value: encode_value(val))
        end
        env = env_vars.map { |k, v| Proto::HostEnvVar.new(key: k.to_s, value: v.to_s) }
        Proto::HostFunctionArguments.new(kwargs: entries, env: env)
      end

      def decode_value(holder)
        case holder.value
        when :string_value then holder.string_value
        when :int_value    then holder.int_value
        when :float_value  then holder.float_value
        when :bool_value   then holder.bool_value
        when :null_value   then nil
        when :list_value
          holder.list_value.items.map { |v| decode_value(v) }
        when :map_value
          holder.map_value.entries.each_with_object({}) do |entry, hash|
            hash[entry.key] = decode_value(entry.value)
          end
        when :class_value
          fields = holder.class_value.fields.each_with_object({}) do |entry, hash|
            hash[entry.key] = decode_value(entry.value)
          end
          { "__baml_class__" => holder.class_value.name.name, **fields }
        when :enum_value
          holder.enum_value.value
        else
          holder
        end
      end

      def decode_value_holder(bytes)
        holder = Proto::CFFIValueHolder.decode(bytes)
        decode_value(holder)
      end

      # Decode spawn response. Returns nil on success, raises on error.
      def decode_spawn_response(bytes)
        return if bytes.nil? || bytes.empty?

        response = Proto::InvocationResponse.decode(bytes)
        raise BamlError, response.error if response.response == :error
      end
    end
  end
end
