require "json"
require "open3"
require_relative "workspace"

module CoderNotify
  # Runs `coder list --output json` and turns the output into Workspace
  # objects. It never raises: failures come back as a Result with an error
  # message, so the caller can keep showing the last known list.
  class WorkspaceDiscovery
    Result = Data.define(:workspaces, :error) do
      def ok? = error.nil?
    end

    # +runner+ is anything that responds to call(argv, timeout:) and returns
    # [stdout, success?, stderr]. Tests pass a fake; production uses
    # CommandRunner below.
    def initialize(coder_bin: "coder", runner: CommandRunner.new, timeout: 30)
      @coder_bin = coder_bin
      @runner = runner
      @timeout = timeout
    end

    def call
      stdout, success, stderr = @runner.call([@coder_bin, "list", "--output", "json"], timeout: @timeout)
      return failure("coder list failed: #{last_line(stderr)}") unless success

      parse(stdout)
    rescue Errno::ENOENT
      failure("coder CLI not found (#{@coder_bin}); set CODER_BIN to its full path")
    end

    def parse(json)
      list = JSON.parse(json)
      return failure("coder list returned unexpected JSON (not an array)") unless list.is_a?(Array)

      Result.new(workspaces: list.map { |hash| Workspace.from_coder_json(hash) }, error: nil)
    rescue JSON::ParserError, KeyError => e
      failure("could not parse coder list output: #{e.message}")
    end

    private

    def failure(message) = Result.new(workspaces: nil, error: message)

    # The Coder CLI prints its most useful message (e.g. "error: You are not
    # logged in...") on the last line of stderr.
    def last_line(text)
      text.to_s.lines.map(&:strip).reject(&:empty?).last || "no error output"
    end
  end

  # Runs a command with a timeout and captures its output. Separated out so
  # discovery can be tested without running a real process.
  class CommandRunner
    def call(argv, timeout:)
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        # Read both pipes in threads so a chatty process can't block on a
        # full pipe buffer while we wait for it.
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }

        if wait_thread.join(timeout).nil?
          Process.kill("TERM", wait_thread.pid)
          wait_thread.join
          return ["", false, "timed out after #{timeout}s"]
        end

        [out_reader.value, wait_thread.value.success?, err_reader.value]
      end
    end
  end
end
