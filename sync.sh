#!/usr/bin/env bash
# pi-list-sync — one job: keep the pi tool list and skill list identical
# on every machine, through this git repo.
#
#   ./sync.sh save            local pi setup -> repo (no commit)
#   ./sync.sh push            save + commit + git push + ship to every host in hosts.txt + apply there
#   ./sync.sh push-if-changed same, but exits early when nothing changed (hook uses this)
#   ./sync.sh apply           repo -> this machine's ~/.pi/agent and ~/.agents
#   ./sync.sh pull            git pull + apply (other machines' changes land here)
#   ./sync.sh hook            allow pi's session-end hook to run push-if-changed here
#   ./sync.sh auto            backstop: schedule a full push hourly (launchd / cron)
#   ./sync.sh bootstrap       install node+pi if missing, then apply (fresh server)
#
# Never synced, ever: auth.json, models-store.json, web-search.json,
# mcp-cache.json, mcp-onboarding.json, trust.json, sessions, npm/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI="${PI_AGENT_DIR:-$HOME/.pi/agent}"
LIB="${AGENTS_DIR:-$HOME/.agents}"
HOSTS_FILE="$ROOT/hosts.txt"
REMOTE_DIR=".pi-list"          # repo mirror on each host, relative to its $HOME
INTERVAL="${SYNC_INTERVAL:-3600}"
SECRETS_RE='"apiKey"[[:space:]]*:[[:space:]]*"[^"]+"|sk-[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}'

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# The package checkout is code-only; run copies of these scripts in a private repo.
[ ! -f "$ROOT/.code-only" ] || die "code-only package: copy sync.sh and brief.py into a separate private snapshot repo first"

RSYNC_EXCLUDES=(--exclude .git --exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store --exclude '._*')

# tar instead of rsync: hosts have no rsync, and macOS openrsync (protocol 29)
# cannot talk to GNU rsync 3.x. copy_dir SRC DST preserves modes, needs nothing.
copy_dir() {
  local from="${1%/}" to="$2" flags="-cf"
  [ "$(uname -s)" = Darwin ] && flags="--no-xattrs -cf"
  mkdir -p "$to"
  # shellcheck disable=SC2086
  tar $flags - -C "$from" . | tar -xf - -C "$to"
}

# json on stdin -> json on stdout with credential-ish fields removed
redact() {
  python3 -c '
import json, sys
bad = {"apiKey", "api_key", "apikey", "key", "token", "accessToken",
       "refreshToken", "secret", "password", "bearerToken"}
def scrub(v):
    if isinstance(v, dict):  return {k: scrub(x) for k, x in v.items() if k not in bad}
    if isinstance(v, list):  return [scrub(x) for x in v]
    return v
json.dump(scrub(json.load(sys.stdin)), sys.stdout, indent=2)
print()
'
}

