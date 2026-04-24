---
name: check-updates
description: |
  Scan every skill under `.claude/skills/<name>/` for pinned third-party
  dependencies and report which ones have newer upstream releases. Read-only:
  never modifies files, never rebuilds images. Use the report to decide which
  skills to bump, then edit the manifest and rebuild the skill's Docker image
  manually.
  Supported manifests:
  - `package.json` dependencies (queries npm registry)
  - `requirements.in` pins like `pkg==1.2.3` (queries PyPI)
  - `Dockerfile` `ARG ..._VERSION=vX.Y.Z` paired with `go install
    github.com/owner/repo@${VAR}` (queries GitHub releases)
  The CLI runs inside a hardened Docker container with the workspace mounted
  read-only. No secrets required; `GITHUB_TOKEN` is optional and only used to
  raise the public GitHub API rate limit.
  Trigger when the user asks to check for skill dependency updates, or says
  things like "skillのupdate確認して", "pdf2zhの新しいの来てない？",
  "依存の更新チェックして", "check for skill updates", "are any skill deps
  outdated", "bump skill deps".
allowed-tools: Bash($CLAUDE_PLUGIN_ROOT/skills/check-updates/run.sh:*)
---

# check-updates Skill

Report which pinned dependencies across the project's skills have newer
upstream releases. Designed to be run periodically to decide which skills
need a version bump + image rebuild.

## What it checks

For each directory under `.claude/skills/` that contains a `SKILL.md`:

| Manifest | Source queried | Version field |
| --- | --- | --- |
| `package.json` | `https://registry.npmjs.org/<pkg>/latest` | Each key in `dependencies` |
| `requirements.in` | `https://pypi.org/pypi/<pkg>/json` | Lines matching `name==version` |
| `Dockerfile` | `https://api.github.com/repos/<owner>/<repo>/releases/latest` | `ARG <N>_VERSION=<v>` paired with `go install github.com/<owner>/<repo>@${<N>_VERSION}` |

Everything else (transitive deps, base images in `FROM` lines, `requirements.txt`
lockfile hashes) is out of scope — the checker only looks at top-level,
human-edited pins.

## What it does NOT do

- Modify any file (never edits `package.json`, `requirements.in`, etc.).
- Regenerate lockfiles (`package-lock.json`, `requirements.txt`).
- Run `docker build` for any skill.
- Install anything on the host.

These are left to the user / to Claude reading the report, because each skill
has its own rebuild/audit workflow that must be exercised consciously.

## Prerequisites

- Docker is installed and the daemon is running.
- The command runs with the project root as the working directory (or
  `CHECK_UPDATES_WORKSPACE` pointing at it); the workspace must contain a
  `.claude/skills/` directory.

## Optional: GitHub token

Unauthenticated requests to the public GitHub API are rate-limited to 60
requests per hour per IP. This skill makes at most one GitHub request per
Dockerfile that references `go install github.com/...@${VAR}`, so the
unauthenticated limit is comfortable for this repo. For noisier environments
or forks with many Go-based skills, export `GITHUB_TOKEN` before invoking
`run.sh` and it will be forwarded to the container.

## One-time setup

Build the Docker image once:

```bash
docker build -t check-updates:local \
  "$CLAUDE_PLUGIN_ROOT/skills/check-updates"
```

Rebuild after updating the skill.

## Usage

```text
run.sh [--json] [--only-outdated]
```

| Flag | Default | Description |
| --- | --- | --- |
| `--json` | off | Emit a JSON array instead of the markdown report. |
| `--only-outdated` | off | Suppress up-to-date entries from the output. |

The command always exits `0` when the scan completes; parse the output to
decide follow-up work.

### Example invocations

```bash
# Markdown report for the whole project, run from the repo root.
.claude/skills/check-updates/run.sh

# Only show entries that need attention.
.claude/skills/check-updates/run.sh --only-outdated

# JSON output for programmatic use.
.claude/skills/check-updates/run.sh --json
```

### Suggested follow-up workflow

The report prints, per skill, the file to edit and a rebuild command. A
typical bump for a single skill looks like:

1. Edit the pinned version in the indicated file (e.g.
   `.claude/skills/pdf2zh/requirements.in`).
2. Regenerate the lockfile if the skill uses one (e.g. `uv pip compile
   --generate-hashes --python-version 3.12 requirements.in -o requirements.txt`
   for pdf2zh, or `npm install --package-lock-only --omit=dev` for the Node
   skills). These steps reach the network and should be run with the same
   isolation the rest of the repo uses.
3. Run `docker build -t <skill>:local .claude/skills/<skill>`.
4. Run the skill's smoke tests under `.claude/skills/<skill>/tests/`.
5. Commit and push.

Do not chain these steps blindly — a major version bump may require source
changes in the skill's entrypoint.

## Isolation guarantees

Each `run.sh` invocation starts a container with:

- `--read-only` root filesystem, writable `/tmp` tmpfs only
- `--cap-drop ALL` and `--security-opt no-new-privileges`
- `--memory 256m --cpus 0.5` resource limits
- Non-root `checker` user (UID 1000) inside the container
- Workspace mounted read-only at `/workspace`
- `--network bridge` (outbound only; required to reach npm / PyPI / GitHub)

`run.sh` additionally guards against common misconfigurations before
launching:

- Refuses to run if the Docker image is missing and prints the build command.
- Refuses to run if the chosen workspace has no `.claude/skills/` directory.

## When to use

- The user asks whether any skill has an available dependency update.
- The user asks specifically about a skill (`pdf2zh`, `slack-post`, ...) being
  out of date.
- Setting up a periodic "check the skills" job — pair with the `loop` skill
  to schedule a recurring scan.

## Out of scope

- Applying the update (edit the manifest, regenerate the lockfile, rebuild
  the image, run the smoke tests — each belongs to the owning skill).
- Checking base-image tags in `FROM` lines.
- Auditing transitive dependencies (use `npm audit` / `pip-audit` in CI).
