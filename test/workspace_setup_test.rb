require_relative "test_helper"
require_relative "../lib/coder_notify/workspace_setup"
require "stringio"

class WorkspaceSetupTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  class Runner
    attr_reader :calls
    attr_accessor :fail_at
    def initialize
      @calls = []
    end
    def call(argv, input:, timeout:)
      @calls << { argv: argv, input: input, timeout: timeout }
      CoderNotify::SetupRunner::Result.new(stdout: "checked\n", stderr: "test failure",
                                           status: calls.size == fail_at ? 1 : 0)
    end
  end

  def setup
    @config = CoderNotify::Config.new("CODER_NOTIFY_HOME" => tmpdir)
    @config.ensure_home!
    @runner = Runner.new
    @output = StringIO.new
    @discovery = FakeDiscovery.new
    @discovery.result = CoderNotify::WorkspaceDiscovery::Result.new(workspaces: [workspace], error: nil)
    @installer = CoderNotify::WorkspaceSetup.new(config: @config, root: ROOT, discovery: @discovery,
                                                runner: @runner, output: @output)
  end

  def tokens = CoderNotify::TokenStore.new(path: @config.tokens_path)

  def archive_files
    files = {}
    Gem::Package::TarReader.new(StringIO.new(@runner.calls.last[:input])) do |tar|
      tar.each { |entry| files[entry.full_name] = entry.read }
    end
    files
  end

  def test_setup_uses_main_agent_and_never_autostarts_or_leaks_token
    entry = @installer.call("alpha")
    @runner.calls.each do |call|
      assert_includes call[:argv], "--disable-autostart"
      assert_includes call[:argv], "alpha.workspace"
      refute_includes call[:argv].join(" "), entry.token
    end
    assert_includes archive_files["env"], entry.token
    assert_equal "both", archive_files["agent"]
    assert_equal File.read(File.join(ROOT, "remote/install.sh")), archive_files["install.sh"]
    refute_includes @output.string, entry.token
  end

  def test_stopped_unreachable_and_unknown_workspaces_do_not_connect_or_enable
    [workspace(build_status: "stopped"), workspace(agent_status: "timeout")].each do |ws|
      @discovery.result = CoderNotify::WorkspaceDiscovery::Result.new(workspaces: [ws], error: nil)
      assert_raises(CoderNotify::WorkspaceSetup::Error) { @installer.call("alpha") }
    end
    assert_raises(CoderNotify::WorkspaceSetup::Error) { @installer.call("missing") }
    assert_empty @runner.calls
    assert_empty tokens.entries
  end

  def test_preflight_failure_creates_no_token
    @runner.fail_at = 1
    assert_raises(CoderNotify::WorkspaceSetup::Error) { @installer.call("alpha") }
    assert_empty tokens.entries
    assert_equal 1, @runner.calls.size
  end

  def test_failed_install_does_not_enable_new_token_or_change_existing_token
    @runner.fail_at = 2
    assert_raises(CoderNotify::WorkspaceSetup::Error) { @installer.call("alpha") }
    assert_empty tokens.entries

    old = tokens.enable(workspace)
    @runner = Runner.new
    @runner.fail_at = 2
    installer = CoderNotify::WorkspaceSetup.new(config: @config, root: ROOT, discovery: @discovery,
                                                runner: @runner, output: @output)
    assert_raises(CoderNotify::WorkspaceSetup::Error) { installer.call("alpha") }
    assert_equal old.token, tokens.entries.fetch(0).token
  end

  def test_repeat_setup_reuses_token_and_supports_claude_only
    first = @installer.call("alpha", agent: "claude", install_deps: true)
    again = @installer.call("alpha", agent: "claude")
    assert_equal first.token, again.token
    assert_equal "claude", archive_files["agent"]
    assert_includes @runner.calls.first[:argv].last, "install-deps"
    refute_includes @output.string, "open /hooks"
  end

  def test_runner_can_upload_input_and_capture_output
    result = CoderNotify::SetupRunner.new.call([RbConfig.ruby, "-e", 'print STDIN.read.reverse; warn "stderr"'],
                                               input: "abc", timeout: 5)
    assert_equal "cba", result.stdout
    assert_equal "stderr\n", result.stderr
    assert_equal 0, result.status
  end
end
