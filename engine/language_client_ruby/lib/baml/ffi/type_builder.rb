# frozen_string_literal: true

require_relative "raw_object"

module Baml
  module Ffi
    # Wraps a Rust-side TypeBuilder (OBJECT_TYPE_BUILDER).
    # Mirrors Go's rawobjects_type_builder.go.
    class TypeBuilder < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_TYPE_BUILDER] = self
      def self.create(runtime_ptr)
        construct(:OBJECT_TYPE_BUILDER, runtime_ptr: runtime_ptr)
      end

      # Primitive types — no kwargs needed, return FieldType
      def string;  call_method("string");  end
      def int;     call_method("int");     end
      def float;   call_method("float");   end
      def bool;    call_method("bool");    end
      def null;    call_method("null");    end

      # Literal types
      def literal_string(value) call_method("literal_string", { "value" => value }) end
      def literal_int(value)    call_method("literal_int",    { "value" => value }) end
      def literal_bool(value)   call_method("literal_bool",   { "value" => value }) end

      # Composite types — args are FieldType (RawObject) handles
      def list(inner)        call_method("list",     { "inner" => inner })          end
      def optional(inner)    call_method("optional", { "inner" => inner })          end
      def map(key, value)    call_method("map",      { "key" => key, "value" => value }) end
      def union(types)       call_method("union",    { "types" => types })          end

      # Class/enum operations — these go through runtime internally
      def class_(name)       call_method("class",      { "name" => name }) end
      def enum_(name)        call_method("enum_",      { "name" => name }) end
      def add_class(name)    call_method("add_class",  { "name" => name }) end
      def add_enum(name)     call_method("add_enum",   { "name" => name }) end
      def list_classes()     call_method("list_classes")                    end
      def list_enums()       call_method("list_enums")                     end

      # Inline BAML schema
      def add_baml(baml)     call_method("add_baml", { "baml" => baml })   end
    end

    # Wraps a Rust-side TypeWrapper (OBJECT_TYPE).
    # Returned by TypeBuilder primitive/composite methods.
    # Mirrors Go's rawobjects_type_def.go.
    class FieldType < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_TYPE] = self
      def list;     call_method("list");     end
      def optional; call_method("optional"); end
    end

    # Wraps a Rust-side ClassBuilder (OBJECT_CLASS_BUILDER).
    # Mirrors Go's rawobjects_class_builder.go.
    class ClassBuilder < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_CLASS_BUILDER] = self
      def name;             call_method("name");                                          end
      def field;            call_method("type_");                                         end
      def property(name)    call_method("property",     { "name" => name })               end
      def add_property(name, field_type)
        call_method("add_property", { "name" => name, "field_type" => field_type })
      end
      def list_properties
        call_method("list_properties")
      end
      def set_description(desc) call_method("set_description", { "description" => desc }); self end
      def set_alias(a)          call_method("set_alias",       { "alias" => a });          self end
      def description()         call_method("description");                                     end
      def alias_()              call_method("alias");                                           end
    end

    # Wraps a Rust-side ClassPropertyBuilder (OBJECT_CLASS_PROPERTY_BUILDER).
    # Chainable setters for builder pattern: property(name).type(ft).description(desc).
    class ClassPropertyBuilder < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_CLASS_PROPERTY_BUILDER] = self
      def name;       call_method("name");                                            end
      def type(ft)    call_method("set_type", { "field_type" => ft });          self   end
      def description(desc) call_method("set_description", { "description" => desc }); self end
      def alias_(a)   call_method("set_alias", { "alias" => a });               self   end
      def get_type()  call_method("type_");                                            end
    end

    # Wraps a Rust-side EnumBuilder (OBJECT_ENUM_BUILDER).
    # Mirrors Go's rawobjects_enum_builder.go.
    class EnumBuilder < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_ENUM_BUILDER] = self
      def name;             call_method("name");                                          end
      def field;            call_method("type_");                                         end
      def value(name)       call_method("value",     { "name" => name })                  end
      def add_value(value)  call_method("add_value", { "value" => value })                end
      def list_values()     call_method("list_values");                                   end
      def set_description(desc) call_method("set_description", { "description" => desc }); self end
      def set_alias(a)          call_method("set_alias",       { "alias" => a });          self end
      def description()         call_method("description");                                     end
      def alias_()              call_method("alias");                                           end
    end

    # Wraps a Rust-side EnumValueBuilder (OBJECT_ENUM_VALUE_BUILDER).
    # Chainable setters: value(name).description(desc).skip(true).
    class EnumValueBuilder < RawObject
      RawObject::WRAPPER_CLASS[:OBJECT_ENUM_VALUE_BUILDER] = self
      def name;              call_method("name");                                            end
      def skip(val = true)   call_method("set_skip", { "skip" => val });              self   end
      def get_skip()         call_method("skip");                                            end
      def description(desc)  call_method("set_description", { "description" => desc }); self end
      def alias_(a)          call_method("set_alias", { "alias" => a });                self end
    end
  end
end
