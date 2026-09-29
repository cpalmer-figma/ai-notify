require_relative "test_helper"
require "open3"

# Runs remote/bin/coder-notify-remote locally against fake `curl` and `tmux`
# (test/support/bin), so no workspace or network is involved. Needs bash
# and jq on this machine.
class RemoteScriptTest < Minitest::Test
  SCRIPT = File.expand_path("../remote/bin/coder-notify-remote", __dir__)
  FAKE_BIN = File.expand_path("support/bin", __dir__)
  TOKEN = "t0ken-for-tests"

  def setup
    skip "jq is not installed" unless system("command -v jq >/dev/null 2>&1")
    @home = tmpdir
    @curl_log = File.join(@home, "curl.log")
    FileUtils.mkdir_p(File.join(@home, ".config/coder-notify"))
    File.write(File.join(@home, ".config/coder-notify/env"),
               "CODER_NOTIFY_URL=http://127.0.0.1:47290\nCODER_NOTIFY_TOKEN=#{TOKEN}\n")
  end

  def env(extra = {})
    {
      "HOME" => @home,
      "PATH" => "#{FAKE_BIN}:#{ENV.fetch('PATH')}",
      "FAKE_CURL_LOG" => @curl_log,
      # The test process is an ancestor of the script, so this pretends the
      # hook runs inside pane %5.
      "FAKE_PANE_PID" => Process.pid.to_s,
      "TMUX_PANE" => "%5",
      "CODER_WORKSPACE_NAME" => "alpha",
      "XDG_CACHE_HOME" => File.join(@home, ".cache")
    }.merge(extra)
  end

  def run_script(*args, stdin: "", **extra_env)
    Open3.capture3(env(extra_env.transform_keys(&:to_s)), SCRIPT, *args, stdin_data: stdin)
  end

  def wait_until(seconds = 3)
    deadline = Time.now + seconds
    sleep 0.05 until yield || Time.now > deadline
  end

  def logged_requests = File.exist?(@curl_log) ? File.readlines(@curl_log).map { |line| JSON.parse(line) } : []

  # Hooks send in the background, so wait for the fake curl to be called.
  def requests(count: 1)
    wait_until { logged_requests.size >= count }
    logged_requests
  end

  # Background sends take well under a second; give them time, then check.
  def assert_nothing_sent
    sleep 0.5
    assert_empty logged_requests
  end

  def sent_events = requests.map { |r| JSON.parse(r["body"]) unless r["body"].empty? }.compact

  def spool_files = Dir[File.join(@home, ".cache/coder-notify/spool/*.json")]

  def claude_hook(fields) = JSON.generate({ "session_id" => "abc-123", "cwd" => "/src" }.merge(fields))

  # --- hooks ---------------------------------------------------------------

  def test_claude_permission_prompt_is_a_waiting_event
    stdout, _stderr, status = run_script("hook", "claude", stdin: claude_hook(
      "hook_event_name" => "Notification", "notification_type" => "permission_prompt",
      "message" => "Claude needs your permission to use Bash"
    ))

    assert status.success?
    assert_empty stdout, "hooks must print nothing (Claude may treat stdout as input)"
    event = sent_events.fetch(0)
    assert_equal "waiting", event["type"]
    assert_equal "permission", event["reason"]
    assert_equal "claude", event["agent"]
    assert_equal "abc-123", event["session_id"]
    assert_equal "%5", event["pane_id"]
    assert_equal "main:1.0", event["pane_label"]
    assert_equal "alpha", event["workspace_name"]
    assert_equal false, event["focused"]
    refute event.key?("message"), "free text from the hook must not be forwarded"
  end

  def test_payload_is_accepted_by_the_mac_side_validator
    run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Stop"))
    event = CoderNotify::Event.from_payload(sent_events.fetch(0))
    assert_equal "done", event.reason
  end

  def test_prompt_submission_is_resumed_and_never_includes_the_prompt
    stdout, = run_script("hook", "claude", stdin: claude_hook(
      "hook_event_name" => "UserPromptSubmit", "prompt" => "TOP SECRET PROMPT"
    ))

    assert_empty stdout
    request = requests.fetch(0)
    assert_equal "resumed", JSON.parse(request["body"])["type"]
    refute_includes request["body"], "TOP SECRET PROMPT"
  end

  def test_token_is_not_passed_on_the_command_line
    run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Stop"))
    request = requests.fetch(0)
    refute_includes request["argv"], TOKEN
    assert_includes request["config"], "Authorization: Bearer #{TOKEN}"
    assert_equal "http://127.0.0.1:47290/events", request["url"]
  end

  def test_codex_permission_request_and_session_end
    run_script("hook", "codex", stdin: claude_hook("hook_event_name" => "PermissionRequest", "tool_name" => "Bash"))
    run_script("hook", "codex", stdin: claude_hook("hook_event_name" => "SessionEnd"))

    events = requests(count: 2).map { |r| JSON.parse(r["body"]) }.sort_by { |e| e["type"] }
    assert_equal %w[ended waiting], events.map { |e| e["type"] }
    assert_equal %w[codex codex], events.map { |e| e["agent"] }
  end

  def test_subagent_prompts_are_ignored
    run_script("hook", "codex", stdin: claude_hook("hook_event_name" => "UserPromptSubmit", "agent_id" => "sub-1"))
    assert_nothing_sent
  end

  def test_unrelated_notifications_are_ignored
    run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Notification",
                                                    "notification_type" => "idle_prompt"))
    assert_nothing_sent
  end

  def test_focused_pane_is_reported_only_when_tmux_focus_events_are_on
    run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Stop"), FAKE_FOCUS_EVENTS: "on")
    assert_equal true, sent_events.fetch(0)["focused"]
  end

  def test_hook_outside_its_pane_reports_nothing
    # e.g. Codex running hooks in a shared background server started elsewhere
    stdout, _stderr, status = run_script("hook", "codex", stdin: claude_hook("hook_event_name" => "Stop"),
                                                          FAKE_PANE_PID: "999999")
    assert status.success?
    assert_empty stdout
    assert_nothing_sent
    assert_match(/not running inside pane %5/, File.read(File.join(@home, ".cache/coder-notify/remote.log")))
  end

  def test_not_in_tmux_or_not_configured_does_nothing_quietly
    _stdout, _stderr, status = run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Stop"),
                                                            TMUX_PANE: "")
    assert status.success?

    File.delete(File.join(@home, ".config/coder-notify/env"))
    stdout, stderr, status = run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Stop"))
    assert status.success?
    assert_empty stdout + stderr
    assert_nothing_sent
  end

  def test_codex_legacy_notify
    notify = JSON.generate("type" => "agent-turn-complete", "thread-id" => "th-1", "turn-id" => "1",
                           "input-messages" => ["secret"], "last-assistant-message" => "secret too")
    run_script("codex-notify", notify)

    request = requests.fetch(0)
    refute_includes request["body"], "secret"
    event = JSON.parse(request["body"])
    assert_equal %w[waiting done th-1], event.values_at("type", "reason", "session_id")
  end

  def test_focus_hook_sends_acknowledged_for_the_pane
    run_script("focus", "%7", TMUX_PANE: "")
    event = sent_events.fetch(0)
    assert_equal "acknowledged", event["type"]
    assert_equal "%7", event["pane_id"]
  end

  def test_focus_hook_ignores_garbage
    run_script("focus", "not-a-pane")
    assert_nothing_sent
  end

  # --- queueing and reconnect ------------------------------------------------

  def test_undeliverable_event_is_queued_and_replayed_by_sync
    run_script("hook", "claude", stdin: claude_hook("hook_event_name" => "Stop"), FAKE_CURL_STATUS: "000")
    wait_until { spool_files.any? }
    assert_equal 1, spool_files.size

    File.delete(@curl_log)
    stdout, _stderr, status = run_script("sync")
    assert status.success?
    assert_match(/sync: HTTP 200/, stdout)
    assert_empty spool_files
    types = requests(count: 2).map { |r| JSON.parse(r["body"])["type"] }
    assert_equal %w[waiting sync], types, "queued events are replayed before the sync"
  end

  def test_sync_lists_live_panes
    run_script("sync")
    sync = sent_events.find { |e| e["type"] == "sync" }
    assert_equal [{ "pane_id" => "%1", "pane_label" => "main:1.0" }, { "pane_id" => "%5", "pane_label" => "work:2.1" }],
                 sync["panes"]
  end

  def test_sync_payload_is_accepted_by_the_mac_side_validator
    run_script("sync")
    sync = CoderNotify::Event.from_payload(sent_events.find { |e| e["type"] == "sync" })
    assert_equal %w[%1 %5], sync.panes.map { |pane| pane[:pane_id] }
  end

  def test_sync_with_no_tmux_server_reports_no_panes
    run_script("sync", FAKE_TMUX_DOWN: "1")
    assert_equal [], sent_events.find { |e| e["type"] == "sync" }["panes"]
  end

  # --- tunnel ----------------------------------------------------------------

  def test_tunnel_prints_ready_and_exits_when_stdin_closes
    stdout, _stderr, status = run_script("tunnel", stdin: "")
    assert_equal "READY\n", stdout
    assert_equal 0, status.exitstatus
  end

  def test_tunnel_exit_codes
    _out, _err, status = run_script("tunnel", FAKE_HEALTH: '{"ok":true,"service":"coder-notify"}')
    assert_equal 4, status.exitstatus, "health without a workspace means the token was rejected"

    _out, _err, status = run_script("tunnel", FAKE_HEALTH: '{"hello":"another app"}')
    assert_equal 5, status.exitstatus, "something else is listening on the port"

    File.delete(File.join(@home, ".config/coder-notify/env"))
    _out, _err, status = run_script("tunnel")
    assert_equal 3, status.exitstatus
  end
end
