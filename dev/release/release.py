#!/usr/bin/env python3
"""Release plumbing for Salish Tides — the deterministic half of the release flow.

The judgement calls (summarizing commits into user-facing notes, choosing the
semver bump) are made by the `release` Claude skill. Everything mechanical
and error-prone lives here so it's reproducible and testable:

  status   Print current versions, the last release tag, and every commit since
           it (as JSON for the skill, or a human table). Read-only.
  apply    Set MARKETING_VERSION and bump CURRENT_PROJECT_VERSION in
           Config/Base.xcconfig. This is the "real Xcode version increment".
  render   Regenerate docs/changelog.html from the canonical CHANGELOG.md.
  tag      Create the annotated git tag vX.Y.Z for a release.

Source of truth: CHANGELOG.md (Keep a Changelog style) is canonical; the website
page and the git tags are derived from it. MARKETING_VERSION mirrors the latest
released version there.

Conventions:
  - Semantic versioning (MAJOR.MINOR.PATCH). Tags are `vX.Y.Z`.
  - CURRENT_PROJECT_VERSION (build number) is monotonic and only ever increases;
    it is independent of the marketing version (App Store / TestFlight require a
    unique, increasing build number per uploaded binary).

Usage:
    python3 dev/release/release.py status [--json]
    python3 dev/release/release.py apply --version X.Y.Z [--build N] [--dry-run]
    python3 dev/release/release.py render [--check]
    python3 dev/release/release.py tag --version X.Y.Z [--message MSG]

Stdlib only; run from anywhere (paths are resolved relative to the repo root).
"""

from __future__ import annotations

import argparse
import html
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
XCCONFIG = REPO_ROOT / "Config" / "Base.xcconfig"
CHANGELOG = REPO_ROOT / "CHANGELOG.md"
CHANGELOG_HTML = REPO_ROOT / "docs" / "changelog.html"

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
PR_RE = re.compile(r"\(#(\d+)\)\s*$")


# --------------------------------------------------------------------------- #
# git helpers
# --------------------------------------------------------------------------- #
def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout


def release_tags() -> list[tuple[tuple[int, int, int], str]]:
    """All vX.Y.Z tags, sorted ascending by semver."""
    out = git("tag", "--list", "v*")
    tags: list[tuple[tuple[int, int, int], str]] = []
    for line in out.splitlines():
        line = line.strip()
        m = TAG_RE.match(line)
        if m:
            tags.append(((int(m[1]), int(m[2]), int(m[3])), line))
    tags.sort()
    return tags


def last_release_tag() -> str | None:
    tags = release_tags()
    return tags[-1][1] if tags else None


def commits_since(tag: str | None) -> list[dict]:
    """Commits reachable from HEAD but not from `tag` (all history if None)."""
    rev = f"{tag}..HEAD" if tag else "HEAD"
    # Unit separator (\x1f) between fields, record separator (\x1e) between commits.
    fmt = "%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1e"
    out = git("log", rev, f"--pretty=format:{fmt}")
    commits = []
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        full, short, subject, author, date = record.split("\x1f")
        pr = PR_RE.search(subject)
        commits.append(
            {
                "hash": full,
                "short": short,
                "subject": subject,
                "author": author,
                "date": date,
                "pr": int(pr[1]) if pr else None,
            }
        )
    return commits


# --------------------------------------------------------------------------- #
# xcconfig read / write
# --------------------------------------------------------------------------- #
def read_xcconfig_value(key: str) -> str | None:
    pattern = re.compile(rf"^{re.escape(key)}\s*=\s*(.*?)\s*$", re.MULTILINE)
    m = pattern.search(XCCONFIG.read_text())
    return m[1] if m else None


def current_versions() -> tuple[str, str]:
    marketing = read_xcconfig_value("MARKETING_VERSION") or "0.0.0"
    build = read_xcconfig_value("CURRENT_PROJECT_VERSION") or "0"
    return marketing, build


def normalize_semver(version: str) -> str:
    """Accept 1, 1.0, or 1.0.0 and return canonical MAJOR.MINOR.PATCH."""
    parts = version.strip().split(".")
    if not (1 <= len(parts) <= 3) or not all(p.isdigit() for p in parts):
        sys.exit(f"'{version}' is not a valid version (want MAJOR.MINOR.PATCH)")
    parts += ["0"] * (3 - len(parts))
    return ".".join(parts)


def write_xcconfig(marketing: str, build: str) -> None:
    text = XCCONFIG.read_text()
    text, n1 = re.subn(
        r"^(MARKETING_VERSION\s*=\s*).*$",
        lambda m: m[1] + marketing,
        text,
        flags=re.MULTILINE,
    )
    text, n2 = re.subn(
        r"^(CURRENT_PROJECT_VERSION\s*=\s*).*$",
        lambda m: m[1] + build,
        text,
        flags=re.MULTILINE,
    )
    if n1 != 1 or n2 != 1:
        sys.exit(
            f"expected exactly one MARKETING_VERSION and one CURRENT_PROJECT_VERSION "
            f"line in {XCCONFIG} (found {n1} and {n2})"
        )
    XCCONFIG.write_text(text)


