require_relative "test_helper"

class EventTest < Minitest::Test
  def errors_for(hash)
    CoderNotify::Event.from_payload(hash)
    flunk "expected the payload to be rejected"
  rescue CoderNotify::Event::Invalid => e
    e.errors
  end

  def test_valid_waiting_event
    event = event(type: "waiting", reason: "done", focused: true)
    assert_equal "waiting", event.type
    assert_equal "done", event.reason
    assert event.focused
  end

  def test_acknowledged_needs_only_a_pane
    event = CoderNotify::Event.from_payload(
      { "version" => 1, "event_id" => "e1", "type" => "acknowledged", "sent_at_ms" => 1, "pane_id" => "%4" }
    )
    assert_equal "%4", event.pane_id
    assert_nil event.agent
  end

  def test_sync_lists_panes
    event = event(type: "sync", panes: [{ "pane_id" => "%1", "pane_label" => "main:1.0" }])
    assert_equal [{ pane_id: "%1", pane_label: "main:1.0" }], event.panes
  end

  def test_rejects_non_object_body
    assert_equal ["body must be a JSON object"], errors_for([1, 2])
  end

  def test_reports_every_problem_at_once
    errors = errors_for({ "version" => 2, "type" => "explode" })
    assert_includes errors, "version must be 1"
    assert_includes errors, "type must be one of waiting, resumed, acknowledged, ended, sync"
    assert_includes errors, "event_id is missing or malformed"
    assert_includes errors, "sent_at_ms must be an integer"
  end

  def test_rejects_unknown_agent_and_reason
    errors = errors_for(payload(agent: "gemini", reason: "bored"))
    assert_includes errors, "agent must be one of claude, codex"
    assert_includes errors, "reason must be one of permission, question, done"
  end

  def test_rejects_malformed_pane_and_labels
    errors = errors_for(payload(pane_id: "1; rm -rf /", pane_label: "evil\n| bash=/bin/sh"))
    assert_includes errors, "pane_id must look like %12"
    assert_includes errors, "pane_label is malformed"
  end

  def test_rejects_oversized_identifiers
    errors = errors_for(payload(session_id: "x" * 101))
    assert_includes errors, "session_id is missing or malformed"
  end

  def test_rejects_bad_sync_panes
    assert_includes errors_for(payload(type: "sync", panes: "all")), "panes must be an array of at most 500 entries"
    assert_includes errors_for(payload(type: "sync", panes: [{ "pane_id" => "nope" }])), "panes contains a malformed entry"
  end

  def test_extra_fields_like_prompts_are_not_kept
    event = event(prompt: "secret prompt text", transcript: "...")
    refute_includes event.to_h.values, "secret prompt text"
  end
end
