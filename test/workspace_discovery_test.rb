require_relative "test_helper"

class WorkspaceDiscoveryTest < Minitest::Test
  # Stands in for CommandRunner: returns canned output instead of running coder.
  FakeRunner = Struct.new(:stdout, :success, :stderr, :calls) do
    def call(argv, timeout:)
      (self.calls ||= []) << argv
      [stdout, success, stderr]
    end
  end

  def discover(stdout: fixture("coder_list.json"), success: true, stderr: "")
    runner = FakeRunner.new(stdout, success, stderr)
    [CoderNotify::WorkspaceDiscovery.new(coder_bin: "/usr/local/bin/coder", runner: runner).call, runner]
  end

  def test_runs_coder_list_with_json_output
    _result, runner = discover
    assert_equal [["/usr/local/bin/coder", "list", "--output", "json"]], runner.calls
  end

  def test_parses_real_coder_list_output
    result, _runner = discover
    assert result.ok?
    assert_equal %w[alpha beta gamma], result.workspaces.map(&:name)

    alpha = result.workspaces.first
    assert_equal "00000000-0000-4000-8000-000000000001", alpha.id
    assert_equal "running", alpha.state
    # The devcontainer sub-agent has a parent_id; we must pick the main agent.
    assert_equal "workspace", alpha.agent_name
    assert_equal "alpha.workspace", alpha.ssh_target
  end

  def test_stopped_workspace_has_no_agent_and_is_off
    result, _runner = discover
    gamma = result.workspaces.last
    assert_equal "stopped", gamma.state
    assert gamma.off?
    assert_nil gamma.agent_name
    refute gamma.running?
  end

  def test_running_workspace_with_disconnected_agent_is_unreachable
    list = JSON.parse(fixture("coder_list.json"))
    list[0]["latest_build"]["resources"][0]["agents"][1]["status"] = "disconnected"
    result, _runner = discover(stdout: JSON.generate(list))

    alpha = result.workspaces.first
    assert_equal "unreachable", alpha.state
    refute alpha.running?
    refute alpha.off?, "an unreachable workspace may come back; keep its sessions"
  end

  def test_other_build_statuses
    assert_equal "starting", workspace(build_status: "starting").state
    assert_equal "stopped", workspace(build_status: "stopping").state
    assert_equal "deleting", workspace(build_status: "deleting").state
    assert_equal "failed", workspace(build_status: "failed").state
  end

  def test_preserves_reported_credit_cost_including_zero
    list = JSON.parse(fixture("coder_list.json"))
    list[0]["latest_build"]["daily_cost"] = 60
    list[1]["latest_build"]["daily_cost"] = 0
    result, = discover(stdout: JSON.generate(list))

    assert_equal [60, 0, nil], result.workspaces.map(&:daily_cost)
  end

  def test_coder_failure_returns_error_from_last_stderr_line
    stderr = "Encountered an error running \"coder list\"\nerror: You are not logged in.\n"
    result, _runner = discover(stdout: "", success: false, stderr: stderr)

    refute result.ok?
    assert_nil result.workspaces
    assert_equal "coder list failed: error: You are not logged in.", result.error
  end

  def test_invalid_json_is_an_error
    result, _runner = discover(stdout: "not json")
    assert_match(/could not parse/, result.error)
  end

  def test_json_that_is_not_a_list_is_an_error
    result, _runner = discover(stdout: '{"message": "nope"}')
    assert_match(/not an array/, result.error)
  end

  def test_missing_coder_binary_is_an_error
    runner = ->(_argv, timeout:) { raise Errno::ENOENT, "coder" }
    result = CoderNotify::WorkspaceDiscovery.new(runner: runner).call
    assert_match(/coder CLI not found/, result.error)
  end

  def test_command_runner_times_out_slow_commands
    stdout, success, stderr = CoderNotify::CommandRunner.new.call(["sleep", "5"], timeout: 0.2)
    assert_equal "", stdout
    refute success
    assert_match(/timed out/, stderr)
  end
end
