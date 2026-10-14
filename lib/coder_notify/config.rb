require "fileutils"

module CoderNotify
  # All tunable settings live here, read from environment variables with
  # sensible defaults. Keeping them in one small object makes it easy for tests
  # to build a Config pointing at a temporary directory.
  class Config
    attr_reader :home, :port, :remote_port, :coder_bin, :discovery_interval,
                :notifications, :activate_bundle_id

    def initialize(env = ENV)
      # Directory for tokens, persisted state and logs.
      @home = File.expand_path(env.fetch("CODER_NOTIFY_HOME", "~/.coder-notify"))
      # Port the Sinatra service listens on (always on 127.0.0.1).
      @port = Integer(env.fetch("CODER_NOTIFY_PORT", "47290"))
      # Port that the reverse tunnel opens on each workspace's 127.0.0.1.
      @remote_port = Integer(env.fetch("CODER_NOTIFY_REMOTE_PORT", "47290"))
      # launchd starts us with a minimal PATH, so allow an absolute path here.
      @coder_bin = env.fetch("CODER_BIN", "coder")
      # Seconds between `coder list` runs.
      @discovery_interval = Integer(env.fetch("CODER_NOTIFY_DISCOVERY_INTERVAL", "60"))
      # Set CODER_NOTIFY_NOTIFICATIONS=0 to run with the dashboard only.
      @notifications = env.fetch("CODER_NOTIFY_NOTIFICATIONS", "1") != "0"
      # App brought to the front when you click a notification.
      @activate_bundle_id = env.fetch("CODER_NOTIFY_ACTIVATE", "com.mitchellh.ghostty")
    end

    def tokens_path = File.join(home, "tokens.json")
    def state_path = File.join(home, "state.json")
    def menu_token_path = File.join(home, "menu-token")
    def log_dir = File.join(home, "logs")

    def ensure_home!
      FileUtils.mkdir_p(home, mode: 0o700)
      FileUtils.mkdir_p(log_dir, mode: 0o700)
    end
  end
end
