#!/usr/bin/env bash
# Invoked from a private, short-lived staging directory populated over SSH stdin.
set -euo pipefail
umask 077
stage=$(cd -- "$(dirname -- "$0")" && pwd)
agent=$(cat "$stage/agent")
expected_workspace=$(cat "$stage/workspace")
PATH="$PATH:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export PATH

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "${CODER_WORKSPACE_NAME:-}" = "$expected_workspace" ] || fail "Workspace identity changed; refusing installation."
for tool in curl jq tmux; do command -v "$tool" >/dev/null || fail "Missing $tool."; done

config="$HOME/.config/coder-notify"
mkdir -p "$config" "$HOME/.local/bin"
chmod 700 "$config"
backup="$config/backups/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -p "$backup"

# Prepare all merged configs before replacing any settings files.
prepare_hooks() {
  local target=$1 additions=$2 output=$3
  if [ -e "$target" ]; then
    jq -e 'type == "object" and ((.hooks // {}) | type == "object")' "$target" >/dev/null || fail "Invalid JSON: $target"
    cp -p "$target" "$backup/$output.original"
    jq -s -f "$stage/merge-hooks.jq" "$target" "$stage/$additions" > "$stage/$output"
  else
    printf '{}\n' > "$stage/empty.json"
    jq -s -f "$stage/merge-hooks.jq" "$stage/empty.json" "$stage/$additions" > "$stage/$output"
  fi
}
if [ "$agent" = claude ] || [ "$agent" = both ]; then
  prepare_hooks "$HOME/.claude/settings.json" claude-hooks.json claude-settings.json
fi
if [ "$agent" = codex ] || [ "$agent" = both ]; then
  prepare_hooks "$HOME/.codex/hooks.json" codex-hooks.json codex-settings.json
fi

install_file() {
  local source=$1 target=$2 mode=$3
  local link count=0
  # Keep dotfile/config symlinks intact, updating their actual destination atomically.
  while [ -L "$target" ]; do
    count=$((count + 1))
    [ "$count" -le 20 ] || fail "Symlink loop: $target"
    link=$(readlink "$target")
    case "$link" in
      /*) target=$link ;;
      *) target="$(dirname -- "$target")/$link" ;;
    esac
  done
  mkdir -p "$(dirname -- "$target")"
  if [ -e "$target" ]; then cp -p "$target" "$backup/$(basename -- "$target").original"; fi
  local temporary
  temporary=$(mktemp "${target}.XXXXXX")
  cat "$source" > "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$target"
}

install_file "$stage/bin/coder-notify-remote" "$HOME/.local/bin/coder-notify-remote" 700
for file in env coder-notify.tmux.conf merge-hooks.jq remove-hooks.jq claude-hooks.json codex-hooks.json; do
  install_file "$stage/$file" "$config/$file" 600
done
if [ "$agent" = claude ] || [ "$agent" = both ]; then
  install_file "$stage/claude-settings.json" "$HOME/.claude/settings.json" 600
fi
if [ "$agent" = codex ] || [ "$agent" = both ]; then
  install_file "$stage/codex-settings.json" "$HOME/.codex/hooks.json" 600
  help=$(codex --help 2>/dev/null)
  if grep -q -- '--no-daemon' <<< "$help"; then
    cat > "$stage/coder-notify-codex" <<'WRAPPER'
#!/usr/bin/env bash
exec codex --no-daemon "$@"
WRAPPER
    install_file "$stage/coder-notify-codex" "$HOME/.local/bin/coder-notify-codex" 700
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      temporary=$(mktemp "$stage/rc.XXXXXX")
      if [ -e "$rc" ]; then
        awk '/^# BEGIN coder-notify$/ { skip=1; next } /^# END coder-notify$/ { skip=0; next } !skip' "$rc" > "$temporary"
      fi
      if grep -Eq '^[[:space:]]*(alias[[:space:]]+codex=|function[[:space:]]+codex|codex[[:space:]]*\(\))' "$temporary"; then
        printf 'Existing Codex alias/function in %s preserved. Use ~/.local/bin/coder-notify-codex for pane-aware hooks.\n' "$rc"
        continue
      fi
      cat >> "$temporary" <<'ALIAS'

# BEGIN coder-notify
alias codex='$HOME/.local/bin/coder-notify-codex'
# END coder-notify
ALIAS
      install_file "$temporary" "$rc" 600
    done
  fi
fi

touch "$HOME/.tmux.conf"
# Keep $HOME literal for tmux to expand when it reads this configuration.
# shellcheck disable=SC2016
source_line='source-file -q "$HOME/.config/coder-notify/coder-notify.tmux.conf"'
if ! grep -qF "$source_line" "$HOME/.tmux.conf" \
   && ! grep -qF 'source-file -q ~/.config/coder-notify/coder-notify.tmux.conf' "$HOME/.tmux.conf"; then
  cp -p "$HOME/.tmux.conf" "$backup/tmux.conf.original"
  printf '\n# coder-notify: clear alerts when a pane gains focus\n%s\n' "$source_line" >> "$HOME/.tmux.conf"
fi
chmod 600 "$HOME/.tmux.conf"
if tmux list-sessions >/dev/null 2>&1; then
  tmux source-file "$config/coder-notify.tmux.conf"
fi
printf 'Remote reporter, private token, selected hooks and tmux focus hook installed.\n'
printf 'Backups: %s\n' "$backup"
