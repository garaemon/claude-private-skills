#!/usr/bin/env bash
# Wrapper that runs the check-updates scanner inside a hardened Docker
# container. Mounts the project workspace read-only and prints a report of
# pinned dependencies across every skill under .claude/skills/.
#
# The workspace defaults to the current directory; override with
# CHECK_UPDATES_WORKSPACE=/path/to/project.
#
# Optional: set GITHUB_TOKEN before invoking to raise the public GitHub API
# rate limit. It is forwarded into the container via -e.

set -euo pipefail

readonly IMAGE_TAG="check-updates:local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

WORKSPACE_DIR="${CHECK_UPDATES_WORKSPACE:-$PWD}"

die() {
  echo "run.sh: error: $*" >&2
  exit 1
}

ensure_image_exists() {
  if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    die "Docker image '${IMAGE_TAG}' not found. Build it first:
  docker build -t ${IMAGE_TAG} \"${SCRIPT_DIR}\""
  fi
}

ensure_workspace() {
  if [[ ! -d "${WORKSPACE_DIR}" ]]; then
    die "workspace not found: ${WORKSPACE_DIR}"
  fi
  if [[ ! -d "${WORKSPACE_DIR}/.claude/skills" ]]; then
    die "no .claude/skills/ directory under ${WORKSPACE_DIR}. Run from the project root or set CHECK_UPDATES_WORKSPACE."
  fi
  WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
}

run_container() {
  local env_flags=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    env_flags+=(-e "GITHUB_TOKEN=${GITHUB_TOKEN}")
  fi
  docker run --rm \
    --network bridge \
    --read-only --tmpfs /tmp \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --memory 256m --cpus 0.5 \
    "${env_flags[@]}" \
    -v "${WORKSPACE_DIR}:/workspace:ro" \
    "${IMAGE_TAG}" "$@"
}

main() {
  ensure_image_exists
  ensure_workspace
  run_container "$@"
}

main "$@"
