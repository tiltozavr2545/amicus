# CLAUDE.md

Context for Claude Code when working in this repository.

All the content lives in @AGENTS.md, shared by every agent (Codex, Claude Code,
etc.). There are currently no Claude Code-specific differences.

Comments in historical migrations (the `pre-baseline-migrations*` tags) and a
few comments inside function bodies carried into the baseline verbatim refer
to «Грабли в CLAUDE.md» and «Конвенции работы в CLAUDE.md» — they mean
AGENTS.md, where «Грабли» is now the "Pitfalls" section and «Конвенции работы»
is "Working conventions". This is historical: there used to be one file, its
content moved, and comments in already-applied migrations were not rewritten —
they are a journal, not a living document. Baseline function bodies must match
production byte for byte, so they are not edited just to fix a reference.
In `docs/` itself and in the README, links point straight to AGENTS.md.
