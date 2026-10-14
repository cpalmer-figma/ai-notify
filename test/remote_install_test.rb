require_relative "test_helper"
require "open3"
require_relative "../lib/coder_notify/workspace_setup"

class RemoteInstallTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    skip "jq is not installed" unless system("command -v jq >/dev/null 2>&1")
    @home = File.join(tmpdir, "home")
    @stage = File.join(tmpdir, "stage")
    @tools = File.join(tmpdir, "tools")
    FileUtils.mkdir_p([@home, @stage, @tools, File.join(@stage, "bin")])
    CoderNotify::WorkspaceSetup::FILES.each do |source, destination|
      FileUtils.cp(File.join(ROOT, "remote", source), File.join(@stage, destination))
    end
    File.write(File.join(@stage, "workspace"), "alpha")
    File.write(File.join(@stage, "agent"), "both")
    File.write(File.join(@stage, "env"), "CODER_NOTIFY_URL=http://127.0.0.1:47290\nCODER_NOTIFY_TOKEN=test-secret\n")
    write_tool("tmux", '#!/bin/sh' + "\nexit 1\n") # No live server; tests must not touch real tmux.
    write_tool("codex", <<~SH)
      #!/bin/sh
      case "$1" in
        features) echo 'hooks stable true' ;;
        --help) echo '--no-daemon' ;;
      esac
    SH
    @env = { "HOME" => @home, "PATH" => "#{@tools}:#{ENV.fetch('PATH')}", "CODER_WORKSPACE_NAME" => "alpha" }
  end

  def write_tool(name, contents)
    path = File.join(@tools, name)
    File.write(path, contents)
    File.chmod(0o700, path)
  end

  def install
    Open3.capture3(@env, "bash", File.join(@stage, "install.sh"))
  end

  def test_real_installer_preserves_settings_repeats_safely_and_keeps_token_private
    FileUtils.mkdir_p(File.join(@home, ".claude"))
    original = { "model" => "opus", "hooks" => { "Stop" => [{ "hooks" => [{ "command" => "say done" }] }] } }
    settings = File.join(@home, ".claude/settings.json")
    File.write(settings, JSON.generate(original))
    File.write(File.join(@home, ".tmux.conf"), "set -g mouse on\n")
    File.write(File.join(@home, ".bashrc"), "export MY_SETTING=keep\n")
    stdout, stderr, status = install
    assert status.success?, stderr
    refute_includes stdout + stderr, "test-secret"
    first = JSON.parse(File.read(settings))
    assert_equal "opus", first["model"]
    assert_equal "say done", first.dig("hooks", "Stop", 0, "hooks", 0, "command")
    assert_equal 2, first.dig("hooks", "Stop").size
    _, stderr, status = install
    assert status.success?, stderr
    assert_equal first, JSON.parse(File.read(settings))
    tmux = File.read(File.join(@home, ".tmux.conf"))
    assert_includes tmux, "set -g mouse on"
    assert_equal 1, tmux.scan(/^source-file/).size
    rc = File.read(File.join(@home, ".bashrc"))
    assert_includes rc, "export MY_SETTING=keep"
    assert_equal 1, rc.scan(/^alias codex=/).size
    assert File.executable?(File.join(@home, ".local/bin/coder-notify-remote"))
    assert File.executable?(File.join(@home, ".local/bin/coder-notify-codex"))
    assert_equal 0o600, File.stat(File.join(@home, ".config/coder-notify/env")).mode & 0o777
    assert Dir.glob(File.join(@home, ".config/coder-notify/backups/*/claude-settings.json.original")).any?
  end

  def test_invalid_json_stops_before_replacing_reporter_or_config
    FileUtils.mkdir_p(File.join(@home, ".claude"))
    settings = File.join(@home, ".claude/settings.json")
    File.write(settings, "broken json")
    _, _, status = install
    refute status.success?
    assert_equal "broken json", File.read(settings)
    refute File.exist?(File.join(@home, ".local/bin/coder-notify-remote"))
  end

  def test_existing_codex_alias_is_preserved
    File.write(File.join(@home, ".bashrc"), "alias codex='my-custom-codex'\n")
    _, stderr, status = install
    assert status.success?, stderr
    assert_equal "alias codex='my-custom-codex'\n", File.read(File.join(@home, ".bashrc"))
  end

  def test_dotfile_symlinks_are_preserved
    destination = File.join(@home, "dotfiles-bashrc")
    File.write(destination, "export ORIGINAL=yes\n")
    File.symlink("dotfiles-bashrc", File.join(@home, ".bashrc"))
    _, stderr, status = install
    assert status.success?, stderr
    assert File.symlink?(File.join(@home, ".bashrc"))
    assert_includes File.read(destination), "export ORIGINAL=yes"
    assert_includes File.read(destination), "alias codex="
  end

  def test_workspace_mismatch_stops_without_writes
    @env["CODER_WORKSPACE_NAME"] = "wrong"
    _, _, status = install
    refute status.success?
    refute File.exist?(File.join(@home, ".config/coder-notify"))
  end

  def test_preflight_rejects_invalid_config_and_checks_workspace_identity
    FileUtils.mkdir_p(File.join(@home, ".codex"))
    File.write(File.join(@home, ".codex/hooks.json"), "broken")
    _, stderr, status = Open3.capture3(@env, "sh", File.join(ROOT, "remote/preflight.sh"), "alpha", "both", "check-only")
    refute status.success?
    assert_includes stderr, "Invalid hook configuration"
    _, stderr, status = Open3.capture3(@env, "sh", File.join(ROOT, "remote/preflight.sh"), "other", "claude", "check-only")
    refute status.success?
    assert_includes stderr, "identity mismatch"
  end
end
