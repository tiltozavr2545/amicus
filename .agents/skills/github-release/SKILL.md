---
name: github-release
description: Publish an Amicus GitHub release - build APK, tag, notes.
---

# GitHub Release (Amicus)

Creates exactly one GitHub release for a single specific `develop` -> `main`
PR - never sweeps or backfills intermediate versions. Amicus ships two
release channels independently: Google Play (via `deploy-closed-testing.yml`,
`.aab`) and a sideloadable GitHub release (`.apk`, this skill). They share
nothing except the version number.

## Usage

```text
github-release [--version X.Y.Z]
```

- **`--version X.Y.Z`** (optional): identifies the release by its
  major.minor.patch only - the build-number suffix and exact tag are
  resolved from the matching merged `develop` -> `main` PR, not typed by
  hand. Matches loosely: `--version 0.18.3` finds the PR whose
  `pubspec.yaml` version starts with `0.18.3+` regardless of build number,
  and works whether given as `0.18.3`, `v0.18.3`, or the full `0.18.3+54`.
- **No `--version`** (default): use the single most recently merged
  `develop` -> `main` PR - never sweep or backfill older ones.

## Preconditions

- The target PR already merged the version bump into `main` (this skill
  does not bump versions or open PRs - see the release-shipping flow
  already used in this repo: bump `pubspec.yaml`, commit, PR, merge,
  backmerge).
- No release/tag exists yet for that PR's version.

## Steps

1. **Identify the release PR.** A release is tied to one specific PR that
   merged `develop` into `main` - not to whatever `pubspec.yaml` happens to
   say on disk right now.
   ```bash
   gh pr list --base main --state merged --limit 20 \
     --json number,title,mergedAt,mergeCommit
   ```
   - If `--version` was given: scan the list for the PR whose merge commit's
     `app/pubspec.yaml` (`git show <mergeCommit>:app/pubspec.yaml`) has a
     `version:` line starting with the given major.minor.patch. If none
     match within the last 20 PRs, widen the search before giving up - do
     not assume it doesn't exist from just the first page.
   - If no `--version`: take the single most recent PR in the list.
   Record its `mergeCommit` SHA and the exact `version: X.Y.Z+N` string -
   the tag and filename use `X.Y.Z` only, dropping `+N` (e.g. `0.18.3+54`
   -> tag `v0.18.3`, filename `amicus-0.18.3.apk`).

2. **Confirm no duplicate.** If `gh release view v<X.Y.Z>` already succeeds,
   a release for this version already exists - do not overwrite or re-tag.
   Tell the user plainly ("v<X.Y.Z> is already released") and suggest the
   real fix: bump `pubspec.yaml` to the next version, commit, open a PR
   `develop` -> `main`, merge it, then re-run this skill against that new
   PR. Do not guess a version bump yourself or invent a new tag to work
   around the collision.

3. **Write the release body in Russian**, matching every prior release
   exactly in structure (verify against 2-3 recent releases with
   `gh release view v<prev> --json body -q '.body'` before writing - do not
   rely on memory of the format, it must match verbatim style):
   ```text
   APK для Android (universal, sideload).

   ## Что нового с <предыдущая версия>

   <one bolded-lead-sentence bullet per user-visible change since the
   previous release tag, written for an end user - not a commit-log dump.
   Pull the actual changes from the release PR's diff/description and
   `CHANGELOG.md`, then describe user impact, the same voice as existing
   release bodies>
   ```
   The `<предыдущая версия>` is the version of the immediately preceding
   PUBLISHED GitHub release - not "one PR back" and not "one version-bump
   back." Versions get skipped routinely (a version can be bumped and
   merged to `main` without ever getting its own GitHub release, e.g. via
   this skill's own duplicate-avoidance in step 2, or simply because nobody
   ran this skill for it). Get it from GitHub's actual release list, not
   from git tags or PR history:
   ```bash
   gh release list --limit 5
   ```
   Take the newest release whose version sorts below the one being created
   now - do not assume it is adjacent in the PR sequence, and do not assume
   `git tag --sort=-creatordate` matches this (tag creation order is not
   guaranteed to match semantic version order if a release was ever made
   out of sequence). The changelog scope is then "everything since that
   actual previous release," which may span several skipped versions/PRs -
   summarize their combined user-visible impact from `CHANGELOG.md` and PR
   history between the two points, not just the single latest PR's diff.

   **Scope filter - only changes that ship inside the APK.** Before
   drafting bullets, drop any PR or `CHANGELOG.md` entry confined entirely
   to non-shipping paths - `.agents/`, `.claude/`, skill definitions
   anywhere in the repo, `docs/`, `AGENTS.md`/`CLAUDE.md`, or CI/workflow
   files that aren't themselves compiled into the app. A sideloaded APK
   release describes what changed in the thing being installed, not in the
   repo's own tooling - a skill addition or a translation of a skill's
   instructions has zero effect on the built binary and does not belong in
   these notes. In this repo, tooling-only PRs are already conventionally
   titled `(tooling only, ...)` - treat that as a strong hint, but confirm
   by checking whether the PR's diff actually touches `app/`, `android/`,
   or an app-facing `supabase/` migration; if none of those are touched,
   the PR contributes nothing to this changelog and should not appear as a
   bullet, even indirectly (e.g. do not fold it into an adjacent bullet's
   wording either).

   **Correctness warning - a bullet can be true of the current version and
   still mislead relative to the previous RELEASED version.** Do not phrase
   a bullet purely from the latest PR's diff without checking whether the
   thing it "fixes" even existed as a problem back at `<предыдущая
   версия>`. Concretely seen in this repo: a PR fixed an icon-margin
   regression that was introduced two versions after the last real release
   - phrasing it as "the icon now has a margin" implied margins were
   missing since that release, when the actual state at that release (the
   plain Flutter default icon) never had the bug at all. The regression and
   its fix both happened invisibly between releases. Before writing each
   bullet, walk the full intermediate history (`CHANGELOG.md` entries and
   PR titles for every version between `<предыдущая версия>` and this one,
   not just the two endpoints) and describe the NET change relative to what
   a user on the previous release actually experienced - not the literal
   text of whichever intermediate PR happened to touch that area last.

