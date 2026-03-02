# BAML Ruby Integration Tests

Install [`mise`](https://mise.jdx.dev/getting-started.html) to manage ruby
installations.

## Setup

The gem auto-discovers the CFFI shared library (`libbaml_cffi.so`) and will
download a matching release binary automatically. For local dev, build it
and point Ruby at your build:

```bash
cd ../../engine
cargo build -p baml_cffi
cd ../integ-tests/ruby
```

```bash
export BAML_LIBRARY_PATH="../../engine/target/debug/libbaml_cffi.so"
```

## Running Tests

In this directory (integ-tests/ruby)

Install deps
```bash
mise exec -- bundle install
```

Generate the BAML client code:
```bash
mise exec -- rake generate
```

### Run all tests
```bash
infisical run --env=test -- mise exec -- rake test
```

### Run specific tests
```bash
# Run a specific test file
infisical run --env=test -- mise exec -- ruby test_functions.rb

# Run a specific test
infisical run --env=test -- mise exec -- rake test test_collector.rb TEST_OPTS="--name=/test_collector_no_stream_success/ -v"
```

### Environment Variables
- Tests can be run with environment variables using `infisical` (default)
```bash
infisical run --env=test -- mise exec -- rake test
```

- Alternatively, you can use a .env file with dotenv:
```bash
mise exec -- rake test
```

## Project Structure

- `baml_client/` - Generated BAML client code
- `test_functions.rb` - Main test file
- `streaming-example.rb` - Streaming functionality examples
- `tracing-demo1.rb` - Tracing functionality examples
- `Gemfile` - Ruby dependencies
- `Rakefile` - Test and build tasks

## Debugging Tests
### Debug Logs
- Add `puts` statements in your tests
- Set the environment variable `BAML_LOG=trace` for detailed BAML client logs:
```bash
BAML_LOG=trace infisical run --env=test -- mise exec -- rake test
```

## Troubleshooting

### Common Issues

1. **Missing API Keys**
   - Ensure all required API keys are set in your environment
   - Check that `.env` file exists if not using Infisical
   - Verify Infisical is properly configured if using `infisical run`

2. **Build Issues**
   - If you get Rust compilation errors:
     ```bash
     # Clean and rebuild the CFFI library
     (cd ../../engine && cargo clean -p baml_cffi && cargo build -p baml_cffi)
     ```
   - For Bundler issues:
     ```bash
     mise exec -- bundle install --clean
     ```

3. **Ruby Version Issues**
   - Ensure mise is properly set up:
     ```bash
     mise install
     mise exec -- ruby --version
     ```
   - If mise isn't picking up the right version:
     ```bash
     mise trust
     mise install
     ```

4. **BAML Client Generation Issues**
   - Check that BAML source files in `../baml_src` are valid
   - Try regenerating the client:
     ```bash
     rm -rf baml_client
     mise exec -- rake generate
     ```

5. **Test Load Path Issues**
   - If tests can't find files, ensure you're running from the correct directory
   - Try running with full paths:
     ```bash
     mise exec -- ruby -I. test_functions.rb
     ```

### Getting Help
- Run tests with verbose output:
  ```bash
  infisical run --env=test -- mise exec -- rake test TESTOPTS="--verbose"
  ```
- Use Ruby's debug mode:
  ```bash
  infisical run --env=test -- mise exec -- ruby -rdebug test_functions.rb
  ```
- Check the test output for error backtraces and assertion details
