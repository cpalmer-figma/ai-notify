require_relative "test_helper"
require "open3"

PLUGIN_PATH = File.expand_path("../swiftbar/coder-notify.1m.rb", __dir__)
load PLUGIN_PATH # defines CoderNotifyMenu without running it

class SwiftbarPluginTest < Minitest::Test
  Result = CoderNotify::WorkspaceDiscovery::Result
  NOW = Time.at(1_000_000)

  def setup
    @service = build_service(tmpdir)
    @service.workspaces.apply(Result.new(workspaces: [
      workspace(id: "a", name: "alpha"),
      workspace(id: "b", name: "beta"),
      workspace(id: "g", name: "gamma", build_status: "stopped", agent_status: nil)
    ], error: nil))
  end

  def apply(workspace_id: "a", **fields)
    @service.sessions.apply(event(**fields), workspace_id: workspace_id, workspace_name: workspace_id == "a" ? "alpha" : "beta")
  end

  def menu = CoderNotifyMenu.render(JSON.parse(JSON.generate(@service.snapshot)), NOW)
  def title = menu.lines.first.chomp

  def test_idle_menu_shows_a_plain_bell
    assert_equal "| sfimage=bell", title
    assert_includes menu, "No agents need you right now"
  end

  def test_waiting_agents_show_count_and_details
    apply(type: "waiting", reason: "permission", sent_at_ms: 820_000_000, pane_id: "%1", session_id: "s1")
    apply(type: "waiting", reason: "done", sent_at_ms: 999_000_000, pane_id: "%2", session_id: "s2", pane_label: "work:2.1")

    assert_equal "2 | sfimage=bell.badge.fill", title
    assert_includes menu, "Needs attention (2)"
    assert_includes menu, "Claude · alpha · main:1.0 — Needs permission (50h 0m)"
    assert_includes menu, "Claude · alpha · work:2.1 — Finished responding (16m)"
    assert_includes menu, "--Dismiss | bash=\"#{PLUGIN_PATH}\" param1=dismiss param2=\"a|%1|claude|s1\" terminal=false refresh=true"
    assert_includes menu, "Dismiss all |"
  end

  def test_seen_and_working_sessions_are_listed_separately
    apply(type: "waiting", focused: true, pane_id: "%1", session_id: "s1")
    apply(type: "resumed", pane_id: "%2", session_id: "s2")

    assert_equal "| sfimage=bell", title, "seen or working sessions don't count"
    assert_includes menu, "Seen (1)"
    assert_includes menu, "Working (1) | sfimage=hammer"
    refute_includes menu, "Dismiss all"
  end

  def test_workspace_statuses
    @service.tokens.enable(@service.workspaces.find("a"))
    @service.tokens.enable(@service.workspaces.find("g"))

    assert_includes menu, "alpha — connecting | sfimage=arrow.triangle.2.circlepath"
    assert_includes menu, "beta — not enabled | sfimage=circle.dashed"
    assert_includes menu, "--not set up; see README (bin/coder-notify enable beta)"
    assert_includes menu, "gamma — stopped | sfimage=moon.zzz"
  end

  def test_unreachable_workspace_and_discovery_error_are_warnings
    @service.workspaces.apply(Result.new(workspaces: [workspace(id: "a", name: "alpha", agent_status: "timeout")], error: nil))
    @service.workspaces.apply(Result.new(workspaces: nil, error: "coder list failed: error: You are not logged in."))

    assert_equal "| sfimage=exclamationmark.triangle", title
    assert_includes menu, "alpha — unreachable | sfimage=exclamationmark.triangle"
    assert_includes menu, "⚠ Workspace discovery failed; showing last known list"
    assert_includes menu, "--coder list failed: error: You are not logged in."
  end

  def test_tunnel_errors_are_shown
    snapshot = JSON.parse(JSON.generate(@service.snapshot))
    snapshot["workspaces"][0]["monitoring"] = {
      "state" => "remote_not_installed", "detail" => "coder-notify-remote is not installed", "retry_in" => 240
    }
    text = CoderNotifyMenu.render(snapshot, NOW)
    assert_includes text, "alpha — remote not installed | sfimage=exclamationmark.triangle"
    assert_includes text, "--Retrying in 240s"
  end

  def test_labels_cannot_inject_menu_options_or_items
    apply(type: "waiting", pane_label: "evil | bash=/bin/sh")
    item = menu.lines.find { |line| line.include?("evil") }
    assert_equal 1, item.count("|"), "only the option separator we add may contain a pipe"
    assert_includes item, "evil ¦ bash=/bin/sh"

    assert_equal "x", CoderNotifyMenu.clean("---x")
    assert_equal "a b", CoderNotifyMenu.clean("a\nb")
  end

  def test_service_down
    text = CoderNotifyMenu.render({ "error" => "coder-notify service is not running (ECONNREFUSED)" }, NOW)
    assert_equal "| sfimage=bell.slash", text.lines.first.chomp
    assert_includes text, "service is not running"
  end

  def test_runs_under_macos_system_ruby
    ruby = "/usr/bin/ruby"
    skip "no #{ruby}" unless File.executable?(ruby)

    # A clean environment, like SwiftBar's (and without Bundler's RUBYOPT).
    env = { "HOME" => Dir.home, "PATH" => "/usr/bin:/bin",
            "CODER_NOTIFY_HOME" => tmpdir, "CODER_NOTIFY_URL" => "http://127.0.0.1:9" }
    stdout, _stderr, status = Open3.capture3(env, ruby, PLUGIN_PATH, unsetenv_others: true)
    assert status.success?
    assert_includes stdout, "sfimage=bell.slash"
  end
end