# --------------------------------------------------------------------------- #
# CHANGELOG.md -> HTML
# --------------------------------------------------------------------------- #
RELEASE_HEADER_RE = re.compile(r"^##\s+\[([^\]]+)\]\s*-\s*(.+?)\s*$")
CATEGORY_HEADER_RE = re.compile(r"^###\s+(.+?)\s*$")
BULLET_RE = re.compile(r"^[-*]\s+(.*)$")


def parse_changelog(text: str) -> list[dict]:
    """Parse a Keep-a-Changelog file into a list of release dicts.

    Each release: {version, date, intro: [str], groups: [(category, [items])]}.
    Only structure the renderer needs; unreleased/link sections are ignored.

    Hard-wrapped source is handled: a plain line following a bullet or an intro
    line is a continuation and is joined to it with a space (this is how people
    hand-edit changelogs), and a blank line ends the current paragraph/bullet. So
    wrapping a bullet across several lines never drops the tail.
    """
    releases: list[dict] = []
    current: dict | None = None
    category: str | None = None
    # Where a continuation line appends: ("intro", idx) or ("bullet", items_list).
    pending: tuple | None = None

    for raw in text.splitlines():
        line = raw.rstrip()
        header = RELEASE_HEADER_RE.match(line)
        if header:
            current = {
                "version": header[1].strip(),
                "date": header[2].strip(),
                "intro": [],
                "groups": [],
            }
            releases.append(current)
            category = None
            pending = None
            continue
        if current is None:
            continue  # preamble before the first release entry

        if not line.strip():
            pending = None  # blank line ends the current paragraph / bullet
            continue

        cat = CATEGORY_HEADER_RE.match(line)
        if cat:
            category = cat[1].strip()
            current["groups"].append((category, []))
            pending = None
            continue

        bullet = BULLET_RE.match(line)
        if bullet:
            item = bullet[1].strip()
            if category is None:
                current["intro"].append(item)  # stray bullet before any category
                pending = ("intro", len(current["intro"]) - 1)
            else:
                items = current["groups"][-1][1]
                items.append(item)
                pending = ("bullet", items)
            continue

        # Plain non-blank line: continue the pending bullet/paragraph, else start
        # a new one.
        stripped = line.strip()
        if pending and pending[0] == "intro":
            current["intro"][pending[1]] += " " + stripped
        elif pending and pending[0] == "bullet":
            pending[1][-1] += " " + stripped
        elif category is None:
            current["intro"].append(stripped)
            pending = ("intro", len(current["intro"]) - 1)
        else:
            items = current["groups"][-1][1]
            items.append(stripped)
            pending = ("bullet", items)

    return releases


def inline_md(text: str) -> str:
    """Escape HTML, then render `code` spans and [text](url) links. Minimal."""
    out = html.escape(text)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(
        r"\[([^\]]+)\]\((https?://[^)]+)\)",
        r'<a href="\2">\1</a>',
        out,
    )
    return out


def render_changelog_html(releases: list[dict]) -> str:
    sections = []
    for rel in releases:
        parts = [
            '    <section class="release">',
            f'      <h2>{html.escape(rel["version"])} '
            f'<span class="date">{html.escape(rel["date"])}</span></h2>',
        ]
        for intro in rel["intro"]:
            parts.append(f"      <p>{inline_md(intro)}</p>")
        for category, items in rel["groups"]:
            if not items:
                continue
            parts.append(f'      <h3>{html.escape(category)}</h3>')
            parts.append("      <ul>")
            for item in items:
                parts.append(f"        <li>{inline_md(item)}</li>")
            parts.append("      </ul>")
        parts.append("    </section>")
        sections.append("\n".join(parts))
    body = "\n".join(sections)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Changelog — Salish Tides</title>
  <meta name="description" content="What's new in Salish Tides — release notes.">
  <link rel="icon" href="logo.png">
  <link rel="stylesheet" href="/site.css">

  <style>
    /* Tokens, reset, and base body typography come from /site.css. */
    body {{
      margin: 0 auto;
      max-width: 62ch;
      padding: 3rem 1.25rem 4rem;
      font-size: 0.9375rem;
      line-height: 1.7;
    }}

    a {{ color: inherit; }}

    .back {{
      display: inline-block;
      margin-bottom: 2.5rem;
      color: var(--muted);
      text-decoration: none;
      font-size: 0.8125rem;
    }}
    .back:hover, .back:focus-visible {{ color: var(--fg); }}

    h1 {{ font-size: 1.25rem; margin: 0 0 2.5rem; }}

    .release + .release {{ margin-top: 1rem; }}

    h2 {{
      font-size: 1rem;
      margin: 2.75rem 0 0.75rem;
      padding-top: 1.5rem;
      border-top: 1px solid var(--rule);
    }}
    h2 .date {{
      color: var(--muted);
      font-size: 0.8125rem;
      font-weight: normal;
      margin-left: 0.5rem;
    }}

    h3 {{
      font-size: 0.8125rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--muted);
      margin: 1.5rem 0 0.4rem;
    }}

    ul {{ margin: 0 0 0.5rem; padding-left: 1.25rem; }}
    li {{ margin: 0 0 0.35rem; }}

    p {{ margin: 0 0 1rem; }}

    code {{
      font-size: 0.85em;
      padding: 0.1em 0.35em;
      border-radius: 4px;
      background: color-mix(in srgb, var(--fg) 8%, transparent);
    }}
  </style>
