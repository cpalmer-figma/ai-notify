require_relative "json_file"

module CoderNotify
  # The heart of the app: what each agent instance is doing right now.
  #
  # An agent instance is identified by
  #   Coder workspace id + tmux pane id + agent type + agent session id.
  #
  # Each instance is either "working" or "waiting". A waiting instance needs
  # your attention until you acknowledge it (by focusing its tmux pane or
  # clicking Dismiss) or it resumes. Acknowledging does NOT mark it as
  # working: it just means "I've seen it". That keeps "I looked at the pane"
  # separate from "the agent actually got what it needed".
  #
  # Every public method is thread-safe: Puma handles requests on several
  # threads, and the background discovery thread also calls in here.
  class SessionStore
    Session = Data.define(
      :key, :workspace_id, :workspace_name, :agent, :session_id, :pane_id, :pane_label,
      :status,             # "waiting" or "working"
      :reason,             # why it is waiting: "permission", "question" or "done"
      :waiting_since_ms,   # when the current wait started (remote clock)
      :acknowledged_at_ms, # when you saw it; nil means it still needs attention
      :updated_at_ms       # sent_at_ms of the newest event applied; used for ordering
    ) do
      def self.key_for(workspace_id, pane_id, agent, session_id)
        [workspace_id, pane_id, agent, session_id].join("|")
      end

      def self.from_h(hash) = new(**hash.transform_keys(&:to_sym))

      def waiting? = status == "waiting"
      def attention? = waiting? && acknowledged_at_ms.nil?

      # A stable id for "this particular wait". The notifier uses it to tell a
      # brand new wait (post a fresh notification) from one it already posted.
      def episode = attention? ? "#{key}@#{waiting_since_ms}" : nil
    end

    # How many recent event ids to remember for duplicate detection.
    SEEN_LIMIT = 2000
    # Pane focus times older than this are forgotten.
    PANE_ACK_TTL_MS = 10 * 60 * 1000

    def initialize(path:, clock: -> { Time.now })
      @path = path
      @clock = clock
      @mutex = Mutex.new
      # [workspace_id, pane_id] => sent_at_ms of the latest "acknowledged".
      # Remembered so a "waiting" event that arrives late (after the focus
      # event, although it was sent before it) is treated as already seen.
      @pane_acks = {}
      load
    end

    def sessions = @mutex.synchronize { @sessions.values.sort_by { |s| [-(s.waiting_since_ms || 0), s.key] } }
    def attention = sessions.select(&:attention?)

    # Applies an event that was sent by +workspace+ (already authenticated).
    # Returns :applied, :duplicate, :stale or :unchanged.
    def apply(event, workspace_id:, workspace_name:)
      @mutex.synchronize do
        return :duplicate if @seen_ids.include?(event.id)

        remember(event.id)
        outcome =
          case event.type
          when "waiting", "resumed", "ended" then apply_agent_event(event, workspace_id, workspace_name)
          when "acknowledged" then acknowledge_pane(event, workspace_id)
          when "sync" then sync_panes(event, workspace_id)
          end
        save
        outcome
      end
    end

    # "Dismiss" from the menu: mark one waiting session as seen.
    def dismiss(key)
      @mutex.synchronize do
        session = @sessions[key]
        return :unchanged unless session&.attention?

        @sessions[key] = session.with(acknowledged_at_ms: now_ms)
        save
        :applied
      end
    end

    def dismiss_all
      @mutex.synchronize do
        @sessions.transform_values! { |s| s.attention? ? s.with(acknowledged_at_ms: now_ms) : s }
        save
        :applied
      end
    end

    # Forget every session on a workspace that was deleted or stopped.
    def remove_workspace(workspace_id)
      @mutex.synchronize do
        before = @sessions.size
        @sessions.delete_if { |_key, s| s.workspace_id == workspace_id }
        save if @sessions.size != before
      end
    end

    private

    def apply_agent_event(event, workspace_id, workspace_name)
      key = Session.key_for(workspace_id, event.pane_id, event.agent, event.session_id)
      current = @sessions[key]
      # Events can arrive out of order (they are sent in the background, and
      # replayed after an outage). Never let an older event undo a newer one.
      return :stale if current && event.sent_at_ms < current.updated_at_ms

      # A tmux pane runs one agent at a time. If a new session shows up in a
      # pane, older sessions there have exited (maybe without telling us).
      @sessions.delete_if do |other_key, other|
        other_key != key && other.workspace_id == workspace_id &&
          other.pane_id == event.pane_id && other.updated_at_ms <= event.sent_at_ms
      end

      if event.type == "ended"
        @sessions.delete(key)
        return :applied
      end

      waiting = event.type == "waiting"
      @sessions[key] = Session.new(
        key: key,
        workspace_id: workspace_id,
        workspace_name: workspace_name,
        agent: event.agent,
        session_id: event.session_id,
        pane_id: event.pane_id,
        pane_label: event.pane_label || current&.pane_label,
        status: waiting ? "waiting" : "working",
        reason: waiting ? event.reason : nil,
        waiting_since_ms: waiting ? event.sent_at_ms : nil,
        acknowledged_at_ms: waiting ? already_seen_at(event, workspace_id) : nil,
        updated_at_ms: event.sent_at_ms
      )
      :applied
    end

    # A new wait counts as already seen if the pane was in front of you when
    # it started, or if you focused the pane after it started.
    def already_seen_at(event, workspace_id)
      return event.sent_at_ms if event.focused

      focused_at = @pane_acks[[workspace_id, event.pane_id]]
      focused_at if focused_at && focused_at >= event.sent_at_ms
    end

    def acknowledge_pane(event, workspace_id)
      pane = [workspace_id, event.pane_id]
      @pane_acks[pane] = [@pane_acks[pane].to_i, event.sent_at_ms].max
      @pane_acks.delete_if { |_pane, at_ms| at_ms < event.sent_at_ms - PANE_ACK_TTL_MS }

      changed = false
      @sessions.transform_values! do |session|
        # Only acknowledge waits that started before you focused the pane.
        if session.workspace_id == workspace_id && session.pane_id == event.pane_id &&
           session.attention? && session.waiting_since_ms <= event.sent_at_ms
          changed = true
          session.with(acknowledged_at_ms: event.sent_at_ms)
        else
          session
        end
      end
      changed ? :applied : :unchanged
    end

    # After a tunnel reconnects, the remote reports which tmux panes still
    # exist. Sessions in panes that are gone cannot be waiting any more.
    def sync_panes(event, workspace_id)
      labels = event.panes.to_h { |pane| [pane[:pane_id], pane[:pane_label]] }
      before = @sessions.dup

      @sessions.delete_if do |_key, session|
        session.workspace_id == workspace_id && !labels.key?(session.pane_id) &&
          session.updated_at_ms < event.sent_at_ms
      end
      # Also refresh labels, in case you renamed a tmux session or window.
      @sessions.transform_values! do |session|
        label = labels[session.pane_id]
        session.workspace_id == workspace_id && label ? session.with(pane_label: label) : session
      end

      @sessions == before ? :unchanged : :applied
    end

    def remember(id)
      @seen_ids << id
      @seen_ids.shift while @seen_ids.size > SEEN_LIMIT
    end

    def now_ms = (@clock.call.to_f * 1000).to_i

    def load
      data = JsonFile.read(@path, {})
      @sessions = (data["sessions"] || []).to_h do |hash|
        session = Session.from_h(hash)
        [session.key, session]
      end
      @seen_ids = data["seen_event_ids"] || []
    end

    def save
      JsonFile.write(@path, {
        "sessions" => @sessions.values.map { |s| s.to_h.transform_keys(&:to_s) },
        "seen_event_ids" => @seen_ids
      })
    end
  end
end
