#!/usr/bin/env bash
#
# Smoke test for claude-with-retry.sh. Drives the wrapper against a fake
# `claude` stub so no real CLI, network, or Anthropic account is needed. Covers:
#   - a clean run exits 0 and is not retried;
#   - a non-limit failure propagates its exit code and is not retried;
#   - a usage-limit response triggers a retry that then succeeds;
#   - the limit persisting across every attempt exits non-zero.
#
# Waits are kept near-zero by pointing the reset epoch into the past and setting
# CLAUDE_RETRY_DEFAULT_SLEEP_SEC=0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WRAPPER="$SCRIPT_DIR/claude-with-retry.sh"

work_dir="$(mktemp -d)"
readonly work_dir
trap 'rm -rf "$work_dir"' EXIT

readonly count_file="$work_dir/count"
readonly stub="$work_dir/claude"

fail() {
  printf 'smoke: FAIL - %s\n' "$1" >&2
  exit 1
}

# Fake claude CLI. Its behaviour is driven by the STUB_MODE env var and a
# per-run invocation counter so a single stub can model every scenario. It
# prints the count so the test can assert how many times it ran.
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count_file="$STUB_COUNT_FILE"
n=$(( $(cat "$count_file") + 1 ))
echo "$n" >"$count_file"
echo "stub invocation $n (args: $*)"
case "$STUB_MODE" in
  success)
    exit 0
    ;;
  fail)
    echo "some unrelated error" >&2
    exit 7
    ;;
  limit-then-success)
    if [[ "$n" -eq 1 ]]; then
      echo "Claude AI usage limit reached|$STUB_RESET_EPOCH"
      exit 1
    fi
    exit 0
    ;;
  always-limit)
    echo "Claude AI usage limit reached|$STUB_RESET_EPOCH"
    exit 1
    ;;
esac
STUB
chmod +x "$stub"

# A reset epoch safely in the past so the wrapper's "already passed" branch
# fires and falls back to CLAUDE_RETRY_DEFAULT_SLEEP_SEC (0 here).
past_epoch=$(( $(date +%s) - 3600 ))

run_wrapper() {
  local mode="$1"
  shift
  echo 0 >"$count_file"
  STUB_MODE="$mode" \
  STUB_COUNT_FILE="$count_file" \
  STUB_RESET_EPOCH="$past_epoch" \
  CLAUDE_BIN="$stub" \
  CLAUDE_RETRY_DEFAULT_SLEEP_SEC=0 \
  CLAUDE_RETRY_BUFFER_SEC=0 \
  CLAUDE_RETRY_MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}" \
    "$WRAPPER" "$@"
}

invocations() { cat "$count_file"; }

# 1. Clean run: exit 0, exactly one invocation.
run_wrapper success -p "hi" >/dev/null 2>&1 && status=0 || status=$?
[ "$status" -eq 0 ] || fail "success case should exit 0, got $status"
[ "$(invocations)" -eq 1 ] || fail "success case should run once, ran $(invocations)"

# 2. Non-limit failure: exit code propagated, no retry.
run_wrapper fail -p "hi" >/dev/null 2>&1 && status=0 || status=$?
[ "$status" -eq 7 ] || fail "failure case should propagate exit 7, got $status"
[ "$(invocations)" -eq 1 ] || fail "failure case must not retry, ran $(invocations)"

# 3. Usage limit then success: retries once, ends up exit 0, two invocations.
run_wrapper limit-then-success -p "hi" >/dev/null 2>&1 && status=0 || status=$?
[ "$status" -eq 0 ] || fail "limit-then-success should exit 0, got $status"
[ "$(invocations)" -eq 2 ] || fail "limit-then-success should run twice, ran $(invocations)"

# 4. Limit on every attempt: exits non-zero after exhausting the attempt budget.
MAX_ATTEMPTS=2 run_wrapper always-limit -p "hi" >/dev/null 2>&1 && status=0 || status=$?
[ "$status" -ne 0 ] || fail "always-limit should exit non-zero"
[ "$(invocations)" -eq 2 ] || fail "always-limit should run MAX_ATTEMPTS=2 times, ran $(invocations)"

printf 'smoke: OK\n'
