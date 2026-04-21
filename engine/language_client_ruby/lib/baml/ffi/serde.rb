# frozen_string_literal: true

require "baml/cffi/v1/baml_inbound_pb"
require "baml/cffi/v1/baml_outbound_pb"
require "baml/cffi/v1/baml_object_methods_pb"

module Baml
  module Ffi
    module Serde
      Proto = Baml::Cffi::V1

      STREAM_STATE_NAMES = {
        PENDING: "Pending",
        STARTED: "Incomplete",
        DONE: "Complete",
      }.freeze

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

      def encode_function_args(kwargs, env_vars: {}, type_builder: nil, client_registry: nil, collectors: [], tags: {})
        entries = kwargs.map do |key, val|
          Proto::HostMapEntry.new(string_key: key.to_s, value: encode_value(val))
        end
        env = env_vars.map { |k, v| Proto::HostEnvVar.new(key: k.to_s, value: v.to_s) }
        tb_handle = type_builder&.encode_handle
        cr_proto = client_registry&.encode_proto
        collector_handles = collectors.map(&:encode_handle)
        tag_entries = tags.map do |k, v|
          Proto::HostMapEntry.new(string_key: k.to_s, value: Proto::HostValue.new(string_value: v.to_s))
        end
        Proto::HostFunctionArguments.new(
          kwargs: entries, env: env, type_builder: tb_handle,
          client_registry: cr_proto, collectors: collector_handles, tags: tag_entries
        )
      end

      def decode_value(holder)
        case holder.value
        when :string_value then holder.string_value
        when :int_value then holder.int_value
        when :float_value then holder.float_value
        when :bool_value then holder.bool_value
        when :null_value then nil
        when :list_value then holder.list_value.items.map { |v| decode_value(v) }
        when :map_value then decode_map(holder.map_value)
        when :class_value then decode_class(holder.class_value)
        when :enum_value then decode_enum(holder.enum_value)
        when :union_variant_value then decode_value(holder.union_variant_value.value)
        when :checked_value then decode_checked(holder.checked_value)
        when :literal_value then decode_literal(holder.literal_value)
        when :streaming_state_value then decode_streaming_state(holder.streaming_state_value)
        when :object_value then nil
        else raise ArgumentError, "unsupported BAML decode type: #{holder.value}"
        end
      end

      def decode_map(map)
        map.entries.each_with_object({}) do |entry, hash|
          hash[entry.key] = decode_value(entry.value)
        end
      end

      def decode_class(cls)
        fields = cls.fields.each_with_object({}) do |entry, hash|
          hash[entry.key] = decode_value(entry.value)
        end
        { "__baml_class__" => cls.name.name, **fields }
      end

      def decode_enum(enum)
        { "__baml_enum__" => enum.name.name, "value" => enum.value }
      end

      def decode_checked(cv)
        checks = cv.checks.each_with_object({}) do |check, hash|
          hash[check.name.to_sym] = {
            "__baml_class__" => "Check",
            "name" => check.name,
            "expr" => check.expression,
            "status" => check.status,
          }
        end
        { "__baml_class__" => "Checked", "value" => decode_value(cv.value), "checks" => checks }
      end

      def decode_literal(lit)
        case lit.literal
        when :string_literal then lit.string_literal.value
        when :int_literal then lit.int_literal.value
        when :bool_literal then lit.bool_literal.value
        else raise ArgumentError, "unexpected literal variant: #{lit.literal}"
        end
      end

      def decode_streaming_state(ss)
        state = STREAM_STATE_NAMES[ss.state] || ss.state.to_s
        { "__baml_class__" => "StreamState", "value" => decode_value(ss.value), "state" => state }
      end

      def decode_value_holder(bytes)
        holder = Proto::CFFIValueHolder.decode(bytes)
        decode_value(holder)
      end

      # Recursively coerce decoded values into T::Struct instances.
      # Hashes with "__baml_class__" become struct instances looked up in types_module.
      # Unknown classes (created dynamically via TypeBuilder) become DynamicStruct.
      # Plain hashes, arrays, and primitives pass through.
      def coerce_to_struct(value, types_module)
        case value
        when Hash
          if (class_name = value["__baml_class__"])
            coerce_class_hash(class_name, value, types_module)
          elsif (enum_name = value["__baml_enum__"])
            coerce_enum(enum_name, value["value"], types_module)
          else
            value.transform_values { |v| coerce_to_struct(v, types_module) }
          end
        when Array
          value.map { |v| coerce_to_struct(v, types_module) }
        else
          value
        end
      end

      # Coerce a hash with "__baml_class__" into a typed struct or DynamicStruct.
      def coerce_class_hash(class_name, value, types_module)
        klass = types_module&.const_defined?(class_name, false) &&
                types_module.const_get(class_name, false)

        if klass.is_a?(Class) && klass < T::Struct
          build_struct(klass, value, types_module)
        elsif klass
          value
        else
          build_dynamic_struct(value, types_module)
        end
      end

      def build_struct(klass, value, types_module)
        props = klass.props
        kwargs = {}
        value.each do |k, v|
          next if k == "__baml_class__"
          sym = k.to_sym
          # When a prop references a class from a different module (e.g.
          # StreamTypes prop typed as Types::Foo), coerce using that module.
          nested_module = enclosing_module(props.dig(sym, :type)) || types_module
          kwargs[sym] = coerce_to_struct(v, nested_module)
        end
        known_kwargs = kwargs.select { |k, _| props.key?(k) }
        instance = klass.new(**known_kwargs)
        instance.instance_variable_set(:@props, kwargs)
        instance
      end

      def build_dynamic_struct(value, types_module)
        kwargs = {}
        value.each do |k, v|
          next if k == "__baml_class__"
          kwargs[k.to_sym] = coerce_to_struct(v, types_module)
        end
        Baml::DynamicStruct.new(**kwargs)
      end

      # Returns the enclosing module of a T::Struct class, or nil.
      # Used to resolve cross-module type references during coercion.
      def enclosing_module(type)
        return nil unless type.is_a?(Class) && type < T::Struct
        parts = type.name&.split("::")
        return nil unless parts && parts.length > 1
        Object.const_get(parts[0..-2].join("::"))
      rescue NameError
        nil
      end

      def coerce_enum(enum_name, value, types_module)
        klass = types_module&.const_defined?(enum_name, false) &&
                types_module.const_get(enum_name, false)
        return value unless klass.is_a?(Class) && klass < T::Enum

        klass.deserialize(value)
      rescue KeyError, RuntimeError
        # KeyError: dynamic value not in enum's serialization map
        # RuntimeError: empty T::Enum (no `enums do` block, e.g. dynamic-only enums)
        value
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
