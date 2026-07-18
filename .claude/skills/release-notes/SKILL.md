---
name: release-notes
description: Cut a Salish Tides release — turn the commits since the last release tag into user-facing release notes, bump the Xcode version per semantic versioning, update CHANGELOG.md + the website changelog page, and tag it. Use when the user wants to "cut a release", "make release notes", "bump the version", "ship a new version", or "update the changelog".
---

# Release notes + version bump

Cut a release for Salish Tides. The flow is: read what changed since the last
release, write human release notes, choose a semver bump, apply the real Xcode
version increment, render the website, and tag it. Stop before committing so the
user reviews.

**Source of truth:** `CHANGELOG.md` (Keep a Changelog style) is canonical.
`docs/changelog.html` and the git tags are generated from it. `MARKETING_VERSION`
in `Config/Base.xcconfig` mirrors the latest released version.

The deterministic plumbing lives in `dev/release/release.py` (stdlib Python). You
supply the judgement: summarizing commits and choosing the bump level.

## Steps

### 1. Read the state

```bash
python3 dev/release/release.py status --json
```

This gives you the current `MARKETING_VERSION`, the build number, the last release
tag (or `is_first_release: true` if there are none), and every commit since it
with subject + PR number. If `commit_count` is 0, tell the user there's nothing
to release and stop.

### 2. Choose the version

Semantic versioning, `MAJOR.MINOR.PATCH`:

- **MAJOR** — breaking changes, data-format migrations users must be aware of, a
  redesign that changes how the app is used.
- **MINOR** — new user-facing features or capabilities, backward compatible
  (a new model, a new layer, a new setting).
- **PATCH** — bug fixes, polish, performance, docs, internal refactors with no
  user-visible feature.

Infer the level from the commits. Ignore purely internal churn (CI, build
plumbing, test-only, tooling) when deciding — it doesn't move the user-facing
version, though it can still appear under an "Internal" note if relevant.

If `is_first_release` is true, the version is the current `MARKETING_VERSION`
normalized to three parts (e.g. `1.0` → `1.0.0`) — a baseline, not a bump — unless
the user says otherwise.

**Propose, then confirm.** Present the suggested version and a one-line rationale,
and the grouped notes you're about to write (below). Let the user accept or
override the level before you write anything. Never skip this confirmation.

### 3. Write the release notes

These are for **users**, not developers. Rewrite terse commit subjects into plain,
benefit-oriented lines. Group them under Keep-a-Changelog categories, in this
order, omitting any that are empty:

- **Added** — new features/capabilities.
- **Changed** — changes to existing behavior.
- **Fixed** — bug fixes.
- **Removed** — removed features.

Rules:
- Merge related commits into one line; drop noise (merge commits, `(#NN)` refs,
  reverts that cancel out). Don't emit one bullet per commit.
- No commit hashes, no PR numbers, no internal file/type names. Say what changed
  for someone using the app.
- Sentence case, no trailing period, imperative-ish but readable
  ("Extend offline currents up the outer coast to SE Alaska", not "feat: webtide").
- For a first release, lead with a one-paragraph intro under the version header
  (plain lines before the first `###`), then the categories.

Prepend the new entry to `CHANGELOG.md` (newest first), directly under the intro
preamble and above the previous release. Create `CHANGELOG.md` with a title +
one-line preamble if it doesn't exist. Header format is exact — the renderer
parses it:

```markdown
## [1.1.0] - 2026-07-17

### Added
- Extend offline currents up the outer coast to SE Alaska

### Fixed
- Snap the timeline "now" marker to the nearest hour
```

Use today's real date (`YYYY-MM-DD`); it's in your session context — don't shell
out for it.

### 4. Apply the Xcode version increment

```bash
python3 dev/release/release.py apply --version X.Y.Z
```

This sets `MARKETING_VERSION = X.Y.Z` and bumps `CURRENT_PROJECT_VERSION` (the
build number) by one in `Config/Base.xcconfig`. The build number is monotonic and
independent of the marketing version — App Store / TestFlight require it to strictly
increase per uploaded binary, so it goes up on every release regardless of the
bump level. Use `--dry-run` first if you want to preview.

### 5. Render the website

```bash
python3 dev/release/release.py render
```

Regenerates `docs/changelog.html` from `CHANGELOG.md`. The page is linked from the
site nav (`docs/index.html`) as "changelog". Never hand-edit `docs/changelog.html`
— it's generated; edit `CHANGELOG.md` and re-render. `release.py render --check`
verifies they're in sync (useful in CI).

### 6. Tag it — on the release commit, not before it

The tag `vX.Y.Z` must sit on the commit that carries the version bump + changelog,
because it's the anchor the *next* release measures its commits against. Since this
flow stops before committing, the release commit doesn't exist yet — so **do not**
run `release.py tag` against the current (pre-release) HEAD; that would strand the
tag one commit behind.

Instead, hand the user a single block that commits and tags together, so the tag
lands on the right commit:

```bash
git add Config/Base.xcconfig CHANGELOG.md docs/changelog.html docs/index.html
git commit -m "Release X.Y.Z"
python3 dev/release/release.py tag --version X.Y.Z   # or: git tag -a vX.Y.Z -m "Release X.Y.Z"
git push --follow-tags
```

(`release.py tag` is provided for when the release is *already* committed — e.g. a
later run on a clean tree, or after a merge to main. It refuses to duplicate an
existing tag.)

### 7. Stop and report

Do **not** commit, tag, or push yourself. Summarize what changed:
- version: old → new, build number old → new
- files touched: `Config/Base.xcconfig`, `CHANGELOG.md`, `docs/changelog.html`,
  and `docs/index.html` (only if the changelog nav link wasn't there yet)
- the exact commit + tag + push block from step 6

Show the user the new changelog entry so they can review the wording before it's
committed.

## Notes

- The tag must be created **on the commit that will ship**. If the user is on a
  feature branch that isn't merged to `main`, say so — they'll likely tag after
  merging, or move an existing tag with `git tag -f vX.Y.Z <sha>`.
- If `status` shows the working tree already at the target version, you've likely
  already run this — check `git tag` and `CHANGELOG.md` before redoing it.
- Everything here is reversible before commit: `git checkout Config/Base.xcconfig
  CHANGELOG.md docs/changelog.html docs/index.html`.
