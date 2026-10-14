#!/bin/sh
# Runs via coder ssh, before the Mac creates a token or transfers credentials.
set -eu
expected_workspace=$1
agent=$2
deps=$3
PATH="$PATH:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export PATH

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "${CODER_WORKSPACE_NAME:-}" = "$expected_workspace" ] || fail "Workspace identity mismatch; expected $expected_workspace."

missing=""
set --
for tool in bash curl jq tmux tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing="$missing $tool"
    set -- "$@" "$tool"
  fi
done
if [ -n "$missing" ]; then
  [ "$deps" = install-deps ] || fail "Missing tools:$missing. Rerun with --install-deps to install them using apt-get."
  command -v apt-get >/dev/null 2>&1 || fail "Automatic dependency installation supports apt-get; install:$missing"
  if [ "$(id -u)" = 0 ]; then
    apt-get update >&2
    apt-get install -y --no-install-recommends "$@" >&2
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n apt-get update >&2
    sudo -n apt-get install -y --no-install-recommends "$@" >&2
  else
    fail "Installing$missing requires root or passwordless sudo."
  fi
fi

validate_json() {
  [ ! -e "$1" ] || jq -e 'type == "object" and ((.hooks // {}) | type == "object")' "$1" >/dev/null \
    || fail "Invalid hook configuration: $1 (left unchanged)."
}
if [ "$agent" = claude ] || [ "$agent" = both ]; then
  validate_json "$HOME/.claude/settings.json"
  if [ -f "$HOME/.claude/settings.json" ] && jq -e '.disableAllHooks == true' "$HOME/.claude/settings.json" >/dev/null; then
    fail "Claude hooks are disabled in settings.json; refusing to override that setting."
  fi
fi
if [ "$agent" = codex ] || [ "$agent" = both ]; then
  command -v codex >/dev/null 2>&1 || fail "Codex is not installed here. Use --agent claude, or install Codex first."
  validate_json "$HOME/.codex/hooks.json"
  features=$(codex features list 2>/dev/null) || fail "Cannot inspect Codex hook support."
  printf '%s\n' "$features" | grep -Eq '(^|[[:space:]])hooks[[:space:]].*true' || fail "This Codex version has hooks disabled or unsupported."
fi
printf 'Workspace identity, dependencies and selected hook configs checked.\n'
