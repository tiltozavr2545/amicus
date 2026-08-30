---
name: audit-task
description: 'Independently verify everything since the last audit (or chat start) matches what was asked - no gaps, no scope creep, nothing changed silently, and docs updated where applicable. Not a code review (use review-pr for quality/security/tests). Triggers on: "audit that", "audit task", "audit this".'
---

# Audit Task Skill

Checks goal-alignment and documentation only: did everything in scope (see Step 0) do exactly what was asked - the whole thing, nothing extra, nothing silent - and were the docs describing changed behavior updated where applicable. It does not review code quality, run tests, or run builds. Those are `review-pr` / `rework-pr`'s job.

## Why isolation matters

The implementer's own "I'm finished" summary is not evidence - it is a claim under pressure to look complete. This skill never reads it. The judging agent sees only the original instruction and the actual resulting state, the same review-isolation principle `rework-pr` uses for its judging phases: the agent that did the work is never the agent that verifies it.

## Requirements

This skill's isolation step (Step 3) needs a host with a real isolated-subagent-dispatch mechanism. Without one, Step 3 has no way to isolate the judge from the implementer's own summary, which defeats the point of the skill - confirm your host has this before relying on this skill.

## Steps

0. **Determine audit scope.** Do not rely on scanning the visible in-context conversation alone - context compaction may have dropped earlier messages from view while they still exist in the persisted session log. Use `session_search` (or the equivalent session/history search tool) against the current session to reliably find the most recent prior invocation of this skill (its trigger message + verdict), regardless of whether it's still in-context:
   - Found → scope = every in-scope instruction from immediately after that prior audit up to now.
   - Not found → scope = every in-scope instruction since the start of the conversation (search back to the session's start, not just to the compaction boundary).

   This makes the skill self-bookmarking: each audit becomes the boundary marker for the next one, no external state file needed - the conversation itself is the ledger.

   An "in-scope instruction" is any user message that led to a change (code edit, config/doc edit, file written, message sent, agreement reached) or a resulting artifact. A pure question-and-answer exchange only counts if it produced a new agreement and/or an edit - discussion that resolved into "no action taken" is not in scope. When in doubt whether a turn produced a qualifying agreement or edit, err on the side of including it.

1. **Recover every in-scope instruction verbatim, in order.** For each one, copy the user's message as written - do not paraphrase or summarize. If the scope's start point cannot be found unambiguously, stop and ask the user to clarify or paste it.

2. **Capture the actual resulting state across the whole scope**, not anyone's description of it - one cumulative capture spanning from before the first in-scope instruction to now:

   ```bash
   git diff                              # uncommitted changes
   git diff <commit-before-scope>..HEAD  # committed changes since the scope started
   ```

   For a non-code task (a doc, a config, a message sent), capture the concrete artifact itself the same way - the actual current content, not a summary of it.

   Also identify any docs the changes could plausibly touch - README, user/admin guides, skill descriptions, architecture docs, CLI help - and capture their current relevant sections too (even if untouched by the diff; an untouched doc that should have changed is itself a finding). If the diff clearly has no user/operator-visible behavior (pure refactor, formatting, internal-only fix), a quick note that no docs apply is enough - do not go hunting for documentation that has no bearing on the change.

3. **Dispatch to a fresh, isolated subagent** using your host's isolated-subagent-dispatch mechanism (e.g. a Task-tool-style subagent). Give it exactly these things and nothing else - as the dispatch prompt:
   - the ordered list of every verbatim in-scope instruction from step 1
   - the cumulative raw diff / artifact from step 2
   - the relevant doc excerpts gathered in step 2, or a note that none applied

   Do not pass the implementer's summary, reasoning, or "done" claim into this subagent's context. Do not pass unrelated conversation history outside the determined scope.

4. **The subagent's mandate is alignment and documentation only, judged per instruction against the shared cumulative diff.** Check, attributing each finding to the specific in-scope instruction(s) it relates to when more than one instruction is in scope:
   - **Completeness** - every requirement in every in-scope instruction was addressed
   - **No omission** - nothing was left half-done, skipped, or silently deferred
   - **No scope creep** - no changes beyond what was asked or explicitly discussed across the in-scope instructions
   - **No silent side effects** - any change not traceable to an in-scope instruction gets named, even a small one
   - **Documentation** - if the changes alter how something works, is configured, is run, or is used - user-facing or operator-facing behavior, not internal implementation detail - check whether the docs that describe that behavior were updated in the same change: READMEs, user guides, admin guides, skill descriptions/frontmatter, architecture docs, CLI help text, inline usage docs. Not every change needs this (pure refactors, internal bug fixes with no externally visible behavior change, formatting) - judge whether documentation was *applicable*, then whether it was *done*. This mirrors the "Documentation Co-Maintenance" rule in `~/.agents/AGENTS.md`: docs describing changed behavior must be updated in the same change, not left for later.

   Explicitly out of scope for this subagent: code style, security review, test coverage, whether the build passes. Do not let it run tests or builds - if it tries, redirect it back to alignment and documentation only.

5. **Report the verdict in chat only.** No file, no PR comment, no artifact - this is a fast conversational check, not a review pipeline.

   - **PASS** - state briefly what was verified.
   - **DRIFT DETECTED** - for every finding, phrase it as a corrective instruction ready to hand straight back to the implementing agent, not just a description of the problem. Example:

     ```text
     DRIFT DETECTED

     - Omitted: the instruction asked to update both the header and footer nav links; only the header was changed. Update footer/Nav.tsx to match.
     - Scope creep: components/Button.tsx was reformatted (quote style, prop order) with no request to touch it. Revert the unrelated formatting changes there.
     - Silent change: package.json bumped a dependency version that was never discussed. Confirm this was intentional or revert it.
     - Documentation gap: the CLI's --verbose flag was added but README.md's "Options" table still doesn't list it. Add a row for --verbose to README.md's Options table.
     ```

## Out of scope

- Code quality, security, performance -> `review-pr`
- Tests, builds, verify commands -> do not run them here
- Multi-round PR rework -> `rework-pr`

This skill covers everything since the last audit in this chat (or since chat start, if never run before): one or many small tasks marked "done", and you want a second, unbiased pair of eyes before you accept that.
