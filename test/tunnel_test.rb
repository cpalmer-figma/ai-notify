require_relative "test_helper"

class TunnelPlannerTest < Minitest::Test
  Tunnel = CoderNotify::TunnelSupervisor::Tunnel

  def plan(workspaces:, enabled: [], tunnels: {}, now: 100.0)
    CoderNotify::TunnelPlanner.plan(workspaces: workspaces, enabled_ids: enabled, tunnels: tunnels, now: now)
  end

  def test_starts_tunnel_for_enabled_running_workspace
    result = plan(workspaces: [workspace(id: "a")], enabled: ["a"])
    assert_equal ["a"], result.start.map(&:id)
  end

  def test_ignores_workspaces_that_are_not_enabled
    result = plan(workspaces: [workspace(id: "a")], enabled: [])
    assert_empty result.start
  end

  def test_never_tunnels_to_stopped_or_starting_workspaces
    stopped = workspace(id: "s", build_status: "stopped", agent_status: nil)
    starting = workspace(id: "t", build_status: "starting", agent_status: "connecting")
    result = plan(workspaces: [stopped, starting], enabled: %w[s t])
    assert_empty result.start
  end

  def test_waits_for_the_agent_to_connect
    result = plan(workspaces: [workspace(id: "a", agent_status: "disconnected")], enabled: ["a"])
    assert_empty result.start
  end

  def test_leaves_running_tunnel_alone
    running = Tunnel.new(handle: :pid, retry_at: 0)
    result = plan(workspaces: [workspace(id: "a")], enabled: ["a"], tunnels: { "a" => running })
    assert_empty result.start
    assert_empty result.stop
  end

  def test_restarts_broken_tunnel_only_after_its_retry_time
    broken = Tunnel.new(handle: nil, retry_at: 150.0)
    args = { workspaces: [workspace(id: "a")], enabled: ["a"], tunnels: { "a" => broken } }

    assert_empty plan(**args, now: 100.0).start
    assert_equal ["a"], plan(**args, now: 150.0).start.map(&:id)
  end

  def test_stops_tunnels_for_stopped_disabled_or_deleted_workspaces
    tunnels = { "stopped" => Tunnel.new(handle: 1), "disabled" => Tunnel.new(handle: 2),
                "deleted" => Tunnel.new(handle: 3), "ok" => Tunnel.new(handle: 4) }
    workspaces = [workspace(id: "stopped", build_status: "stopped"), workspace(id: "disabled"), workspace(id: "ok")]
    result = plan(workspaces: workspaces, enabled: %w[stopped ok deleted], tunnels: tunnels)

    assert_equal %w[stopped disabled deleted], result.stop
  end
end

