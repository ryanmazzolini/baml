# frozen_string_literal: true

require "rbconfig"
require "net/http"
require "uri"
require "digest/sha2"
require "fileutils"
require "tempfile"

module Baml
  module Ffi
    # Library discovery and platform detection.
    # Mirrors: language_client_go/baml_go/lib_common.go — findOrDownloadLibrary, getTargetLibFilename
    module Library
      VERSION = "0.221.0"
      GITHUB_REPO = "boundaryml/baml"

      module_function

      # Discovery cascade (mirrors Go's findOrDownloadLibrary):
      #   1. BAML_LIBRARY_PATH env var
      #   2. Cache dir: platform-correct cache/baml/libs/{VERSION}/{platform-filename}
      #   3. Auto-download from GitHub releases with SHA256 verification
      #   4. System path fallback (/usr/local/lib/...)
      #   5. Error with actionable message listing all steps tried
      def find
        # 1. Explicit env var
        if (env_path = ENV["BAML_LIBRARY_PATH"])
          return env_path if File.exist?(env_path)
          raise LoadError, "BAML_LIBRARY_PATH=#{env_path} does not exist"
        end

        # 2. Cache dir
        filename = target_lib_filename
        dir = cache_dir
        cached_path = File.join(dir, filename)
        return cached_path if File.exist?(cached_path)

        # 3. Auto-download (unless disabled)
        download_disabled = ENV["BAML_LIBRARY_DISABLE_DOWNLOAD"].to_s.downcase == "true" ||
                            ENV["BAML_NO_AUTO_DOWNLOAD"].to_s.downcase == "true"
        download_attempted = false
        download_error = nil

        unless download_disabled
          download_attempted = true
          begin
            download_library(dir, filename)
            return cached_path if File.exist?(cached_path)
          rescue => e
            download_error = e
          end
        end

        # 4. System path fallback (matches Go: findOrDownloadLibrary lines 307-351)
        system_paths_checked = system_paths
        system_paths_checked.each { |p| return p if File.exist?(p) }

        # 5. Actionable error listing all steps tried
        download_status = if download_disabled
                            "Disabled via BAML_LIBRARY_DISABLE_DOWNLOAD/BAML_NO_AUTO_DOWNLOAD"
                          elsif download_attempted && download_error
                            "Attempted but failed: #{download_error.message}"
                          elsif download_attempted
                            "Attempted (library not present after download)"
                          else
                            "Not attempted"
                          end

        raise LoadError, <<~MSG.strip
          baml: failed loading shared library: could not find BAML library v#{VERSION} for #{host_os}/#{host_arch}.
          Resolution attempts failed:
            - Environment var (BAML_LIBRARY_PATH): Not set
            - Cache path: #{cached_path} (not found)
            - Download (BAML_LIBRARY_DISABLE_DOWNLOAD): #{download_status}
            - Default system paths: #{system_paths_checked.inspect} (not found)
          To resolve:
            - Set BAML_LIBRARY_PATH to the .so/.dylib path
            - Place the library at: #{cached_path}
            - Download from: https://github.com/#{GITHUB_REPO}/releases/tag/#{VERSION}
        MSG
      end

      def target_lib_filename
        case host_os
        when "linux"   then "libbaml_cffi-#{host_arch}-unknown-linux-gnu.so"
        when "darwin"  then "libbaml_cffi-#{host_arch}-apple-darwin.dylib"
        when "windows" then "baml_cffi-#{host_arch}-pc-windows-msvc.dll"
        else raise LoadError, "Unsupported OS: #{host_os}"
        end
        # TODO: detect musl libc (matches Go's isMusl() TODO)
      end

      def host_os
        case RbConfig::CONFIG["host_os"]
        when /linux/i  then "linux"
        when /darwin/i then "darwin"
        when /mswin|mingw|cygwin/i then "windows"
        else RbConfig::CONFIG["host_os"]
        end
      end

      def host_arch
        case RbConfig::CONFIG["host_cpu"]
        when /x86_64|amd64/i  then "x86_64"
        when /aarch64|arm64/i then "aarch64"
        else raise LoadError, "Unsupported architecture: #{RbConfig::CONFIG["host_cpu"]}"
        end
      end

      # Platform-correct cache directory.
      # Windows: %LOCALAPPDATA%\baml\libs\{VERSION}
      # macOS:   ~/Library/Caches/baml/libs/{VERSION}
      # Linux:   $XDG_CACHE_HOME/baml/libs/{VERSION} or ~/.cache/baml/libs/{VERSION}
      # Mirrors: Go's getCacheDir() which calls os.UserCacheDir()
      def cache_dir
        base = ENV["BAML_CACHE_DIR"]
        unless base
          base = case host_os
                 when "darwin"  then File.join(Dir.home, "Library", "Caches")
                 when "windows" then ENV["LOCALAPPDATA"] || File.join(Dir.home, "AppData", "Local")
                 else ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache")
                 end
        end
        File.join(base, "baml", "libs", VERSION)
      end

      # System path fallback (matches Go: findOrDownloadLibrary lines 307-351).
      def system_paths
        case host_os
        when "darwin"
          ["/usr/local/lib/libbaml-#{VERSION}.dylib", "/usr/local/lib/libbaml.dylib"]
        when "linux"
          ["/usr/local/lib/libbaml-#{VERSION}.so", "/usr/local/lib/libbaml.so"]
        when "windows"
          program_files = ENV["ProgramFiles"] || ""
          local_app_data = ENV["LOCALAPPDATA"] || ""
          [
            File.join(program_files, "baml", "baml_cffi-#{VERSION}.dll"),
            File.join(program_files, "baml", "baml_cffi.dll"),
            File.join(local_app_data, "baml", "baml_cffi-#{VERSION}.dll"),
            File.join(local_app_data, "baml", "baml_cffi.dll"),
          ].reject { |p| p.start_with?("/baml") }  # Skip if env var was empty
        else
          []
        end
      end

      # Download library from GitHub releases with SHA256 checksum verification.
      # Mirrors: Go's downloadBamlLibrary(destDir, filename).
      #
      # - Creates dest_dir with mkdir_p
      # - Downloads checksum file first; proceeds without verification if unavailable (matches Go)
      # - Streams download to tempfile while computing SHA256
      # - Verifies checksum if available; deletes tempfile on mismatch
      # - Atomic rename (falls back to copy+delete for cross-device moves)
      # - Sets 0755 permissions on final file
      # - Follows redirects (GitHub releases -> CDN); max 10 hops
      def download_library(dest_dir, filename)
        tag = VERSION
        download_url = "https://github.com/#{GITHUB_REPO}/releases/download/#{tag}/#{filename}"
        checksum_url = "https://github.com/#{GITHUB_REPO}/releases/download/#{tag}/#{filename}.sha256"
        dest_path = File.join(dest_dir, filename)

        FileUtils.mkdir_p(dest_dir)

        # Fetch checksum (best-effort; proceed without if unavailable)
        expected_checksum = fetch_checksum(checksum_url, filename)

        # Download library to tempfile, computing SHA256 inline
        tmp = Tempfile.new([filename, ".tmpdl"], dest_dir, binmode: true)
        begin
          hasher = Digest::SHA256.new
          fetch_url(download_url) do |chunk|
            tmp.write(chunk)
            hasher.update(chunk)
          end
          tmp.close

          actual_checksum = hasher.hexdigest
          if expected_checksum && !expected_checksum.empty?
            if actual_checksum != expected_checksum
              raise LoadError,
                "baml: downloaded library checksum mismatch: " \
                "expected #{expected_checksum}, got #{actual_checksum}. " \
                "File #{tmp.path} may be corrupt."
            end
          end

          # Atomic rename (fallback to copy on cross-device)
          begin
            File.rename(tmp.path, dest_path)
          rescue Errno::EXDEV
            FileUtils.cp(tmp.path, dest_path)
          end

          FileUtils.chmod(0755, dest_path)
        rescue => e
          tmp.close
          tmp.unlink rescue nil
          raise e
        ensure
          tmp.close rescue nil
          # Unlink temp only if rename succeeded (dest_path exists and tmp path differs)
          tmp.unlink rescue nil
        end

        dest_path
      end

      private

      module_function

      # Fetch checksum file and parse out the hex digest for the given filename.
      # Returns nil if the checksum file is unavailable (404 or network error).
      # Format: "<sha256hex>  <filename>" or "<sha256hex> *<filename>"
      def fetch_checksum(url, filename)
        body = fetch_url_body(url)
        return nil unless body

        # Find the line matching our filename
        body.lines.each do |line|
          hex, name = line.strip.split(/\s+\*?/, 2)
          return hex if name == filename && hex =~ /\A[0-9a-f]{64}\z/i
        end
        nil
      rescue => _e
        nil
      end

      # Fetch URL body as a string (follows redirects, max 10 hops).
      # Returns nil on 404; raises on other errors.
      def fetch_url_body(url)
        result = ""
        fetch_url(url) { |chunk| result << chunk }
        result
      rescue LoadError => e
        return nil if e.message.include?("HTTP 404")
        raise
      end

      # Fetch URL, yielding response body chunks. Follows redirects up to max_redirects.
      # Sets User-Agent header. Raises LoadError on non-200/redirect responses.
      def fetch_url(url, max_redirects: 10, &block)
        hops = 0
        current_url = url

        loop do
          raise LoadError, "baml: too many redirects fetching #{url}" if hops > max_redirects

          uri = URI.parse(current_url)
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                          open_timeout: 30, read_timeout: 300) do |http|
            req = Net::HTTP::Get.new(uri.request_uri)
            req["User-Agent"] = "baml-ruby/#{VERSION} (#{host_os}/#{host_arch})"

            http.request(req) do |resp|
              case resp
              when Net::HTTPSuccess
                resp.read_body(&block)
                return
              when Net::HTTPRedirection
                current_url = resp["Location"]
                hops += 1
              when Net::HTTPNotFound
                raise LoadError, "baml: library file not found at #{current_url} (HTTP 404)"
              else
                raise LoadError, "baml: unexpected HTTP #{resp.code} fetching #{current_url}"
              end
            end
          end
        end
      end
    end
  end
end
