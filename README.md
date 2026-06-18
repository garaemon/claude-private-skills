# claude-private-skills

This is my private set of Claude Code skills.
These skills are designed and implemented with the intent of being used from the Claude app on
smartphones or desktop via Claude Code's `/remote-control`.

## Skills

- [add-paper-from-url](.claude/skills/add-paper-from-url/SKILL.md) — Add a paper to Paperpile from a PDF URL and attach a Japanese Ochiai-format summary as a note via the [`paperpile`](https://github.com/garaemon/paperpile) CLI.
- [spotify-sheets](.claude/skills/spotify-sheets/SKILL.md) — Search and browse the user's Spotify library (liked songs, followed artists) exported to Google Sheets. Runs in a hardened Docker container with a read-only service-account key mount.
- [spotify-daily-digest](.claude/skills/spotify-daily-digest/SKILL.md) — Produce a morning digest of the songs liked in the last 24 hours, enriched with web-searched background for each track and artist.
- [slack-post](.claude/skills/slack-post/SKILL.md) — Post a message to a Slack channel (or DM) via the Slack Web API. Runs in a hardened Docker container with the bot token mounted read-only; designed for scheduled jobs like a daily morning digest.
- [news-digest](.claude/skills/news-digest/SKILL.md) — Produce a morning news digest for a configured topic (AI, software, NBA, …) with web-searched headlines, category grouping, and cross-day deduplication against a persistent history file. Topics are markdown configs under `topics/`, so adding a new topic requires no code change.
- [pdf2zh](.claude/skills/pdf2zh/SKILL.md) — Translate a PDF to Japanese via the `pdf2zh` (PDFMathTranslate) CLI using Gemini. Runs in a hardened Docker container with a read-only Gemini API key file mount.
- [artist-live-digest](.claude/skills/artist-live-digest/SKILL.md) — Produce a Japanese digest of upcoming live concerts in a configured city (default: Los Angeles) for the user's followed Spotify artists. Delegates the artist list to `spotify-sheets`, enriches via web search within a configurable day window, and dedupes against a persistent history file. Ships a Friday-morning systemd timer that posts via `slack-post`.
- [tldr-digest](.claude/skills/tldr-digest/SKILL.md) — Summarize the real articles in unread TLDR newsletter emails (the `ML/TLDR` Gmail label / `tldrnewsletter.com` sender) in Japanese. Drops sponsor slots, nav, and job ads; resolves each article's source URL from the email footnotes; fetches the page; and produces a concise Japanese outline summary. Reads Gmail via the `gws-secure` wrapper and posts the digest to Slack via `slack-post`.

## Tools

### `gws-secure` — token-less Google Workspace CLI

`scripts/gws-secure` wraps the `gws` (Google Workspace CLI) so that **no OAuth
token is ever written to disk**. The OAuth client and refresh token live in
1Password; each call mints a short-lived access token in memory and passes it
to `gws` through `GOOGLE_WORKSPACE_CLI_TOKEN`, so `gws` persists no credential
(only the non-secret API discovery schema cache).

One-time setup — mint a refresh token and store it in the 1Password item:

```bash
scripts/gws-secure-bootstrap
```

Usage — same arguments as `gws`:

```bash
scripts/gws-secure gmail users getProfile --params '{"userId":"me"}'
```

Put it on your `PATH` to call it from anywhere:

```bash
ln -s "$PWD/scripts/gws-secure" ~/.local/bin/gws-secure
```

See [`scripts/README.md`](scripts/README.md) for prerequisites, configuration
variables, and details.
