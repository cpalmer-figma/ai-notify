require_relative "test_helper"
require "open3"

# Checks the configuration examples in remote/ and the jq programs used to
# merge them into existing settings by hand (see README).
class RemoteConfigTest < Minitest::Test
  REMOTE = File.expand_path("../remote", __dir__)
  CLAUDE_HOOKS = File.join(REMOTE, "claude/settings.hooks.json")
  CODEX_HOOKS = File.join(REMOTE, "codex/hooks.json")

  # Someone's existing ~/.claude/settings.json, with hooks of their own.
  EXISTING = {
    "model" => "opus",
    "permissions" => { "allow" => ["Bash(git status)"] },
    "hooks" => {
      "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "say done" }] }],
      "PreToolUse" => [{ "matcher" => "Bash", "hooks" => [{ "type" => "command", "command" => "audit.sh" }] }]
    }
  }.freeze

  def setup
    skip "jq is not installed" unless system("command -v jq >/dev/null 2>&1")
  end

  def jq(*args)
    stdout, stderr, status = Open3.capture3("jq", *args)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def write_json(name, data)
    File.join(tmpdir, name).tap { |path| File.write(path, JSON.generate(data)) }
  end

  def merge(current, additions = CLAUDE_HOOKS)
    jq("-s", "-f", File.join(REMOTE, "merge-hooks.jq"), write_json("current.json", current), additions)
  end

  def remove(current) = jq("-f", File.join(REMOTE, "remove-hooks.jq"), write_json("merged.json", current))

  def commands(settings, event) = settings.dig("hooks", event).flat_map { |g| g["hooks"].map { |h| h["command"] } }

  def test_merge_keeps_existing_settings_and_hooks
    merged = merge(EXISTING)

    assert_equal "opus", merged["model"]
    assert_equal EXISTING["permissions"], merged["permissions"]
    assert_equal EXISTING["hooks"]["PreToolUse"], merged["hooks"]["PreToolUse"]
    assert_equal ["say done", "$HOME/.local/bin/coder-notify-remote hook claude"], commands(merged, "Stop")
    assert_equal %w[Notification PreToolUse SessionEnd Stop UserPromptSubmit], merged["hooks"].keys.sort
  end

  def test_merge_twice_does_not_duplicate
    once = merge(EXISTING)
    assert_equal once, merge(once)
  end

  def test_merge_into_empty_settings
    merged = merge({})
    assert_equal 4, merged["hooks"].size
  end

  def test_remove_restores_the_original
    assert_equal EXISTING, remove(merge(EXISTING))
  end

  def test_codex_hooks_merge_the_same_way
    merged = merge({ "hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "mine" }] }] } },
                   CODEX_HOOKS)
    assert_equal ["mine", "$HOME/.local/bin/coder-notify-remote hook codex"], commands(merged, "Stop")
    assert_includes merged["hooks"].keys, "PermissionRequest"
  end

  def test_examples_only_call_the_reporter_for_their_agent
    { CLAUDE_HOOKS => "claude", CODEX_HOOKS => "codex" }.each do |path, agent|
      hooks = JSON.parse(File.read(path))["hooks"]
      all = hooks.values.flatten.flat_map { |group| group["hooks"] }
      assert(all.all? { |hook| hook["command"] == "$HOME/.local/bin/coder-notify-remote hook #{agent}" })
    end
  end

  def test_tmux_conf_uses_its_own_hook_slot
    conf = File.read(File.join(REMOTE, "tmux/coder-notify.tmux.conf"))
    assert_includes conf, "set -g focus-events on"
    assert_match(/^set-hook -g pane-focus-in\[42\] 'run-shell -b /, conf)
    refute_match(/set-hook -g pane-focus-in '/, conf, "an unindexed set-hook would replace existing hooks")
  end
end
