# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "baml"
  spec.version = "0.221.0"
  spec.authors = ["BoundaryML"]
  spec.email = ["contact@boundaryml.com"]

  spec.summary = "Unified BoundaryML LLM client"
  spec.description = "A gem for users to interact with BoundaryML's Language Model clients (LLM) in Ruby via CFFI."
  spec.homepage = "https://github.com/BoundaryML/baml"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir["exe/*", "lib/**/*.rb"]
  spec.bindir = "exe"
  # TODO: make sure this is invoke-able from an installed gem
  spec.executables = ["baml-cli", "baml"]
  spec.require_paths = ["lib"]

  # ffi is required by the CFFI binding path (baml/ffi/bindings.rb).
  spec.add_dependency "ffi", "~> 1.0"
  # google-protobuf is required by the CFFI serde layer (baml/ffi/serde.rb).
  spec.add_dependency "google-protobuf", "~> 4.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