4. **Show the release body to the user and stop for approval before doing
   anything else.** Print the exact text from step 3 in full, plainly, with
   no build, tag, or worktree work yet. This is not an optional "dry run"
   flag - it is a mandatory gate every time this skill runs, since the APK
   build and the GitHub publish are the two expensive/irreversible parts.
   Wait for explicit approval or requested edits before proceeding to step
   5. If the user asks for changes, revise and show the updated text again
   before continuing - do not proceed on a corrected draft without a fresh
   confirmation.

5. **Tag and publish the release itself first, without any asset yet.**
   The APK-build workflow (next step) requires the release to already
   exist, so this has to happen before it. Point at the release PR's merge
   commit specifically:
   ```bash
   gh release create v<X.Y.Z> \
     --target <mergeCommit-sha-from-step-1> \
     --title "Amicus vX.Y.Z" \
     --notes-file <body-file-from-step-3>
   ```
   This creates the git tag at that commit automatically - do not
   pre-create the tag with `git tag` first, `gh release create` does both
   atomically and this is what every prior release in this repo did
   (`git for-each-ref refs/tags/v<X> --format='%(contents)'` on past tags
   shows only the release title, confirming `gh` authored them, not a
   manual `git tag -a`).

6. **Build the signed APK via the `github-release-apk.yml` GitHub Actions
   workflow, and let it attach the asset to the release above.** This
   machine has no release-signing keystore; the signing secrets
   (`ANDROID_KEYSTORE_BASE64` and friends) exist only in GitHub Actions,
   the same secrets `deploy-closed-testing.yml` already uses. Trigger it
   against the release PR's merge commit and wait for it to finish:
   ```bash
   gh workflow run github-release-apk.yml \
     -f ref=<mergeCommit-sha-from-step-1> \
     -f tag=v<X.Y.Z>
   gh run watch $(gh run list --workflow=github-release-apk.yml --limit 1 --json databaseId -q '.[0].databaseId')
   ```
   The workflow refuses to run if the target release doesn't exist (hence
   step 5 running first) or already has an `.apk` asset attached - delete
   the stale asset first if intentionally re-running this step.

7. **Verify**: `gh release view v<X.Y.Z>` shows the release with the APK
   asset attached (after step 6's workflow completes) and the `Latest`
   marker. Report the release URL back to the user - do not open a browser
   tab unless asked.

## What this skill does NOT do

- Does not bump the version or touch `pubspec.yaml`/`CHANGELOG.md` - those
  are already committed on `main` before this skill runs.
- Does not touch Google Play (`deploy-closed-testing.yml` handles that
  automatically on push to `main`).
- Does not create intermediate releases for versions that were skipped -
  only the single targeted version, per explicit instruction from the user
  who owns this repo.
- Does not build the APK on this machine or touch any local checkout for
  the build - `github-release-apk.yml` builds it in GitHub Actions from
  the release PR's exact merge commit, using CI's signing secrets, and
  never touches local `main`/`develop` (which may be ahead, behind, or
  have uncommitted changes - irrelevant either way).
- Does not build the APK or publish anything before the user has seen and
  approved the release notes text (step 4).
