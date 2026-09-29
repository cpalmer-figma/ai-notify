# Removes coder-notify's hooks from a Claude Code settings.json or Codex
# hooks.json, leaving every other setting and hook untouched.
#
#   jq -f remove-hooks.jq CURRENT.json > NEW.json

def coder_notify_group:
  (.hooks // []) | any((.command // "") | contains("coder-notify-remote"));

if .hooks then
  .hooks |= (
    with_entries(.value |= map(select(coder_notify_group | not)))
    | with_entries(select(.value | length > 0))
  )
else . end
