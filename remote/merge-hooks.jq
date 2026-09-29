# Merges coder-notify's hooks into an existing Claude Code settings.json or
# Codex hooks.json, leaving every other setting and hook untouched.
#
#   jq -s -f merge-hooks.jq CURRENT.json ADDITIONS.json > NEW.json
#
# Existing coder-notify entries are removed before ours are appended, so
# running it twice doesn't create duplicates.

# True for a hook group that runs coder-notify-remote.
def coder_notify_group:
  (.hooks // []) | any((.command // "") | contains("coder-notify-remote"));

.[0] as $current
| .[1] as $additions
| $current
| .hooks = (
    reduce ($additions.hooks | to_entries[]) as $event
      ($current.hooks // {};
       .[$event.key] = (((.[$event.key] // []) | map(select(coder_notify_group | not))) + $event.value))
  )
