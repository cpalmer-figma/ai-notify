require "json"
require "fileutils"

module CoderNotify
  # Tiny helper for reading and writing the JSON files we persist.
  #
  # Writes are atomic: we write to a temporary file and then rename it over
  # the real one, so a crash mid-write can never leave a half-written file.
  module JsonFile
    module_function

    # Returns the parsed JSON, or +default+ if the file is missing or corrupt.
    def read(path, default)
      return default unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      default
    end

    # Writes +data+ as pretty JSON, readable only by the current user.
    def write(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, JSON.pretty_generate(data) + "\n", perm: 0o600)
      File.rename(tmp, path)
    end
  end
end
