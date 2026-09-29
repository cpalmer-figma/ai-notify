# Loaded by every test file: sets up Minitest and shared helpers.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "tmpdir"
require "json"
require "coder_notify"
require_relative "support/fakes"

module TestHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)

  def fixture(name) = File.read(File.join(FIXTURES, name))

  # A throwaway directory, deleted after the test.
  def tmpdir = @tmpdir ||= Dir.mktmpdir("coder-notify-test")

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir
    super
  end

  # Builds a valid event payload; override any field with keyword arguments.
  def payload(type: "waiting", **overrides)
    base = {
      "version" => 1,
      "event_id" => "evt-#{rand(1_000_000_000)}",
      "type" => type,
      "sent_at_ms" => 1_000,
      "agent" => "claude",
      "session_id" => "sess-1",
      "pane_id" => "%1",
      "pane_label" => "main:1.0"
    }
    base["reason"] = "permission" if type == "waiting"
    base.merge(overrides.transform_keys(&:to_s)).compact
  end

  def event(type: "waiting", **overrides)
    CoderNotify::Event.from_payload(payload(type: type, **overrides))
  end

  # A Service with no real Coder, notifications, SwiftBar or processes.
  def build_service(home, notifier_backend: nil, discovery: FakeDiscovery.new)
    CoderNotify::Service.new(
      config: CoderNotify::Config.new("CODER_NOTIFY_HOME" => home),
      logger: Logger.new(File::NULL),
      discovery: discovery,
      notifier_backend: notifier_backend,
      spawner: NullSpawner.new,
      menu_refresher: Object.new.tap { |fake| def fake.refresh = nil }
    )
  end

  def workspace(id: "ws-1", name: "alpha", build_status: "running", agent_status: "connected")
    CoderNotify::Workspace.new(id: id, name: name, owner: "me", build_status: build_status,
                               agent_name: "workspace", agent_status: agent_status)
  end
end

Minitest::Test.include(TestHelpers)