class TunnelSupervisorTest < Minitest::Test
  # Records spawn/stop calls and lets the test play the child process.
  class FakeSpawner
    Child = Struct.new(:argv, :on_line, :on_error_line, :on_exit, :stopped)
    attr_reader :children

    def initialize = @children = []

    def spawn(argv, on_line:, on_error_line:, on_exit:)
      child = Child.new(argv, on_line, on_error_line, on_exit, false)
      @children << child
      child
    end

    def stop(child) = child.stopped = true
  end

  def setup
    @now = 1_000.0
    @changes = 0
    @spawner = FakeSpawner.new
    config = CoderNotify::Config.new("CODER_NOTIFY_HOME" => tmpdir, "CODER_BIN" => "/usr/local/bin/coder")
    @supervisor = CoderNotify::TunnelSupervisor.new(config: config, spawner: @spawner, clock: -> { @now },
                                                    on_change: -> { @changes += 1 })
    @alpha = workspace(id: "a", name: "alpha")
  end

  def reconcile(workspaces = [@alpha], enabled = ["a"]) = @supervisor.reconcile(workspaces, enabled)
  def child = @spawner.children.last

  def test_command_uses_disable_autostart_loopback_forward_and_main_agent
    reconcile
    assert_equal ["/usr/local/bin/coder", "ssh", "--disable-autostart", "--wait=no", "--usage-app=disable",
                  "-R", "47290:127.0.0.1:47290", "alpha.workspace",
                  "--", "$HOME/.local/bin/coder-notify-remote tunnel"], child.argv
    assert_equal "connecting", @supervisor.status("a")["state"]
  end

  def test_ready_line_marks_tunnel_connected
    reconcile
    child.on_line.call("READY")
    assert_equal({ "state" => "connected", "detail" => "tunnel verified" }, @supervisor.status("a"))
  end

  def test_broken_tunnel_reconnects_with_backoff
    reconcile
    child.on_line.call("READY")
    child.on_exit.call(255)

    status = @supervisor.status("a")
    assert_equal "reconnecting", status["state"]
    assert_match(/connection lost/, status["detail"])
    assert_equal 2, status["retry_in"]

    reconcile
    assert_equal 1, @spawner.children.size, "must wait for the backoff before retrying"

    @now += 2
    reconcile
    assert_equal 2, @spawner.children.size
  end

  def test_backoff_grows_and_is_capped
    reconcile
    10.times do
      child.on_exit.call(1)
      @now += 1_000
      reconcile
    end
    child.on_exit.call(1)
    # 11 failures in a row: 2**11 seconds would be far too long.
    assert_equal 60, @supervisor.status("a")["retry_in"]
  end

  def test_missing_remote_script_is_reported_and_retried_slowly
    reconcile
    child.on_exit.call(127)

    assert_equal "remote_not_installed", @supervisor.status("a")["state"]
    @now += 299
    reconcile
    assert_equal 1, @spawner.children.size
    @now += 1
    reconcile
    assert_equal 2, @spawner.children.size
  end

  def test_missing_remote_config_and_rejected_token_have_their_own_states
    reconcile
    child.on_exit.call(3)
    assert_equal "remote_not_configured", @supervisor.status("a")["state"]

    @now += 300
    reconcile
    child.on_exit.call(4)
    assert_equal "token_rejected", @supervisor.status("a")["state"]
  end

  def test_missing_tools_on_the_workspace
    reconcile
    child.on_exit.call(6)
    assert_equal "remote_missing_tools", @supervisor.status("a")["state"]
  end

  def test_gives_up_on_a_connect_that_never_becomes_ready
    reconcile
    stuck = child
    @now += 121
    reconcile
    assert stuck.stopped
    assert_equal "reconnecting", @supervisor.status("a")["state"]
    assert_match(/timed out connecting/, @supervisor.status("a")["detail"])

    stuck.on_exit.call(nil) # the killed process exiting must not change anything
    assert_equal "reconnecting", @supervisor.status("a")["state"]

    @now += 2
    reconcile
    assert_equal 2, @spawner.children.size
  end

  def test_stale_remote_listener_error_is_shown
    reconcile
    child.on_error_line.call("ssh remote forward: listen on remote SSH address 127.0.0.1:47290: " \
                             "ssh: tcpip-forward request denied by peer")
    child.on_exit.call(1)
    assert_match(/tcpip-forward request denied/, @supervisor.status("a")["detail"])
  end

  def test_stderr_is_kept_as_detail_while_connecting
    reconcile
    child.on_error_line.call("error: workspace is stopped")
    assert_equal "error: workspace is stopped", @supervisor.status("a")["detail"]
  end

  def test_stops_tunnel_when_workspace_stops
    reconcile
    first = child
    reconcile([workspace(id: "a", build_status: "stopped")])

    assert first.stopped
    assert_nil @supervisor.status("a")
  end

  def test_exit_of_a_stopped_tunnel_is_ignored
    reconcile
    first = child
    reconcile([], [])
    first.on_exit.call(143)
    assert_nil @supervisor.status("a")
  end

  def test_stop_all
    reconcile
    @supervisor.stop_all
    assert child.stopped
  end

  def test_reports_changes_for_the_menu
    reconcile
    child.on_line.call("READY")
    assert_operator @changes, :>=, 2
  end
end
