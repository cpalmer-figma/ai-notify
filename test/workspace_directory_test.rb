require_relative "test_helper"

class WorkspaceDirectoryTest < Minitest::Test
  Result = CoderNotify::WorkspaceDiscovery::Result

  def directory = CoderNotify::WorkspaceDirectory.new(path: File.join(tmpdir, "workspaces.json"))
  def ok(*workspaces) = Result.new(workspaces: workspaces, error: nil)
  def failed(message) = Result.new(workspaces: nil, error: message)

  def test_first_successful_discovery_adds_everything
    dir = directory
    update = dir.apply(ok(workspace(id: "a", name: "alpha"), workspace(id: "b", name: "beta")))

    assert_equal %w[alpha beta], update.added.map(&:name)
    assert_empty update.removed
    assert_nil dir.error
  end

  def test_new_workspace_is_discovered
    dir = directory
    dir.apply(ok(workspace(id: "a", name: "alpha")))
    update = dir.apply(ok(workspace(id: "a", name: "alpha"), workspace(id: "n", name: "new-one")))

    assert_equal ["new-one"], update.added.map(&:name)
    assert_equal %w[alpha new-one], dir.workspaces.map(&:name)
  end

  def test_deleted_workspace_is_removed
    dir = directory
    dir.apply(ok(workspace(id: "a", name: "alpha"), workspace(id: "b", name: "beta")))
    update = dir.apply(ok(workspace(id: "a", name: "alpha")))

    assert_equal ["beta"], update.removed.map(&:name)
    assert_nil dir.find("b")
  end

  def test_failure_keeps_last_known_list_and_records_error
    dir = directory
    dir.apply(ok(workspace(id: "a", name: "alpha")))
    update = dir.apply(failed("coder list failed: timeout"))

    assert_empty update.removed, "a failed discovery must not look like a deletion"
    assert_equal ["alpha"], dir.workspaces.map(&:name)
    assert_equal "coder list failed: timeout", dir.error
  end

  def test_success_after_failure_clears_error
    dir = directory
    dir.apply(failed("boom"))
    dir.apply(ok(workspace))
    assert_nil dir.error
  end

  def test_status_changes_are_picked_up
    dir = directory
    dir.apply(ok(workspace(id: "a", build_status: "running")))
    dir.apply(ok(workspace(id: "a", build_status: "stopped")))
    assert_equal "stopped", dir.find("a").state
  end

  def test_list_and_error_survive_restart
    directory.apply(ok(workspace(id: "a", name: "alpha")))
    directory.apply(failed("offline"))

    reloaded = directory
    assert_equal ["alpha"], reloaded.workspaces.map(&:name)
    assert_equal "offline", reloaded.error
  end
end
