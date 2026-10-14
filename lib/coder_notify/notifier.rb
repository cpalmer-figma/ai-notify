module CoderNotify
  # Human-readable text shared by notifications and the dashboard.
  module Labels
    AGENTS = { "claude" => "Claude", "codex" => "Codex" }.freeze
    REASONS = {
      "permission" => "Needs permission",
      "question" => "Asking a question",
      "done" => "Finished responding"
    }.freeze

    def self.agent(name) = AGENTS.fetch(name, name.to_s)
    def self.reason(code) = REASONS.fetch(code, code.to_s)
  end

  # Keeps macOS notifications in step with the sessions that need attention.
  #
  # Instead of reacting to individual events, #sync compares "what needs
  # attention now" with "what we have posted" and fixes the difference. That
  # one rule covers every way an alert can go away: pane focus, resume, Dismiss,
  # session end, sync after reconnect, or workspace deletion.
  #
  # Each agent instance gets a stable notification group id, so a new alert
  # for the same instance replaces the old one, and removing the group clears
  # it from Notification Center.
  class Notifier
    def initialize(backend:, logger: nil)
      @backend = backend # nil when notifications are disabled
      @logger = logger
      @posted = {} # group id => episode we posted a notification for
    end

    def self.group_id(session) = "coder-notify|#{session.key}"

    # Call once at startup: treat alerts that already needed attention before
    # a restart as posted, so restarting the service doesn't re-alert you.
    def adopt(sessions)
      sessions.select(&:attention?).each { |s| @posted[self.class.group_id(s)] = s.episode }
    end

    def sync(sessions)
      return if @backend.nil?

      wanted = sessions.select(&:attention?).to_h { |s| [self.class.group_id(s), s] }

      (@posted.keys - wanted.keys).each do |group|
        @backend.remove(group)
        @posted.delete(group)
      end

      wanted.each do |group, session|
        next if @posted[group] == session.episode

        @backend.notify(group: group, **text_for(session))
        @posted[group] = session.episode
      end
    rescue StandardError => e
      # Notifications are optional; never let them break the service.
      @logger&.warn("notification failed: #{e.class}: #{e.message}")
    end

    def text_for(session)
      {
        title: "#{Labels.agent(session.agent)} on #{session.workspace_name}",
        subtitle: "tmux #{session.pane_label || session.pane_id}",
        message: "#{Labels.reason(session.reason)}. Switch to the pane to clear this."
      }
    end
  end

  # The real notification backend, using the terminal-notifier gem. The gem
  # bundles a signed universal terminal-notifier.app and runs it directly (no
  # shell), so message text is passed through safely.
  class TerminalNotifierBackend
    # terminal-notifier exits with 3 when macOS hasn't allowed it to notify.
    NOT_AUTHORIZED_EXIT = 3

    def initialize(activate_bundle_id:)
      require "terminal-notifier"
      @activate = activate_bundle_id
    end

    def available? = TerminalNotifier.available?

    def notify(group:, title:, subtitle:, message:)
      # -activate brings your terminal forward when you click the notification.
      ok = TerminalNotifier.notify(message, title: title, subtitle: subtitle, group: group,
                                            activate: @activate, sound: "default")
      raise failure_message unless ok
    end

    def remove(group) = TerminalNotifier.remove(group)

    private

    def failure_message
      code = TerminalNotifier.last_status&.exitstatus
      hint = code == NOT_AUTHORIZED_EXIT ? " (not allowed: check System Settings > Notifications)" : ""
      "terminal-notifier exited with #{code.inspect}#{hint}"
    end
  end
end
