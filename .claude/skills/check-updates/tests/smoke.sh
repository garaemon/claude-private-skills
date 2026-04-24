#!/usr/bin/env bash
# Smoke tests for the check-updates Docker image. Exercises failure modes and
# the default-format output without requiring real network access or
# credentials.

set -euo pipefail

readonly IMAGE="${IMAGE:-check-updates:local}"

fail() {
  echo "smoke test failed: $*" >&2
  exit 1
}

test_no_workspace_fails() {
  echo "Test: container exits non-zero when /workspace has no .claude/skills"
  local tmpdir
  tmpdir=$(mktemp -d)
  local output
  local exit_status=0
  output=$(docker run --rm \
      --network none \
      -v "${tmpdir}:/workspace:ro" \
      "${IMAGE}" 2>&1) || exit_status=$?
  rm -rf "${tmpdir}"
  if (( exit_status == 0 )); then
    fail "expected non-zero exit without skills dir; got 0. output: ${output}"
  fi
  grep -q "no skills directory" <<<"${output}" \
    || fail "expected 'no skills directory' message; got: ${output}"
  echo "  OK"
}

test_empty_skills_dir_reports_no_manifests() {
  echo "Test: empty .claude/skills directory yields 'No pinned manifests found'"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "${tmpdir}/.claude/skills"
  local output
  output=$(docker run --rm \
      --network none \
      -v "${tmpdir}:/workspace:ro" \
      "${IMAGE}" 2>&1)
  rm -rf "${tmpdir}"
  grep -q "No pinned manifests found" <<<"${output}" \
    || fail "expected 'No pinned manifests found'; got: ${output}"
  echo "  OK"
}

test_json_mode_emits_array() {
  echo "Test: --json with no skills emits an empty JSON array"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "${tmpdir}/.claude/skills"
  local output
  output=$(docker run --rm \
      --network none \
      -v "${tmpdir}:/workspace:ro" \
      "${IMAGE}" --json 2>&1)
  rm -rf "${tmpdir}"
  # Output should be a JSON array (empty when no skills).
  [[ "${output}" == "[]" ]] \
    || fail "expected empty JSON array '[]'; got: ${output}"
  echo "  OK"
}

test_skill_without_manifests_is_skipped() {
  echo "Test: a SKILL.md-only directory produces no entries"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "${tmpdir}/.claude/skills/example"
  : >"${tmpdir}/.claude/skills/example/SKILL.md"
  local output
  output=$(docker run --rm \
      --network none \
      -v "${tmpdir}:/workspace:ro" \
      "${IMAGE}" --json 2>&1)
  rm -rf "${tmpdir}"
  [[ "${output}" == "[]" ]] \
    || fail "expected '[]' for manifest-less skill; got: ${output}"
  echo "  OK"
}

main() {
  test_no_workspace_fails
  test_empty_skills_dir_reports_no_manifests
  test_json_mode_emits_array
  test_skill_without_manifests_is_skipped
  echo "All check-updates smoke tests passed."
}

main "$@"
