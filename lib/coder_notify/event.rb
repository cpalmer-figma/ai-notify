module CoderNotify
  # One validated event from a remote hook script.
  #
  # Payloads are deliberately tiny: identifiers and a reason code only. We
  # never accept prompt text, transcripts, or tool input, and anything we
  # don't recognise is rejected rather than stored.
  Event = Data.define(
    :id,             # unique per event; lets us drop duplicates and replays
    :type,           # see TYPES
    :sent_at_ms,     # remote clock, milliseconds since epoch; used for ordering
    :agent,          # "claude" or "codex" (not needed for acknowledged/sync)
    :session_id,     # the agent's own session/thread id
    :pane_id,        # tmux pane id such as "%12"
    :pane_label,     # human label such as "main:1.0" (session:window.pane)
    :reason,         # why the agent is waiting (waiting events only)
    :focused,        # true if the pane was already in front of you
    :panes,          # sync only: [{pane_id:, pane_label:}, ...] alive right now
    :workspace_name  # what the remote thinks it is called; checked against the token
  )

  # We reopen the class to add constants and methods. (Constants written inside
  # a `Data.define do ... end` block would land on the enclosing module
  # instead, which is a classic Ruby surprise.)
  class Event
    # waiting      - the agent needs you (finished, or asking permission)
    # resumed      - you submitted a new prompt, so the agent is working again
    # acknowledged - you focused the tmux pane; the alert is seen, not resolved
    # ended        - the agent session exited
    # sync         - sent after a tunnel (re)connects: the panes that still exist
    TYPES = %w[waiting resumed acknowledged ended sync].freeze
    AGENTS = %w[claude codex].freeze
    REASONS = %w[permission question done].freeze

    ID_FORMAT = /\A[A-Za-z0-9._:-]{1,100}\z/
    PANE_ID_FORMAT = /\A%\d{1,6}\z/
    # Printable text without control characters, so it is safe to put in the menu.
    LABEL_FORMAT = /\A[[:print:]]{1,80}\z/
    MAX_PANES = 500

    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.join("; "))
      end
    end

    # Validates a parsed JSON hash and returns an Event, or raises Invalid
    # with every problem found (easier to debug than one error at a time).
    def self.from_payload(payload)
      raise Invalid, ["body must be a JSON object"] unless payload.is_a?(Hash)

      errors = []
      type = payload["type"]
      errors << "version must be 1" unless payload["version"] == 1
      errors << "type must be one of #{TYPES.join(', ')}" unless TYPES.include?(type)
      errors << "event_id is missing or malformed" unless payload["event_id"].to_s.match?(ID_FORMAT)
      errors << "sent_at_ms must be an integer" unless payload["sent_at_ms"].is_a?(Integer)

      if %w[waiting resumed ended].include?(type)
        errors << "agent must be one of #{AGENTS.join(', ')}" unless AGENTS.include?(payload["agent"])
        errors << "session_id is missing or malformed" unless payload["session_id"].to_s.match?(ID_FORMAT)
      end
      if type == "waiting" && !REASONS.include?(payload["reason"])
        errors << "reason must be one of #{REASONS.join(', ')}"
      end
      if type != "sync"
        errors << "pane_id must look like %12" unless payload["pane_id"].to_s.match?(PANE_ID_FORMAT)
        errors << "pane_label is malformed" unless optional_label?(payload["pane_label"])
      end
      errors << "focused must be true or false" unless [nil, true, false].include?(payload["focused"])
      errors << "workspace_name is malformed" unless optional_label?(payload["workspace_name"])

      panes = type == "sync" ? parse_panes(payload["panes"], errors) : nil
      raise Invalid, errors if errors.any?

      new(
        id: payload["event_id"],
        type: type,
        sent_at_ms: payload["sent_at_ms"],
        agent: payload["agent"],
        session_id: payload["session_id"],
        pane_id: payload["pane_id"],
        pane_label: payload["pane_label"],
        reason: payload["reason"],
        focused: payload["focused"] == true,
        panes: panes,
        workspace_name: payload["workspace_name"]
      )
    end

    def self.optional_label?(value) = value.nil? || value.to_s.match?(LABEL_FORMAT)

    def self.parse_panes(list, errors)
      unless list.is_a?(Array) && list.size <= MAX_PANES
        errors << "panes must be an array of at most #{MAX_PANES} entries"
        return []
      end

      list.filter_map do |pane|
        valid = pane.is_a?(Hash) && pane["pane_id"].to_s.match?(PANE_ID_FORMAT) && optional_label?(pane["pane_label"])
        next { pane_id: pane["pane_id"], pane_label: pane["pane_label"] } if valid

        errors << "panes contains a malformed entry"
        nil
      end
    end
  end
end