save() {
  say "== save: $PI -> $ROOT"
  mkdir -p "$ROOT/pi/skills" "$ROOT/library"
  for f in settings.json mcp.json; do
    [ -f "$PI/$f" ] && cp "$PI/$f" "$ROOT/pi/$f" || true
  done
  [ -f "$PI/models.json" ] && redact <"$PI/models.json" >"$ROOT/pi/models.json" || true
  mkdir -p "$ROOT/pi/extensions"
  [ -d "$PI/extensions" ] && rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$PI/extensions/" "$ROOT/pi/extensions/" || true

  : >"$ROOT/pi/skills.txt"
  for e in "$PI"/skills/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    n="$(basename "$e")"
    if [ -L "$e" ]; then
      printf '%s\n' "$n" >>"$ROOT/pi/skills.txt"
    else
      rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$e" "$ROOT/pi/skills/$n"
    fi
  done
  sort -u -o "$ROOT/pi/skills.txt" "$ROOT/pi/skills.txt"

  mkdir -p "$ROOT/library/skills"
  [ -d "$LIB/skills" ] && rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$LIB/skills/" "$ROOT/library/skills/" || true

  say "   skills exposed: $(wc -l <"$ROOT/pi/skills.txt" | tr -d ' ')   library: $(ls "$ROOT/library/skills" | wc -l | tr -d ' ')"

  # uninstalled skills and tools: drop the repo copies too, so the commit is a deletion
  for d in "$ROOT"/pi/skills/*; do
    [ -e "$d" ] || continue
    grep -qxF "$(basename "$d")" "$ROOT/pi/skills.txt" || rm -rf "$d"
  done

  if [ -f "$ROOT/brief.py" ]; then
    python3 "$ROOT/brief.py" "$ROOT" && say "   brief refreshed"
  fi
}

apply() {
  say "== apply: repo -> $PI"
  mkdir -p "$PI" "$LIB/skills"

  for f in settings.json; do
    [ -f "$ROOT/pi/$f" ] && cp "$ROOT/pi/$f" "$PI/$f" || true
  done
  [ -d "$ROOT/pi/extensions" ] && copy_dir "$ROOT/pi/extensions" "$PI/extensions" || true

  if [ -f "$ROOT/pi/mcp.json" ]; then
    python3 - "$ROOT/pi/mcp.json" "$PI/mcp.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
cfg = json.load(open(src))
servers = cfg.get("mcpServers", {})
keep = {}
for name, spec in servers.items():
    cmd = str(spec.get("command", ""))
    if cmd.startswith("/") and not os.path.exists(cmd):
        print(f"   skipped mcp server {name!r}: {cmd} is not on this host")
    else:
        keep[name] = spec
cfg["mcpServers"] = keep
json.dump(cfg, open(dst, "w"), indent=2)
PY
  fi

  # models.json may hold this host's own keys: never clobber it
  if [ -f "$ROOT/pi/models.json" ]; then
    if [ -f "$PI/models.json" ]; then
      cmp -s "$ROOT/pi/models.json" "$PI/models.json" ||
        say "   kept local models.json (repo copy left at $ROOT/pi/models.json)"
    else
      cp "$ROOT/pi/models.json" "$PI/models.json"
    fi
  fi

  copy_dir "$ROOT/library/skills" "$LIB/skills"
  # AppleDouble litter from earlier mac tar runs; never user data
  find "$LIB/skills" "$PI/skills" "$ROOT" -name '._*' -delete 2>/dev/null || true

  mkdir -p "$PI/skills"
  # drop stale links into the library that are no longer exposed
  for l in "$PI"/skills/*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l")" in
      */skills/*)
        grep -qxF "$(basename "$l")" "$ROOT/pi/skills.txt" || rm -f "$l" ;;
    esac
  done
  while IFS= read -r n; do
    [ -n "$n" ] && ln -sfn "$LIB/skills/$n" "$PI/skills/$n" || true
  done <"$ROOT/pi/skills.txt"
  for d in "$ROOT"/pi/skills/*; do
    [ -e "$d" ] && copy_dir "$d" "$PI/skills/$(basename "$d")" || true
  done

  if command -v pi >/dev/null 2>&1; then
    say "== installing declared packages (pi update --extensions)"
    pi update --extensions || say "   pi update --extensions failed (offline?) — config is in place, rerun later"
  else
    say "pi is not on PATH here — run: npm i -g @earendil-works/pi-coding-agent   then: $0 apply"
  fi
}

hosts() {
  [ -f "$HOSTS_FILE" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$HOSTS_FILE" | grep -v '^[[:space:]]*$' || true
}

push() {
  local mode="${1:-full}" lock="$ROOT/.lock.d"
  # two sessions ending at once must not interleave writes into the same repo
  # a lock older than 10 min is from a killed run, not a live one
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rm -rf "$lock"
  fi
  mkdir "$lock" 2>/dev/null || { say "== another sync is already running"; return 0; }
  trap "rmdir '$lock' 2>/dev/null || true" EXIT
  save
  cd "$ROOT"
  git add -A
  # Inspect the whole staged tree, not just additions or the config directory.
  local scan_status=0
  git grep --cached -I -l -E "$SECRETS_RE" -- . >/dev/null || scan_status=$?
  if [ "$scan_status" = 0 ]; then
    git reset -q
    die "refusing to commit: a possible credential showed up in the staged snapshot. nothing pushed."
  fi
  [ "$scan_status" = 1 ] || die "could not scan the staged snapshot; nothing pushed"

  if git diff --cached --quiet; then
    say "== no config changes"
    # hook path: nothing local, and origin already has our HEAD -> skip the big ship
    if [ "$mode" = changed ] &&
      git ls-remote origin main | grep -q "^$(git rev-parse HEAD)"; then
      return 0
    fi
  else
    git commit -q -m "sync $(date -u +%FT%TZ)"
    say "== committed $(git rev-parse --short HEAD)"
  fi
  # also covers an earlier commit that never made it to origin
  git push -q origin main
  say "== pushed to origin/main"

  while IFS= read -r h; do
    say "== $h"
    # tar over ssh: macOS openrsync (protocol 29) cannot talk to GNU rsync 3.x
    # both flags: --no-xattrs keeps pax noise out, --no-mac-metadata stops the
    # AppleDouble ._* files macOS tar otherwise writes
    local tar_flags=()
    [ "$(uname -s)" != Darwin ] || tar_flags=(--no-xattrs --no-mac-metadata)
    tar "${tar_flags[@]}" -czf - -C "$ROOT" --exclude .git --exclude hosts.txt --exclude .hook --exclude .lock.d . |
      ssh "$h" "mkdir -p \"\$HOME/$REMOTE_DIR\" && tar xzf - -C \"\$HOME/$REMOTE_DIR\""
    ssh -n "$h" "cd \"\$HOME/$REMOTE_DIR\" && bash sync.sh apply"
  done < <(hosts)
}

pull() {
  say "== pull: origin -> $ROOT"
  git -C "$ROOT" pull -q --ff-only || die "pull failed (local commits? run ./sync.sh push first)"
  apply
}

auto() {
  case "$(uname -s)" in
    Darwin)
      local label="dev.pi-list.sync" plist="$HOME/Library/LaunchAgents/dev.pi-list.sync.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ROOT/sync.sh</string><string>push</string></array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.pi-sync.log</string>
  <key>StandardErrorPath</key><string>$HOME/.pi-sync.log</string>
</dict></plist>
EOF
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
      say "== launchd job $label every ${INTERVAL}s, log $HOME/.pi-sync.log"
      ;;
    *)
      ( crontab -l 2>/dev/null | grep -v "my-awesome-pi-list/sync.sh push" || true
        echo "*/$((INTERVAL / 60)) * * * * cd $ROOT && ./sync.sh push >> \$HOME/.pi-sync.log 2>&1"
      ) | crontab -
      say "== cron entry every $((INTERVAL / 60)) min, log \$HOME/.pi-sync.log"
      ;;
  esac
}

bootstrap() {
  if ! command -v node >/dev/null 2>&1; then
    say "== no node, installing via nvm"
    [ -s "$HOME/.nvm/nvm.sh" ] || {
      NVM_VER="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest |
        grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)"
      [ -n "$NVM_VER" ] || die "could not resolve latest nvm release"
      curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VER/install.sh" | bash
    }
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
  fi
  command -v pi >/dev/null 2>&1 ||
    npm i -g @earendil-works/pi-coding-agent
  # expose pi to later non-interactive ssh calls without touching shell config
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$(command -v pi)" "$HOME/.local/bin/pi"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [ -f "$rc" ] && ! grep -q 'pi-list bootstrap' "$rc" &&
          printf '%s\n' '# pi-list bootstrap' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' >>"$rc"
      done ;;
  esac
  apply
}

case "${1:-}" in
  save)            save ;;
  apply)           apply ;;
  pull)            pull ;;
  push)            push full ;;
  push-if-changed) push changed ;;
  hook)            : >"$ROOT/.hook"; say "== session-end hook armed on this machine" ;;
  auto)            auto ;;
  bootstrap)       bootstrap ;;
  *)               sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 1 ;;
esac
