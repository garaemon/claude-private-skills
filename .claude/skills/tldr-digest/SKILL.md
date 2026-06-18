---
name: tldr-digest
model: haiku
description: |
  Summarize the real articles in unread TLDR newsletter emails in
  Japanese. TLDR newsletters (TLDR AI, TLDR Web Dev, the main TLDR,
  etc.) are sent from `tldrnewsletter.com` and are usually filed under
  the user's `ML/TLDR` Gmail label. For each genuine article — not a
  `(SPONSOR)` slot, a nav link, or a job posting — resolve its source
  URL from the email's footnote link list, fetch the page, and produce
  a short Japanese outline summary. Gmail is read through the
  `gws-secure` wrapper (token-less, 1Password-backed) and the finished
  digest is posted to Slack via the `slack-post` skill.
  Trigger when the user asks to read or summarize their TLDR / ML
  newsletters, with phrases like "TLDRまとめて", "TLDRの要約",
  "今日のTLDR", "ML/TLDR まとめ", "未読のTLDR読んで", "tldr-digest".
allowed-tools: Bash(gws-secure gmail:*), Bash(jq:*), Bash(base64:*), Bash(tr:*), Bash(date:*), Bash(mkdir:*), Bash(mktemp:*), Bash(rm:*), Bash($CLAUDE_PLUGIN_ROOT/skills/slack-post/run.sh:*), WebFetch
---

# TLDR Digest Skill

Turn the user's oldest unread TLDR newsletter email into a concise
Japanese digest. The skill always processes exactly one newsletter — the
single oldest unread message — keeping only the genuine articles
(dropping sponsor slots, navigation, and job ads), resolves each
article's real source URL from the footnote link list at the bottom of
the email, fetches that page, and summarizes it with a fixed prompt.

