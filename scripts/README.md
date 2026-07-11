# Repository scripts

## `claude-with-retry.sh` — retry `claude -p` past a usage-limit window

`claude-with-retry.sh` wraps a `claude -p` invocation so an unattended job
survives hitting the Anthropic usage limit instead of silently producing
nothing.

In print mode, Claude Code emits a line of the form

```text
Claude AI usage limit reached|<unix-epoch-seconds>
```

when the account's usage/rate limit is exhausted; the trailing epoch is when the
limit resets. The wrapper detects that line (regardless of exit status — Claude
Code sometimes reports the limit as a normal result message), sleeps until the
reset time plus a small buffer, and re-runs the exact same command. Any other
outcome is passed straight through: a clean run exits 0, and a non-limit failure
propagates its original exit code without retrying.

The `spotify-daily-digest`, `news-digest`, and `artist-live-digest` systemd
`--user` timer wrappers route their `claude -p` calls through this script, so a
morning/weekly digest that lands inside a usage-limit window is waited out and
retried rather than lost.

### Usage

```bash
CLAUDE_BIN=/path/to/claude scripts/claude-with-retry.sh -p "prompt" --allowedTools ...
```

### Configuration

All optional, via environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_BIN` | `~/.local/bin/claude` | path to the `claude` CLI |
| `CLAUDE_RETRY_MAX_ATTEMPTS` | `3` | total attempts before giving up |
| `CLAUDE_RETRY_BUFFER_SEC` | `60` | extra seconds to wait past the reset time |
| `CLAUDE_RETRY_MAX_SLEEP_SEC` | `21600` | cap on a single wait (6h) |
| `CLAUDE_RETRY_DEFAULT_SLEEP_SEC` | `900` | wait used when the reset epoch is already past or unparseable |

### Tests

`scripts/tests/claude-with-retry-smoke.sh` drives the wrapper against a fake
`claude` stub (no CLI, network, or account needed) covering the clean run,
non-limit failure pass-through, retry-then-succeed, and limit-persists paths.

## `gws-secure` — token-less Google Workspace CLI

`gws-secure` wraps the [`gws`](https://www.npmjs.com/package/@googleworkspace/cli)
Google Workspace CLI so that **no OAuth token is ever written to disk**.

Normally `gws` persists an encrypted refresh token and an access-token cache
under `~/.config/gws`. `gws-secure` instead keeps the OAuth client and refresh
token in 1Password and mints a short-lived access token in memory on every
call:

1. Read `client_secret.json` and the `refresh_token` field from the 1Password
   item (in memory only).
2. Exchange the refresh token for a short-lived access token via Google's token
   endpoint (in memory only).
3. Run the real `gws` with that access token supplied through
   `GOOGLE_WORKSPACE_CLI_TOKEN`. In this mode `gws` writes only the non-secret
   API discovery schema cache to `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`
   (default `~/.cache/gws-secure`) — never a credential.

### Prerequisites

- `op` (1Password CLI), signed in.
- `gws`, `curl`, and `jq` on `PATH`. `gws` is the `@googleworkspace/cli` npm
  package; install it globally with `npm install -g @googleworkspace/cli`.
- A 1Password item (default title `googleworkspace cli` in the `Private` vault)
  holding the OAuth desktop client as a `client_secret.json` document.

### One-time setup

Run the bootstrap once. It performs the standard installed-app loopback OAuth
flow in your browser and stores the resulting refresh token back into the same
1Password item as a concealed `refresh_token` field:

```bash
scripts/gws-secure-bootstrap
```

### Usage

`gws-secure` takes the exact same arguments as `gws`:

```bash
scripts/gws-secure gmail users getProfile --params '{"userId":"me"}'
```

Put it on your `PATH` (e.g. symlink into `~/.local/bin`) to call it as
`gws-secure` from anywhere.

### Configuration

All optional, via environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GWS_SECURE_OP_ITEM` | `googleworkspace cli` | 1Password item title |
| `GWS_SECURE_OP_VAULT` | `Private` | 1Password vault |
| `GWS_SECURE_REFRESH_FIELD` | `refresh_token` | field label of the stored token |
| `GWS_SECURE_SCOPES` | current `gws` scopes | OAuth scopes (bootstrap only) |
| `GWS_SECURE_CACHE_DIR` | `~/.cache/gws-secure` | schema cache dir (non-secret) |
| `GWS_SECURE_GWS_BIN` | `gws` | path to the real `gws` binary |

### Tests

`scripts/tests/gws-secure-smoke.sh` covers the deterministic dependency-check
failure path (no network, 1Password, or browser needed). The OAuth and
1Password paths are verified live during bootstrap and first use.
