require_relative "test_helper"
require "stringio"

class NotifierTest < Minitest::Test
  def setup
    @backend = FakeNotifierBackend.new
    @notifier = CoderNotify::Notifier.new(backend: @backend)
    @store = CoderNotify::SessionStore.new(path: File.join(tmpdir, "state.json"))
  end

  def apply(**fields) = @store.apply(event(**fields), workspace_id: "ws-1", workspace_name: "alpha")
  def sync = @notifier.sync(@store.sessions)
  def group = "coder-notify|ws-1|%1|claude|sess-1"

  def test_posts_one_notification_per_waiting_agent_with_a_stable_group
    apply(type: "waiting", reason: "permission")
    sync

    assert_equal 1, @backend.posted.size
    posted = @backend.posted.first
    assert_equal group, posted[:group]
    assert_equal "Claude on alpha", posted[:title]
    assert_equal "tmux main:1.0", posted[:subtitle]
    assert_match(/Needs permission/, posted[:message])
  end

  def test_does_not_repost_the_same_wait
    apply(type: "waiting")
    sync
    sync
    assert_equal 1, @backend.posted.size
  end

  def test_focusing_the_pane_removes_the_notification
    apply(type: "waiting", sent_at_ms: 1_000)
    sync
    apply(type: "acknowledged", sent_at_ms: 2_000)
    sync

    assert_equal [group], @backend.removed
  end

  def test_resuming_removes_the_notification
    apply(type: "waiting", sent_at_ms: 1_000)
    sync
    apply(type: "resumed", sent_at_ms: 2_000)
    sync
    assert_equal [group], @backend.removed
  end

  def test_a_new_wait_for_the_same_agent_replaces_the_notification
    apply(type: "waiting", reason: "permission", sent_at_ms: 1_000)
    sync
    apply(type: "waiting", reason: "done", sent_at_ms: 2_000)
    sync

    assert_equal [group, group], @backend.posted.map { |p| p[:group] }
    assert_match(/Finished responding/, @backend.posted.last[:message])
  end

  def test_already_seen_wait_is_not_posted
    apply(type: "waiting", focused: true)
    sync
    assert_empty @backend.posted
  end

  def test_adopting_after_restart_does_not_re_alert_but_still_clears
    apply(type: "waiting", sent_at_ms: 1_000)
    @notifier.adopt(@store.sessions)
    sync
    assert_empty @backend.posted

    apply(type: "acknowledged", sent_at_ms: 2_000)
    sync
    assert_equal [group], @backend.removed
  end

  def test_disabled_notifications_do_nothing
    apply(type: "waiting")
    CoderNotify::Notifier.new(backend: nil).sync(@store.sessions)
    assert_empty @backend.posted
  end

  def test_backend_errors_are_logged_not_raised
    failing = Object.new
    def failing.notify(**) = raise("terminal-notifier exited with 3")
    log = StringIO.new
    notifier = CoderNotify::Notifier.new(backend: failing, logger: Logger.new(log))
    apply(type: "waiting")

    notifier.sync(@store.sessions)
    assert_match(/notification failed.*exited with 3/, log.string)
  end
end