The skill reads Gmail through the `gws-secure` wrapper, which mints a
short-lived access token from 1Password on each call and never writes an
OAuth token to disk — see [Security note](#security-note). After
rendering the digest it posts it to Slack via the `slack-post` skill.

## Prerequisites

- `gws-secure` is on `PATH` and bootstrapped: the OAuth client and a
  refresh token live in the 1Password `googleworkspace cli` item (run
  `scripts/gws-secure-bootstrap` once). A `gws-secure gmail ...` call must
  succeed without prompting. If a call fails with an auth error, stop and
  tell the user to re-run `scripts/gws-secure-bootstrap` themselves (this
  skill must not trigger an interactive login). See
  [`scripts/README.md`](../../../scripts/README.md).
- The `slack-post` skill is set up: its Docker image is built and
  `~/.config/slack-post/config.json` holds the bot token and a
  `default_channel`. See the [slack-post skill](../slack-post/SKILL.md).
- Network access for `WebFetch` to load article pages.
- `jq` and `base64` are available (both ship with the host).
- A writable cache directory for the raw message JSON. By default
  `~/.cache/claude-private-skills/tldr-digest/`. Override with the
  `TLDR_DIGEST_CACHE_DIR` environment variable.

## Workflow

### Step 1: Find unread TLDR messages

The user's intent is "unread TLDR emails under the `ML/TLDR` label".
That label is sometimes empty (the Gmail filter does not always apply),
so query by sender, which is robust:

```bash
gws-secure gmail users messages list \
  --params '{"userId":"me","q":"from:tldrnewsletter.com is:unread","maxResults":50}' \
  --format json
```

Notes:

- Prefer the label when it is populated. You may first try
  `"q":"label:ML/TLDR is:unread"`; if it returns zero results, fall
  back to the sender query above. Do not fail just because the label is
  empty.
- The response lists message ids only. `resultSizeEstimate` is an
  estimate of the total match count, not the page size.
- If there are no unread messages, stop and reply with a single
  Japanese line: `未読の TLDR はありません。`

### Step 2: Select the single oldest unread message

This skill always processes exactly **one** newsletter: the oldest unread
TLDR. Never ask the user how many to process and never batch — regardless
of how many unread messages exist.

Gmail returns ids newest-first, so the oldest is the last id of the last
page. Pick it like this:

```bash
gws-secure gmail users messages list \
  --params '{"userId":"me","q":"label:ML/TLDR is:unread","maxResults":50}' \
  --format json | jq -r '.messages[-1].id'
```

- If the response contains a `nextPageToken`, there are more unread
  messages than one page holds and the true oldest is on a later page.
  Follow the token (pass it as `"pageToken"` in `--params`) until no token
  remains, then take the last id of the final page.
- Report the total unread count to the user in one Japanese line for
  context (e.g. `未読 TLDR は N 通。一番古い 1 通を処理します。`), then
  continue with that single id through Steps 3–6.

### Step 3: Fetch each message and decode its body

For each message id, save the full message and decode the plain-text
part. Keep the large JSON in a file — do not read it into the response.

```bash
CACHE_DIR="${TLDR_DIGEST_CACHE_DIR:-$HOME/.cache/claude-private-skills/tldr-digest}"
mkdir -p "$CACHE_DIR"

gws-secure gmail users messages get \
  --params '{"userId":"me","id":"<ID>","format":"full"}' \
  --format json > "$CACHE_DIR/<ID>.json"

# Pull the first text/plain part (recurse handles nested multipart),
# then convert base64url -> base64 and decode.
jq -r '[.payload | recurse(.parts[]?) | select(.mimeType=="text/plain") | .body.data] | .[0] // ""' \
  "$CACHE_DIR/<ID>.json" | tr '_-' '/+' | base64 -d > "$CACHE_DIR/<ID>.txt"
```

Also read the `Subject`, `From`, and `Date` headers from the same JSON
for the digest header:

```bash
jq -r '.payload.headers[] | select(.name=="Subject" or .name=="From" or .name=="Date") | "\(.name): \(.value)"' \
  "$CACHE_DIR/<ID>.json"
```

Use `format=full` (not `metadata`): the `gws` metadata mode (which
`gws-secure` wraps) does not pass the `metadataHeaders` array correctly
and returns empty headers.

If the plain-text part is missing, fall back to the `text/html` part
(same decode), then strip tags before parsing. This is rare.

### Step 4: Extract the real articles and resolve their URLs

A TLDR plain-text body has three relevant shapes:

- **Section headers**: short ALL-CAPS lines such as
  `HEADLINES & LAUNCHES`, `DEEP DIVES & ANALYSIS`,
  `ENGINEERING & RESEARCH`, `MISCELLANEOUS`, `QUICK LINKS`. Use them to
  group articles.
- **Article entries**: a title line of the form
  `TITLE (X MINUTE READ) [n]` (also `HOUR READ`, `GITHUB REPO`,
  `MINUTE WATCH`), followed by a 2–4 sentence description. The title
  often wraps across several lines in the plain-text body; treat
  everything up to the `[n]` marker as one title.
- **Footnote links**: at the very bottom, lines of the form `[n] URL`.

Build an `n -> URL` map from the footnote lines, then attach the URL to
each article via its `[n]` marker.

Keep an entry **only if** it is a genuine article. Drop:

- Anything whose title contains `(SPONSOR)`.
- Navigation: `Sign Up`, `Advertise`, `View Online`, `TOGETHER WITH`.
- Job ads and the jobs section (URLs under `jobs.ashbyhq.com`,
  `advertise.tldr.tech`, etc.).
- Pure ad links (e.g. an article whose resolved URL is the advertiser's
  marketing page with `utm_medium=display` / a sponsor campaign).

`QUICK LINKS` entries are usually short real links — include them, but
still drop sponsors among them.

For each kept article collect: section, title, read-time tag, resolved
URL, and the email's own 2–4 sentence blurb (used as a fallback).

### Step 5: Fetch each article page and summarize it

For each kept article, `WebFetch` the resolved URL with this exact
prompt (TLDR redirect links such as `links.tldrnewsletter.com/...`
resolve to the real page automatically):

```text
Analyze the current webpage and provide a comprehensive summary in Japanese, organized by a clear logical outline.
User wants to catch the overview quickly. So that avoid long paragraphs in the summary.

Please structure your response. Detail the key actions or logic presented. Please use bullet points for each section to ensure clarity and conciseness.
```

If a fetch fails (paywall, blocked, timeout), fall back to the email's
own blurb for that article and mark it clearly as
`（本文取得失敗・メール内要約）`. Do not fabricate content.

### Step 6: Render the digest in Japanese

Output a Japanese markdown digest in the chat response. One block per
newsletter, grouped by section, bullet-point heavy and short:

```markdown
📰 **TLDR AI（2026-06-12）**

**🚀 HEADLINES & LAUNCHES**

**1. OpenAI が Ona を買収（1 min read）**
- 要点を箇条書きで
- もう一点
🔗 https://source.example/article

**2. ...**

**🧠 DEEP DIVES & ANALYSIS**
...
```

Rules:

- The chat response is in Japanese; this SKILL.md and any files written
  stay in English.
- Avoid long paragraphs — use bullet points, matching the fetch prompt's
  intent.
- Every article must show its real source URL.
- Skip a section heading if it has no kept articles.
- Process only the single oldest newsletter and label it with its subject
  and date.

### Step 7: Post the digest to Slack

Post the same rendered digest to Slack via the `slack-post` skill. Write
the markdown body to a temp file and pass it with `--markdown` (the file
path is bind-mounted read-only into the slack-post container, which avoids
quoting a multi-line body into a CLI argument):

```bash
DIGEST_FILE="$(mktemp /tmp/tldr-digest.XXXXXX.md)"
# Write the exact markdown rendered in Step 6 into "$DIGEST_FILE".
"$CLAUDE_PLUGIN_ROOT/skills/slack-post/run.sh" post \
  --text-file "$DIGEST_FILE" --markdown
rm -f "$DIGEST_FILE"
```

Notes:

- Posts to the `default_channel` configured in
  `~/.config/slack-post/config.json`. The user can override the target by
  setting `default_channel`, or you may add `--channel <id-or-name>` when
  the user names a channel.
- If `run.sh` fails because the image is missing, surface the build hint
  it prints and stop — do not attempt to build the image.
- If the Slack post fails for another reason, still show the digest in the
  chat response and report the failure in one Japanese line; do not retry
  in a loop.

### Step 8 (optional): Mark as read and archive

Marking mail read and archiving changes the user's Gmail state, so do it
only when the user asks, and confirm first. "Mark as read" here always
also archives the message (removes it from the inbox) in the same call —
remove both the `UNREAD` and `INBOX` labels. When confirmed, per processed
id:

```bash
gws-secure gmail users messages modify \
  --params '{"userId":"me","id":"<ID>"}' \
  --json '{"removeLabelIds":["UNREAD","INBOX"]}'
```

Removing `INBOX` archives the message; removing `UNREAD` marks it read.
Default behaviour is to leave the mail unread and in the inbox.

## Output rules

- Chat response is in Japanese; files (SKILL.md, cached JSON/text) stay
  in ASCII / English identifiers.
- Only summarize articles that came from a real fetched page or, on
  fetch failure, the email's own blurb. Do not invent content from model
  memory.
- Keep each article to a few short bullets — the user reads this to get
  the overview fast.

## Error handling

- `gws-secure` auth error: stop and tell the user to re-run
  `scripts/gws-secure-bootstrap` themselves (this skill must not trigger
  an interactive login).
- Slack post failure: keep the chat digest, report the failure in one
  Japanese line, and do not retry in a loop (see Step 7).
- No unread TLDR: reply `未読の TLDR はありません。` and stop.
- Body decode failure for one message: skip that message, note it in the
  output, and continue with the rest.
- `WebFetch` failure for one article: fall back to the email blurb and
  flag it; do not abort the whole digest.
- Many unread messages: irrelevant — the skill always processes only the
  single oldest message, so never prompt for a count.

## Out of scope

- Channels other than Slack (push, email). The digest is rendered in the
  chat response and posted to Slack (Step 7) only.
- Newsletters other than TLDR. The sender query and parsing rules are
  TLDR-specific.
- Persisting a dedup history. "Unread" is the dedup marker; optionally
  mark mail read (Step 8) to avoid re-processing next time.

## Security note

Gmail is read through `gws-secure` (see
[`scripts/README.md`](../../../scripts/README.md)), which runs Google's
official `gws` CLI on the host but keeps the OAuth client and refresh
token in 1Password and mints a short-lived access token in memory on each
call. No OAuth token is written to disk — `gws` persists only the
non-secret API discovery schema cache. `gws-secure` is used here only to
read the user's own Gmail and, optionally, to remove the `UNREAD` label.

The Slack post (Step 7) runs through the `slack-post` skill, which
executes inside a hardened Docker container with the bot token mounted
read-only — the standard isolation pattern for this repository's
credential-touching, network-reaching skills.
