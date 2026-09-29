require_relative "test_helper"

class SessionStoreTest < Minitest::Test
  def setup
    @now = Time.at(5_000)
    @store = new_store
  end

  def new_store = CoderNotify::SessionStore.new(path: File.join(tmpdir, "state.json"), clock: -> { @now })

  def apply(store = @store, workspace_id: "ws-1", **event_fields)
    store.apply(event(**event_fields), workspace_id: workspace_id, workspace_name: "alpha")
  end

  def only_session = @store.sessions.fetch(0)

  # --- waiting ------------------------------------------------------------

  def test_waiting_event_needs_attention
    assert_equal :applied, apply(type: "waiting", reason: "permission")

    session = only_session
    assert session.attention?
    assert_equal "waiting", session.status
    assert_equal "permission", session.reason
    assert_equal "ws-1|%1|claude|sess-1", session.key
  end

  def test_waiting_while_pane_is_already_focused_does_not_need_attention
    apply(type: "waiting", focused: true)
    assert only_session.waiting?
    refute only_session.attention?
  end

  # --- duplicates and ordering --------------------------------------------

  def test_duplicate_event_id_is_ignored
    apply(type: "waiting", event_id: "same")
    apply(type: "acknowledged", event_id: "ack", sent_at_ms: 2_000)
    assert_equal :duplicate, apply(type: "waiting", event_id: "same")
    refute only_session.attention?, "the replayed duplicate must not re-raise the alert"
  end

  def test_duplicates_are_detected_after_restart
    apply(type: "waiting", event_id: "same")
    assert_equal :duplicate, apply(new_store, type: "waiting", event_id: "same")
  end

  def test_older_event_arriving_late_is_ignored
    apply(type: "resumed", sent_at_ms: 2_000)
    assert_equal :stale, apply(type: "waiting", sent_at_ms: 1_000)
    assert_equal "working", only_session.status
  end

  # --- acknowledged (you focused the pane) --------------------------------

  def test_acknowledged_clears_attention_but_does_not_claim_the_agent_resumed
    apply(type: "waiting", reason: "permission", sent_at_ms: 1_000)
    assert_equal :applied, apply(type: "acknowledged", sent_at_ms: 2_000)

    session = only_session
    refute session.attention?
    assert_equal "waiting", session.status, "focusing a pane is not the same as resolving the approval"
    assert_equal "permission", session.reason
    assert_equal 2_000, session.acknowledged_at_ms
  end

  def test_acknowledged_only_affects_its_own_pane_and_workspace
    apply(type: "waiting", pane_id: "%1", session_id: "a")
    apply(type: "waiting", pane_id: "%2", session_id: "b")
    apply(workspace_id: "ws-2", type: "waiting", pane_id: "%1", session_id: "c")
    apply(type: "acknowledged", pane_id: "%1", sent_at_ms: 2_000)

    attention = @store.attention.map(&:session_id).sort
    assert_equal %w[b c], attention
  end

  def test_focus_before_the_wait_started_does_not_acknowledge_it
    apply(type: "waiting", sent_at_ms: 3_000)
    apply(type: "acknowledged", sent_at_ms: 2_000) # sent earlier, arrived later
    assert only_session.attention?
  end

  def test_wait_that_arrives_after_a_later_focus_is_already_seen
    apply(type: "acknowledged", sent_at_ms: 2_000) # nothing waiting yet
    apply(type: "waiting", sent_at_ms: 1_500)      # sent before the focus, arrived after
    refute only_session.attention?
  end

  def test_acknowledging_a_pane_with_nothing_waiting_changes_nothing
    assert_equal :unchanged, apply(type: "acknowledged")
    assert_empty @store.sessions
  end

  def test_new_wait_after_acknowledgement_needs_attention_again
    apply(type: "waiting", reason: "permission", sent_at_ms: 1_000)
    apply(type: "acknowledged", sent_at_ms: 2_000)
    apply(type: "waiting", reason: "done", sent_at_ms: 3_000)

    assert only_session.attention?
    assert_equal "done", only_session.reason
  end

  # --- resumed and ended --------------------------------------------------

  def test_resumed_means_working_and_clears_attention
    apply(type: "waiting", sent_at_ms: 1_000)
    apply(type: "resumed", sent_at_ms: 2_000)

    assert_equal "working", only_session.status
    refute only_session.attention?
    assert_nil only_session.reason
  end

  def test_ended_removes_the_session
    apply(type: "waiting", sent_at_ms: 1_000)
    apply(type: "ended", sent_at_ms: 2_000)
    assert_empty @store.sessions
  end

  def test_new_session_in_the_same_pane_replaces_the_old_one
    apply(type: "waiting", session_id: "old", sent_at_ms: 1_000)
    apply(type: "resumed", agent: "codex", session_id: "new", sent_at_ms: 2_000)

    assert_equal ["new"], @store.sessions.map(&:session_id)
  end

  # --- sync after reconnect -----------------------------------------------

  def test_sync_drops_sessions_whose_pane_is_gone_and_updates_labels
    apply(type: "waiting", pane_id: "%1", session_id: "a", sent_at_ms: 1_000)
    apply(type: "waiting", pane_id: "%2", session_id: "b", sent_at_ms: 1_000)
    apply(type: "sync", sent_at_ms: 2_000, panes: [{ "pane_id" => "%2", "pane_label" => "renamed:3.1" }])

    assert_equal ["b"], @store.sessions.map(&:session_id)
    assert_equal "renamed:3.1", only_session.pane_label
  end

  def test_sync_keeps_sessions_newer_than_the_snapshot
    apply(type: "waiting", pane_id: "%9", sent_at_ms: 3_000)
    apply(type: "sync", sent_at_ms: 2_000, panes: [])
    assert_equal 1, @store.sessions.size
  end

  def test_sync_only_touches_its_own_workspace
    apply(workspace_id: "ws-2", type: "waiting", pane_id: "%1")
    apply(type: "sync", sent_at_ms: 2_000, panes: [])
    assert_equal ["ws-2"], @store.sessions.map(&:workspace_id)
  end

  # --- menu actions and workspace changes ---------------------------------

  def test_dismiss_acknowledges_one_session
    apply(type: "waiting", pane_id: "%1", session_id: "a")
    apply(type: "waiting", pane_id: "%2", session_id: "b")
    @store.dismiss("ws-1|%1|claude|a")

    assert_equal ["b"], @store.attention.map(&:session_id)
    assert_equal 5_000_000, @store.sessions.find { |s| s.session_id == "a" }.acknowledged_at_ms
  end

  def test_dismiss_all
    apply(type: "waiting", pane_id: "%1", session_id: "a")
    apply(type: "waiting", pane_id: "%2", session_id: "b")
    @store.dismiss_all
    assert_empty @store.attention
  end

  def test_remove_workspace_forgets_its_sessions
    apply(type: "waiting")
    apply(workspace_id: "ws-2", type: "waiting")
    @store.remove_workspace("ws-1")
    assert_equal ["ws-2"], @store.sessions.map(&:workspace_id)
  end

  def test_state_survives_restart
    apply(type: "waiting", reason: "done", sent_at_ms: 1_000)
    reloaded = new_store.sessions.fetch(0)

    assert reloaded.attention?
    assert_equal "done", reloaded.reason
    assert_equal "main:1.0", reloaded.pane_label
  end
end
