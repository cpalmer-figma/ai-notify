require "open3"
require "shellwords"
require "rubygems/package"
require "stringio"
require_relative "workspace_discovery"
require_relative "token_store"

module CoderNotify
  # Explicit, opt-in installation on one workspace. Discovery never invokes this.
  class WorkspaceSetup
    class Error < StandardError; end

    FILES = {
      "install.sh" => "install.sh",
      "bin/coder-notify-remote" => "bin/coder-notify-remote",
      "tmux/coder-notify.tmux.conf" => "coder-notify.tmux.conf",
      "claude/settings.hooks.json" => "claude-hooks.json",
      "codex/hooks.json" => "codex-hooks.json",
      "merge-hooks.jq" => "merge-hooks.jq",
      "remove-hooks.jq" => "remove-hooks.jq"
    }.freeze

    # No credentials in commands, process arguments, stdout or temporary local files.
    INSTALL_COMMAND = <<~SH.strip.freeze
      set -eu
      umask 077
      stage=$(mktemp -d "${TMPDIR:-/tmp}/coder-notify-setup.XXXXXXXX")
      trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
      tar -xf - -C "$stage"
      bash "$stage/install.sh"
    SH

    def initialize(config:, root:, discovery: nil, runner: SetupRunner.new, output: $stdout)
      @config, @root, @runner, @output = config, root, runner, output
      @discovery = discovery || WorkspaceDiscovery.new(coder_bin: config.coder_bin)
      @tokens = TokenStore.new(path: config.tokens_path)
    end

    def call(name, agent: "both", install_deps: false)
      raise Error, "agent must be claude, codex or both" unless %w[claude codex both].include?(agent)
      result = @discovery.call
      raise Error, result.error unless result.ok?
      workspace = result.workspaces.find { |ws| ws.name == name }
      raise Error, "no workspace named #{name.inspect}" unless workspace
      raise Error, "#{name} is #{workspace.state}; start it yourself before setup" unless workspace.running?
      raise Error, "#{name} has no main agent" unless workspace.agent_name

      @output.puts "Checking #{workspace.name} (#{workspace.agent_name})…"
      args = Shellwords.join([workspace.name, agent, install_deps ? "install-deps" : "check-only"])
      checked = @runner.call(command(workspace, "sh -s -- #{args}"),
                             input: File.read(File.join(@root, "remote/preflight.sh")), timeout: 300)
      raise Error, "remote preflight failed: #{checked.stderr.strip}" unless checked.status.zero?
      @output.print checked.stdout

      # Preflight validates dependencies and existing configs before enabling any tunnel.
      existing = @tokens.entries.find { |item| item.workspace_id == workspace.id }
      entry = TokenStore::Entry.new(
        workspace_id: workspace.id, workspace_name: workspace.name,
        token: existing&.token || SecureRandom.hex(32), created_at: existing&.created_at || Time.now.utc.iso8601
      )
      installed = @runner.call(command(workspace, "sh -c #{Shellwords.escape(INSTALL_COMMAND)}"),
                                input: archive(entry, agent), timeout: 120)
      # Defensive redaction even if a remote command unexpectedly echoes its environment.
      @output.print installed.stdout.gsub(entry.token, "[redacted]")
      unless installed.status.zero?
        raise Error, "remote installation failed: #{installed.stderr.gsub(entry.token, '[redacted]').strip}"
      end
      # Start monitoring only after all remote files exist, avoiding startup/backoff races.
      entry = @tokens.enable(workspace, token: entry.token)
      @output.puts "Enabled #{workspace.name}. Keep the Mac app running; its tunnel will connect automatically."
      @output.puts "Open a new shell, restart existing agent sessions, and reattach tmux once to activate the hooks."
      @output.puts "Codex: open /hooks once to review and trust the coder-notify entries." if %w[both codex].include?(agent)
      entry
    end

    private

    def command(workspace, remote_command)
      [@config.coder_bin, "ssh", "--disable-autostart", "--wait=no", "--usage-app=disable",
       workspace.ssh_target, "--", remote_command]
    end

    def archive(entry, agent)
      io = StringIO.new("".b)
      Gem::Package::TarWriter.new(io) do |tar|
        FILES.each do |source, destination|
          contents = File.binread(File.join(@root, "remote", source))
          tar.add_file_simple(destination, 0o600, contents.bytesize) { |file| file.write(contents) }
        end
        env = "CODER_NOTIFY_URL=http://127.0.0.1:#{@config.remote_port}\nCODER_NOTIFY_TOKEN=#{entry.token}\n"
        { "env" => env, "agent" => agent, "workspace" => entry.workspace_name }.each do |path, contents|
          tar.add_file_simple(path, 0o600, contents.bytesize) { |file| file.write(contents) }
        end
      end
      io.string
    end
  end

  # Reads both output pipes while uploading stdin; bounds time spent in SSH.
  class SetupRunner
    Result = Data.define(:stdout, :stderr, :status)

    def call(argv, input:, timeout:)
      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, waiter|
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        writer = Thread.new do
          begin
            stdin.write(input)
          rescue Errno::EPIPE
            # A failed preflight may exit without consuming the entire upload.
          ensure
            stdin.close
          end
        end
        unless waiter.join(timeout)
          Process.kill("TERM", -waiter.pid) rescue nil
          Process.kill("KILL", -waiter.pid) unless waiter.join(2)
          waiter.join
          return Result.new(stdout: "", stderr: "SSH timed out after #{timeout}s", status: 124)
        end
        writer.join
        Result.new(stdout: readers[0].value, stderr: readers[1].value, status: waiter.value.exitstatus || 1)
      end
    rescue Errno::ENOENT
      raise WorkspaceSetup::Error, "Coder CLI not found: #{argv.first}"
    end
  end
end
