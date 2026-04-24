#!/usr/bin/env python3
"""Scan every skill under /workspace/.claude/skills/<name>/ for pinned
third-party dependencies and report which ones have newer upstream releases.

Supported manifests:
  - package.json dependencies        -> registry.npmjs.org
  - requirements.in lines `pkg==x.y` -> pypi.org
  - Dockerfile ARG ..._VERSION paired with `go install github.com/...@${VAR}`
                                     -> api.github.com releases

Read-only: never modifies any file on disk. Emits a markdown report by default
or JSON with --json. Always exits 0 when the scan completes; parse the output
to decide follow-up work.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional


WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
SKILLS_ROOT = WORKSPACE / ".claude" / "skills"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
HTTP_TIMEOUT = 10
USER_AGENT = "claude-private-skills/check-updates"


def _get_json(url: str, headers: Optional[dict] = None) -> dict:
    req_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def npm_latest(pkg: str) -> str:
    data = _get_json(f"https://registry.npmjs.org/{pkg}/latest")
    return data.get("version", "")


def pypi_latest(pkg: str) -> str:
    data = _get_json(f"https://pypi.org/pypi/{pkg}/json")
    return data.get("info", {}).get("version", "")


def github_latest_release(owner: str, repo: str) -> str:
    headers = {"Accept": "application/vnd.github+json"}
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    data = _get_json(
        f"https://api.github.com/repos/{owner}/{repo}/releases/latest",
        headers=headers,
    )
    return data.get("tag_name", "")


@dataclass
class Entry:
    skill: str
    source: str
    package: str
    current: str
    latest: str
    file: str
    severity: str
    detail: str = ""


def _parse_numeric(version: str) -> tuple[int, ...]:
    cleaned = version.strip().lstrip("vV")
    match = re.match(r"^([0-9]+(?:\.[0-9]+)*)", cleaned)
    if not match:
        return ()
    return tuple(int(p) for p in match.group(1).split("."))


def compare_versions(current: str, latest: str) -> str:
    c = _parse_numeric(current)
    l = _parse_numeric(latest)
    if not c or not l:
        return "unknown"
    n = max(len(c), len(l))
    c = c + (0,) * (n - len(c))
    l = l + (0,) * (n - len(l))
    if c == l:
        return "equal"
    if l < c:
        # Pinned is ahead of upstream's "latest": unusual (pre-release pin,
        # yanked upstream release, registry lag). Flag for manual inspection
        # rather than pretending it is up to date.
        return "ahead"
    if l[0] != c[0]:
        return "major"
    if len(l) > 1 and l[1] != c[1]:
        return "minor"
    return "patch"


def scan_package_json(skill_dir: Path) -> list[Entry]:
    manifest = skill_dir / "package.json"
    if not manifest.is_file():
        return []
    rel = str(manifest.relative_to(WORKSPACE))
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [
            Entry(
                skill=skill_dir.name,
                source="npm",
                package="<package.json>",
                current="",
                latest="",
                file=rel,
                severity="error",
                detail=f"failed to parse package.json: {exc}",
            )
        ]
    entries: list[Entry] = []
    deps = data.get("dependencies") or {}
    for name, spec in sorted(deps.items()):
        current = re.sub(r"^[\^~>=<\s]+", "", str(spec)).strip()
        try:
            latest = npm_latest(name)
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
            entries.append(
                Entry(skill_dir.name, "npm", name, current, "", rel, "error", repr(exc))
            )
            continue
        entries.append(
            Entry(
                skill=skill_dir.name,
                source="npm",
                package=name,
                current=current,
                latest=latest,
                file=rel,
                severity=compare_versions(current, latest),
            )
        )
    return entries


def scan_requirements_in(skill_dir: Path) -> list[Entry]:
    manifest = skill_dir / "requirements.in"
    if not manifest.is_file():
        return []
    rel = str(manifest.relative_to(WORKSPACE))
    entries: list[Entry] = []
    line_re = re.compile(r"^\s*([A-Za-z0-9_.\-]+)\s*==\s*([^\s#;]+)")
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        body = raw.split("#", 1)[0].strip()
        if not body:
            continue
        match = line_re.match(body)
        if not match:
            continue
        name, current = match.group(1), match.group(2)
        try:
            latest = pypi_latest(name)
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
            entries.append(
                Entry(skill_dir.name, "pypi", name, current, "", rel, "error", repr(exc))
            )
            continue
        entries.append(
            Entry(
                skill=skill_dir.name,
                source="pypi",
                package=name,
                current=current,
                latest=latest,
                file=rel,
                severity=compare_versions(current, latest),
            )
        )
    return entries


ARG_RE = re.compile(r"^ARG\s+(?P<name>\w+)\s*=\s*(?P<value>\S+)", re.MULTILINE)
GO_INSTALL_RE = re.compile(
    r"""go\s+install\s+"?(?P<path>[A-Za-z0-9_./\-]+)@\$\{(?P<var>\w+)\}"?"""
)


def scan_dockerfile(skill_dir: Path) -> list[Entry]:
    manifest = skill_dir / "Dockerfile"
    if not manifest.is_file():
        return []
    rel = str(manifest.relative_to(WORKSPACE))
    text = manifest.read_text(encoding="utf-8")
    args = {m.group("name"): m.group("value") for m in ARG_RE.finditer(text)}
    entries: list[Entry] = []
    for m in GO_INSTALL_RE.finditer(text):
        path = m.group("path")
        var = m.group("var")
        current = args.get(var, "")
        if not current:
            continue
        parts = path.split("/")
        if len(parts) < 3 or parts[0] != "github.com":
            continue
        owner, repo = parts[1], parts[2]
        try:
            latest = github_latest_release(owner, repo)
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
            entries.append(
                Entry(
                    skill=skill_dir.name,
                    source="github",
                    package=f"{owner}/{repo}",
                    current=current,
                    latest="",
                    file=rel,
                    severity="error",
                    detail=repr(exc),
                )
            )
            continue
        entries.append(
            Entry(
                skill=skill_dir.name,
                source="github",
                package=f"{owner}/{repo}",
                current=current,
                latest=latest,
                file=rel,
                severity=compare_versions(current, latest),
            )
        )
    return entries


def scan_all() -> list[Entry]:
    if not SKILLS_ROOT.is_dir():
        return []
    entries: list[Entry] = []
    for skill_dir in sorted(p for p in SKILLS_ROOT.iterdir() if p.is_dir()):
        if not (skill_dir / "SKILL.md").is_file():
            continue
        entries.extend(scan_package_json(skill_dir))
        entries.extend(scan_requirements_in(skill_dir))
        entries.extend(scan_dockerfile(skill_dir))
    return entries


SEVERITY_ICON = {
    "major": "!!",
    "minor": "^^",
    "patch": "^",
    "equal": "ok",
    "unknown": "?",
    "ahead": "?",
    "error": "x",
}


def _format_entry_line(entry: Entry) -> str:
    icon = SEVERITY_ICON.get(entry.severity, "?")
    pkg = f"`{entry.package}` ({entry.source})"
    if entry.severity == "error":
        return f"- [{icon}] {pkg}: error fetching latest — {entry.detail}"
    if entry.severity == "equal":
        return f"- [{icon}] {pkg} `{entry.current}` — up to date"
    if entry.severity in {"major", "minor", "patch"}:
        return (
            f"- [{icon}] {pkg} `{entry.current}` -> `{entry.latest}` "
            f"({entry.severity}) — edit `{entry.file}`"
        )
    if entry.severity == "ahead":
        return (
            f"- [{icon}] {pkg} `{entry.current}` > `{entry.latest}` (pinned is ahead of "
            f"upstream latest) — inspect `{entry.file}`"
        )
    return (
        f"- [{icon}] {pkg} `{entry.current}` vs `{entry.latest}` "
        f"({entry.severity}) — inspect `{entry.file}`"
    )


def format_markdown(entries: list[Entry]) -> str:
    if not entries:
        return "# Skill dependency report\n\nNo pinned manifests found under `.claude/skills/`.\n"
    by_skill: dict[str, list[Entry]] = {}
    for entry in entries:
        by_skill.setdefault(entry.skill, []).append(entry)

    outdated_count = sum(
        1 for e in entries if e.severity in {"major", "minor", "patch"}
    )
    error_count = sum(1 for e in entries if e.severity == "error")

    lines: list[str] = ["# Skill dependency report", ""]
    lines.append(f"- Skills scanned: {len(by_skill)}")
    lines.append(f"- Dependencies checked: {len(entries)}")
    lines.append(f"- Outdated: {outdated_count}")
    if error_count:
        lines.append(f"- Errors: {error_count}")
    lines.append("")

    for skill in sorted(by_skill):
        skill_entries = by_skill[skill]
        lines.append(f"## {skill}")
        lines.append("")
        for entry in skill_entries:
            lines.append(_format_entry_line(entry))
        lines.append("")
        if any(e.severity in {"major", "minor", "patch"} for e in skill_entries):
            lines.append("After editing, rebuild the image:")
            lines.append("")
            lines.append("```bash")
            lines.append(f"docker build -t {skill}:local .claude/skills/{skill}")
            lines.append("```")
            lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report outdated pinned dependencies across skills."
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit JSON instead of the default markdown report",
    )
    parser.add_argument(
        "--only-outdated",
        action="store_true",
        help="suppress entries that are already up to date",
    )
    args = parser.parse_args()

    if not SKILLS_ROOT.is_dir():
        print(
            f"check-updates: no skills directory at {SKILLS_ROOT}. "
            "Run from a project root containing .claude/skills/.",
            file=sys.stderr,
        )
        return 2

    entries = scan_all()
    if args.only_outdated:
        entries = [e for e in entries if e.severity != "equal"]

    if args.json:
        print(json.dumps([asdict(e) for e in entries], indent=2))
    else:
        print(format_markdown(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
