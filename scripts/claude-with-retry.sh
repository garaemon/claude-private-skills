#!/usr/bin/env bash
# Run `claude -p ...` and automatically retry when the Anthropic usage limit is
# reached, so an unattended systemd --user timer job survives a limit window
# instead of silently producing nothing for the day.
#
# In print mode (`-p`), Claude Code emits a line of the form
#
#   Claude AI usage limit reached|<unix-epoch-seconds>
#
# when the account's usage/rate limit is exhausted. The trailing epoch is when
# the limit resets. This wrapper detects that line, sleeps until the reset time
# (plus a small buffer), and re-runs the exact same command. The sentinel is
# checked regardless of exit status, because Claude Code sometimes reports the
# limit as a normal result message (exit 0) rather than a hard failure.
#
# Any other outcome is passed straight through: a clean run exits 0, and a
# non-limit failure propagates its original exit code without retrying. This
# wrapper only special-cases the usage-limit signal — it is deliberately not a
# generic "retry on any error" harness.
#
# Usage:
#   CLAUDE_BIN=/path/to/claude scripts/claude-with-retry.sh -p "prompt" --allowedTools ...
#
# Tunables (environment variables):
#   CLAUDE_BIN                     path to the claude CLI (default ~/.local/bin/claude)
#   CLAUDE_RETRY_MAX_ATTEMPTS      total attempts before giving up (default 3)
#   CLAUDE_RETRY_BUFFER_SEC        extra seconds to wait past the reset time (default 60)
#   CLAUDE_RETRY_MAX_SLEEP_SEC     cap on a single wait, in seconds (default 21600 = 6h)
#   CLAUDE_RETRY_DEFAULT_SLEEP_SEC wait used when the reset epoch is already past
#                                  or cannot be parsed (default 900 = 15m)

set -euo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
max_attempts="${CLAUDE_RETRY_MAX_ATTEMPTS:-3}"
buffer_sec="${CLAUDE_RETRY_BUFFER_SEC:-60}"
max_sleep_sec="${CLAUDE_RETRY_MAX_SLEEP_SEC:-21600}"
default_sleep_sec="${CLAUDE_RETRY_DEFAULT_SLEEP_SEC:-900}"

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "error: claude CLI not found or not executable at $CLAUDE_BIN" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "usage: CLAUDE_BIN=<claude> $(basename "$0") <claude args...>" >&2
  exit 2
fi

# Render a reset epoch as a human-readable local timestamp for logs. GNU date
# uses `-d @<epoch>`, BSD/macOS date uses `-r <epoch>`; fall back to the raw
# epoch if neither is available.
format_epoch() {
  local epoch="$1"
  date -d "@${epoch}" -Is 2>/dev/null \
    || date -r "${epoch}" -Iseconds 2>/dev/null \
    || echo "epoch ${epoch}"
}

attempt=1
while :; do
  # Capture combined output to a temp file while still streaming it to the
  # caller so `journalctl` keeps showing the live run.
  out_file="$(mktemp)"
  # A non-zero claude exit must not abort us under `set -e`: inspect the output
  # for the usage-limit sentinel first, then decide what to do.
  set +e
  "$CLAUDE_BIN" "$@" 2>&1 | tee "$out_file"
  status="${PIPESTATUS[0]}"
  set -e

  # Extract the reset epoch from the last "usage limit reached|<epoch>" line, if
  # any. `|| true` keeps `set -e`/pipefail from firing when grep finds nothing.
  limit_line="$(grep -oE 'usage limit reached\|[0-9]+' "$out_file" | tail -n1 || true)"
  rm -f "$out_file"

  if [[ -z "$limit_line" ]]; then
    # Not a usage-limit outcome: propagate the original exit code unchanged.
    exit "$status"
  fi
  reset_epoch="${limit_line##*|}"

  if [[ "$attempt" -ge "$max_attempts" ]]; then
    echo "error: Claude usage limit still in effect after ${attempt} attempt(s); giving up" >&2
    # Ensure a failing exit even if Claude reported the limit as a status-0
    # result message, so the systemd unit is marked failed.
    [[ "$status" -ne 0 ]] && exit "$status"
    exit 1
  fi

  now="$(date +%s)"
  sleep_sec=$(( reset_epoch - now + buffer_sec ))
  if [[ "$sleep_sec" -lt "$buffer_sec" ]]; then
    # Reset time already passed (or clock skew) — wait a sensible default.
    sleep_sec="$default_sleep_sec"
  fi
  if [[ "$sleep_sec" -gt "$max_sleep_sec" ]]; then
    sleep_sec="$max_sleep_sec"
  fi

  echo "warn: Claude usage limit reached (resets at $(format_epoch "$reset_epoch")); sleeping ${sleep_sec}s before retry (attempt $((attempt + 1))/${max_attempts})" >&2
  sleep "$sleep_sec"
  attempt=$(( attempt + 1 ))
done
