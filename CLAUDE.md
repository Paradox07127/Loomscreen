# Project conventions

## Comments — write few, write "why"
- Do NOT narrate the code. No comment that restates the next line, the signature,
  or a default value. No `// MARK`-style preambles like "Helper that…",
  "Convenience init…", "Computes the…".
- Comment ONLY non-obvious "why": bug/regression history (with commit refs),
  magic-number/formula rationale, threading/ordering constraints, cross-references,
  `defaults write` ops knobs, security reasoning.
- Prefer one tight line over a paragraph. If the code is clear, write nothing.
- Default to fewer comments than feels natural — this codebase was over-commented
  and is being trimmed back.

## Git
- **Commit messages**: keep them short — a concise subject line plus at most 2–3 lines of context. No long bullet-by-bullet enumerations.
- **PR descriptions**: same — 2–3 lines summarizing what changed and why. No exhaustive per-item tables or walls of text.
- Keep ending commit messages with the required `Co-Authored-By` trailer.
