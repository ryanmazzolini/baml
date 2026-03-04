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
        when Baml::Sorbet::Struct
          baml_name = value.class.name.split("::").last
          fields = value.serialize.map do |k, v|
            Proto::HostMapEntry.new(string_key: k.to_s, value: encode_value(v))
          end
          Proto::HostValue.new(class_value: Proto::HostClassValue.new(name: baml_name, fields: fields))
        when Baml::DynamicStruct
          fields = value.to_h.map do |k, v|
            Proto::HostMapEntry.new(string_key: k.to_s, value: encode_value(v))
          end
          Proto::HostValue.new(map_value: Proto::HostMapValue.new(entries: fields))
        when Hash
          entries = value.map do |k, v|
            Proto::HostMapEntry.new(string_key: k.to_s, value: encode_value(v))
          end
          Proto::HostValue.new(map_value: Proto::HostMapValue.new(entries: entries))
        when T::Enum
          Proto::HostValue.new(string_value: value.serialize)
        when Baml::Ffi::RawObject
          Proto::HostValue.new(handle: value.encode_handle)
        else
          raise ArgumentError, "unsupported type for BAML encoding: #{value.class}"
        end
      end

      # Encode a Ruby Hash into an array of HostMapEntry protos.
      # Used by RawObject for constructor/method kwargs.
      def encode_map_entries(kwargs)
        kwargs.map do |k, v|
          Proto::HostMapEntry.new(string_key: k.to_s, value: encode_value(v))
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
        when :union_variant_value
          decode_value(holder.union_variant_value.value)
        when :checked_value
          cv = holder.checked_value
          checks = cv.checks.each_with_object({}) do |check, hash|
            hash[check.name.to_sym] = {
              "__baml_class__" => "Check",
              "name" => check.name,
              "expr" => check.expression,
              "status" => check.status,
            }
          end
          { "__baml_class__" => "Checked", "value" => decode_value(cv.value), "checks" => checks }
        when :literal_value
          lit = holder.literal_value
          case lit.value
          when :string_literal then lit.string_literal.value
          when :int_literal    then lit.int_literal.value
          when :bool_literal   then lit.bool_literal.value
          else lit
          end
        when :streaming_state_value
          ss = holder.streaming_state_value
          { "__baml_class__" => "StreamState", "value" => decode_value(ss.value), "state" => ss.state }
        when :object_value
          nil
        else
          raise ArgumentError, "unsupported BAML decode type: #{holder.value}"
        end
      end

      def decode_value_holder(bytes)
        holder = Proto::CFFIValueHolder.decode(bytes)
        decode_value(holder)
      end

      # Recursively coerce decoded values into T::Struct instances.
      # Hashes with "__baml_class__" become struct instances looked up in types_module.
      # Plain hashes, arrays, and primitives pass through.
      def coerce_to_struct(value, types_module)
        case value
        when Hash
          class_name = value["__baml_class__"]
          if class_name && types_module.const_defined?(class_name, false)
            klass = types_module.const_get(class_name, false)
            if klass < T::Struct
              kwargs = {}
              value.each do |k, v|
                next if k == "__baml_class__"
                kwargs[k.to_sym] = coerce_to_struct(v, types_module)
              end
              klass.new(**kwargs)
            else
              value
            end
          else
            value.transform_values { |v| coerce_to_struct(v, types_module) }
          end
        when Array
          value.map { |v| coerce_to_struct(v, types_module) }
        else
          value
        end
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
