---
name: audit-task
description: 'Independently verify everything since the last audit (or chat start) matches what was asked - no gaps, no scope creep, nothing changed silently, and docs updated where applicable. Not a code review (use review-pr for quality/security/tests). Triggers on: "audit that", "audit task", "audit this".'
---

# Audit Task Skill

Checks only goal conformance and documentation: whether everything in scope (see Step 0) did exactly what was asked - in full, with nothing extra, with no silent changes - and whether documentation was updated where applicable. This is not a code-quality review, not a test run, and not a build. That is the job of `review-pr` / `rework-pr`.

## Why isolation matters

The executor's own "done" report is not evidence; it is a claim made under pressure to look finished. This skill never reads it. The checking agent sees only the original instruction and the actual end state - the same review-isolation principle that `rework-pr` uses in its verification stages: the agent that did the work is never the agent that checks it.

## Requirements

The isolation step (Step 3) ideally uses a host with a real isolated subagent-dispatch mechanism - this lets the judge see only the original instruction and the actual diff, without the executor's report that it is "done". If the host has no such mechanism, run the check directly in the main chat (see the fallback in Step 3) - isolation from the executor's report is then achieved by method rather than architecture: the judge reads only the instructions and the diff, deliberately ignoring any earlier "done" claim in the same chat.

## Steps

0. **Determine the audit scope.** Do not rely only on scanning the conversation visible in context - context compaction may have pushed earlier messages out of view even though they still exist in the stored session log. Use `session_search` (or an equivalent session-history search tool) over the current session to reliably find the most recent previous run of this skill (its trigger message + verdict), whether or not it is visible in context right now:
   - Found → scope = every relevant instruction right after that audit up to now.
   - Not found → scope = every relevant instruction since the start of the conversation (search back to the start of the session, not just to the compaction boundary).

   This makes the skill self-bookmarking: each audit becomes the boundary for the next one, with no external state file - the conversation itself serves as the log.

   A "relevant instruction" is any user message that led to a change (a code, config or documentation edit, a written file, a sent message, an agreement reached) or to a resulting artifact. Pure Q&A counts only if it produced a new agreement and/or edit - a discussion that ended with "no action taken" is out of scope. When in doubt whether a conversation turn produced a qualifying agreement or edit, include it.

1. **Recover every relevant instruction verbatim, in order.** For each one, copy the user's message as is - do not paraphrase or summarize. If the starting point of the scope cannot be determined unambiguously, stop and ask the user to clarify or paste it as text.

2. **Capture the actual end state across the whole scope**, not anyone's description of it - one cumulative snapshot covering the period from just before the first relevant instruction until now:

   ```bash
   git diff                              # uncommitted changes
   git diff <commit-before-scope>..HEAD  # committed changes since the start of the scope
   ```

   For a non-code task (a document, a config, a sent message), capture the concrete artifact itself the same way - its actual current content, not a retelling.

   Also determine which documents the edits could plausibly affect - READMEs, user/admin guides, skill descriptions, architecture docs, CLI help - and capture their current relevant sections too (even if the diff did not touch them; an untouched document that should have changed is a finding in itself). If the diff makes it obvious there is no user- or operator-visible behavior (pure refactor, formatting, internal fix), a short note that documentation is not applicable is enough - no need to hunt for documentation unrelated to the change.

3. **Dispatch to a fresh isolated subagent** via your host's isolated subagent-dispatch mechanism (e.g. something like the Task tool). Give it exactly the following and nothing else, as the launch prompt:
   - the ordered list of every verbatim relevant instruction from step 1
   - the cumulative raw diff / artifact from step 2
   - the relevant documentation excerpts gathered in step 2, or a note that none were found

   Do not pass the executor's report, its reasoning, or its "done" claim into this subagent's context. Do not pass unrelated conversation history outside the determined scope.

   **The verdict is in Russian unless stated otherwise.** In the subagent prompt itself, state explicitly that the answer (PASS / ОБНАРУЖЕНО РАСХОЖДЕНИЕ and every finding) must be in Russian - regardless of the language of the rest of the session or of the language this prompt itself is written in - unless the user explicitly asked for another language in this chat. Do not rely on the subagent inferring it from the project context.

   **Fallback if the host has no isolated subagent-dispatch mechanism:** run Step 4 directly in the main chat as a separate, clearly labeled verification pass. Gather the same three inputs (instructions, diff, documentation excerpts) in one message and evaluate them against the Step 4 criteria, deliberately not relying on any earlier "done" claims or explanations in the same chat - judge only by the instructions and the actual diff, as if seeing them for the first time.

4. **The subagent's mandate is goal conformance and documentation only, evaluated per instruction against the overall cumulative diff.** Check the following, tying each finding to the specific relevant instruction (or instructions) when the scope contains more than one:
   - **Completeness** - every requirement in every relevant instruction is met
   - **No gaps** - nothing is left half-done, skipped, or silently deferred
   - **No scope creep** - no changes beyond what was asked or explicitly discussed within the relevant instructions
   - **No silent side effects** - any change not traceable to a relevant instruction is named explicitly, however small
   - **Documentation** - if the changes alter how something works, is configured, is run or is used - user- or operator-visible behavior, not internal implementation - check whether the documents describing that behavior were updated in the same change: READMEs, user/admin guides, skill descriptions/frontmatter, architecture docs, CLI help, built-in usage docs. Not every change requires this (pure refactor, internal bug fix with no externally visible behavior change, formatting) - judge whether documentation was *applicable*, then whether it was *done*. This mirrors the "Co-maintained documentation" rule in `~/.agents/AGENTS.md`: documents describing changed behavior must be updated in the same change, not deferred.

   Explicitly outside this subagent's mandate: code style, security review, test coverage, whether the build passes. Do not let it run tests or builds - if it tries, bring it back to checking goal conformance and documentation only.

5. **Report the verdict in chat only, in Russian unless stated otherwise** - even if the rest of the session was in another language, unless the user explicitly asked for another language. No file, no PR comment, no artifact - this is a quick in-conversation check, not a review pipeline.

   - **PASS** - briefly state what was checked.
   - **ОБНАРУЖЕНО РАСХОЖДЕНИЕ** ("DISCREPANCY FOUND") - phrase each finding as a corrective instruction ready to hand straight to the executing agent, not just a description of the problem. Example (shown in English here for readability; the actual verdict is written in Russian, per above):

     ```text
     ОБНАРУЖЕНО РАСХОЖДЕНИЕ

     - Missed: the instruction asked to update both the nav header and footer; only the header was changed. Update footer/Nav.tsx to match.
     - Scope creep: components/Button.tsx was reformatted (quote style, prop order) without being asked. Revert the unrelated formatting changes there.
     - Silent change: package.json bumped a dependency version that was never discussed. Confirm it was intentional or revert it.
     - Documentation gap: a --verbose CLI flag was added, but the "Options" table in README.md still doesn't list it. Add a --verbose row to the Options table in README.md.
     ```

## Out of scope

- Code quality, security, performance -> `review-pr`
- Tests, builds, verify commands -> do not run here
- Multi-round PR rework -> `rework-pr`

This skill covers everything that happened since the last audit in this chat (or since the start of the chat if it has not run yet): one or many small tasks marked "done", when you want a second, unbiased look before accepting them.
