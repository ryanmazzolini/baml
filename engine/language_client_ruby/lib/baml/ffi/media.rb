# frozen_string_literal: true

module Baml
  module Ffi
    # Base class for CFFI-backed media types (Image, Audio, Pdf, Video).
    # Each subclass registers its object type in RawObject::WRAPPER_CLASS
    # and provides from_url / from_base64 factory methods.
    #
    # Canonical construction is via BamlRuntime methods (e.g. runtime.new_image).
    # The class-level from_url/from_base64 are backwards-compat facades that
    # delegate to the registered default runtime. These may be deprecated in
    # favor of the explicit runtime methods in a future release.
    class MediaObject < RawObject
      class << self
        # Subclasses must override to return their BamlObjectType symbol.
        def object_type
          raise NotImplementedError, "#{name} must define .object_type"
        end

        # Canonical factory: construct via an explicit runtime pointer.
        # Also the path the runtime helpers (BamlRuntime#new_image, etc.) use.
        def create(runtime_ptr, **kwargs)
          construct(object_type, runtime_ptr: runtime_ptr, kwargs: kwargs)
        end

        # Backwards-compat facade: delegates to the registered default runtime.
        def from_url(url, mime_type: nil)
          kwargs = { url: url }
          kwargs[:mime_type] = mime_type if mime_type
          create(Baml::Ffi.default_runtime_ptr!, **kwargs)
        end

        def from_base64(base64, mime_type: nil)
          kwargs = { base64: base64 }
          kwargs[:mime_type] = mime_type if mime_type
          create(Baml::Ffi.default_runtime_ptr!, **kwargs)
        end
      end
    end

    class Image < MediaObject
      RawObject::WRAPPER_CLASS[:OBJECT_MEDIA_IMAGE] = self
      def self.object_type = :OBJECT_MEDIA_IMAGE
    end

    class Audio < MediaObject
      RawObject::WRAPPER_CLASS[:OBJECT_MEDIA_AUDIO] = self
      def self.object_type = :OBJECT_MEDIA_AUDIO
    end

    class Pdf < MediaObject
      RawObject::WRAPPER_CLASS[:OBJECT_MEDIA_PDF] = self
      def self.object_type = :OBJECT_MEDIA_PDF
    end

    class Video < MediaObject
      RawObject::WRAPPER_CLASS[:OBJECT_MEDIA_VIDEO] = self
      def self.object_type = :OBJECT_MEDIA_VIDEO
    end
  end
end