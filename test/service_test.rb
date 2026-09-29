require_relative "test_helper"

# End-to-end behaviour of the Mac-side service with fake discovery: how
# `coder list` results flow into the workspace list, sessions and menu data.
class ServiceTest < Minitest::Test
  Result = CoderNotify::WorkspaceDiscovery::Result

  def setup
    @discovery = FakeDiscovery.new
    @service = build_service(tmpdir, discovery: @discovery)
  end

  def discover(*workspaces, error: nil)
    @discovery.result = Result.new(workspaces: error ? nil : workspaces, error: error)
    @service.discover
  end

  def waiting_session_on(workspace_id)
    @service.sessions.apply(event(type: "waiting"), workspace_id: workspace_id, workspace_name: "x")
  end

  def monitoring = @service.snapshot["workspaces"].to_h { |ws| [ws["name"], ws["monitoring"]["state"]] }

  def test_discovers_workspaces_and_shows_setup_status
    discover(workspace(id: "a", name: "alpha"), workspace(id: "g", name: "gamma", build_status: "stopped"))
    @service.tokens.enable(@service.workspaces.find("g"))

    assert_equal({ "alpha" => "not_enabled", "gamma" => "idle" }, monitoring)
    states = @service.snapshot["workspaces"].to_h { |ws| [ws["name"], ws["state"]] }
    assert_equal({ "alpha" => "running", "gamma" => "stopped" }, states)
  end

  def test_deleted_workspace_disappears_with_its_sessions
    discover(workspace(id: "a", name: "alpha"), workspace(id: "b", name: "beta"))
    waiting_session_on("b")

    discover(workspace(id: "a", name: "alpha"))
    assert_equal ["alpha"], @service.snapshot["workspaces"].map { |ws| ws["name"] }
    assert_empty @service.sessions.sessions
  end

  def test_stopped_workspace_loses_its_sessions
    discover(workspace(id: "a"))
    waiting_session_on("a")

    discover(workspace(id: "a", build_status: "stopped"))
    assert_empty @service.sessions.sessions
  end

  def test_unreachable_workspace_keeps_its_sessions
    discover(workspace(id: "a"))
    waiting_session_on("a")

    discover(workspace(id: "a", agent_status: "disconnected"))
    assert_equal 1, @service.sessions.sessions.size
  end

  def test_discovery_error_keeps_last_list_and_sessions
    discover(workspace(id: "a", name: "alpha"))
    waiting_session_on("a")

    discover(error: "coder list failed: error: You are not logged in.")
    snapshot = @service.snapshot
    assert_equal ["alpha"], snapshot["workspaces"].map { |ws| ws["name"] }
    assert_equal "coder list failed: error: You are not logged in.", snapshot["discovery"]["error"]
    assert_equal 1, snapshot["attention_count"]
  end

  def test_state_survives_a_service_restart
    discover(workspace(id: "a", name: "alpha"))
    waiting_session_on("a")

    restarted = build_service(tmpdir)
    snapshot = restarted.snapshot
    assert_equal 1, snapshot["attention_count"]
    assert_equal ["alpha"], snapshot["workspaces"].map { |ws| ws["name"] }
    assert_equal @service.menu_token, restarted.menu_token
  end
end