</head>
<body>
  <a class="back" href="/">&larr; salish tides</a>

  <h1>Changelog</h1>

{body}
</body>
</html>
"""


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_status(args: argparse.Namespace) -> None:
    marketing, build = current_versions()
    last_tag = last_release_tag()
    commits = commits_since(last_tag)

    if args.json:
        print(
            json.dumps(
                {
                    "marketing_version": marketing,
                    "build_number": build,
                    "last_release_tag": last_tag,
                    "is_first_release": last_tag is None,
                    "commit_count": len(commits),
                    "commits": commits,
                },
                indent=2,
            )
        )
        return

    print(f"MARKETING_VERSION       {marketing}")
    print(f"CURRENT_PROJECT_VERSION {build}")
    print(f"last release tag        {last_tag or '(none — first release)'}")
    print(f"commits since           {len(commits)}")
    print()
    for c in commits:
        pr = f" (#{c['pr']})" if c["pr"] else ""
        subject = PR_RE.sub("", c["subject"]).strip() if c["pr"] else c["subject"]
        print(f"  {c['short']}  {subject}{pr}")


def cmd_apply(args: argparse.Namespace) -> None:
    marketing = normalize_semver(args.version)
    _, cur_build = current_versions()
    if args.build is not None:
        new_build = args.build
    else:
        try:
            new_build = int(cur_build) + 1
        except ValueError:
            sys.exit(f"CURRENT_PROJECT_VERSION '{cur_build}' is not an integer")

    if not str(new_build).isdigit() or int(new_build) <= int(cur_build or 0):
        sys.exit(
            f"build number must be a strictly increasing integer "
            f"(current {cur_build}, requested {new_build})"
        )

    if args.dry_run:
        print(f"would set MARKETING_VERSION       = {marketing}")
        print(f"would set CURRENT_PROJECT_VERSION = {new_build}")
        return

    write_xcconfig(marketing, str(new_build))
    print(f"MARKETING_VERSION       = {marketing}")
    print(f"CURRENT_PROJECT_VERSION = {new_build}")


def cmd_render(args: argparse.Namespace) -> None:
    if not CHANGELOG.exists():
        sys.exit(f"{CHANGELOG} not found — nothing to render")
    releases = parse_changelog(CHANGELOG.read_text())
    if not releases:
        sys.exit("no release entries found in CHANGELOG.md")
    output = render_changelog_html(releases)

    if args.check:
        existing = CHANGELOG_HTML.read_text() if CHANGELOG_HTML.exists() else ""
        if existing != output:
            sys.exit("docs/changelog.html is out of date — run `release.py render`")
        print("docs/changelog.html is up to date")
        return

    CHANGELOG_HTML.write_text(output)
    latest = releases[0]
    print(f"wrote {CHANGELOG_HTML.relative_to(REPO_ROOT)} "
          f"({len(releases)} release(s), latest {latest['version']})")


def cmd_tag(args: argparse.Namespace) -> None:
    version = normalize_semver(args.version)
    tag = f"v{version}"
    existing = {t for _, t in release_tags()}
    if tag in existing:
        sys.exit(f"tag {tag} already exists")
    message = args.message or f"Release {version}"
    git("tag", "-a", tag, "-m", message)
    print(f"created annotated tag {tag}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="show versions + commits since last release")
    p_status.add_argument("--json", action="store_true", help="machine-readable output")
    p_status.set_defaults(func=cmd_status)

    p_apply = sub.add_parser("apply", help="write the Xcode version increment")
    p_apply.add_argument("--version", required=True, help="marketing version X.Y.Z")
    p_apply.add_argument("--build", type=int, help="build number (default: current + 1)")
    p_apply.add_argument("--dry-run", action="store_true")
    p_apply.set_defaults(func=cmd_apply)

    p_render = sub.add_parser("render", help="regenerate docs/changelog.html")
    p_render.add_argument("--check", action="store_true", help="verify, don't write")
    p_render.set_defaults(func=cmd_render)

    p_tag = sub.add_parser("tag", help="create the vX.Y.Z git tag")
    p_tag.add_argument("--version", required=True, help="marketing version X.Y.Z")
    p_tag.add_argument("--message", help="annotation (default: 'Release X.Y.Z')")
    p_tag.set_defaults(func=cmd_tag)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
