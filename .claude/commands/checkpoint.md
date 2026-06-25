---
description: Append a concise dated progress checkpoint to docs/WORK_CHECKPOINTS.md
---

Write a CONCISE progress checkpoint of what's been accomplished in this session
and add it to `docs/WORK_CHECKPOINTS.md` (create the file with a `# Work Checkpoints`
header if it doesn't exist).

Rules:
- **Keep it short** — ~10–20 lines, bullets over prose. This file is meant to be
  read back into future sessions, so brevity matters; do NOT blow up the context
  window. Choose the level of detail yourself, but err toward concise.
- Capture only **durable, high-signal facts**: features shipped, key decisions,
  current state (what's in prod vs dev), and what's next. Skip play-by-play,
  command output, and anything obvious from git history.
- Don't duplicate `ROADMAP.md` / `AI_CONTEXT.md` — this is a dated session log,
  not the spec. Cross-reference them instead of repeating.
- **Insert the new entry at the TOP** (just under the `# Work Checkpoints` header),
  keeping older entries below. Never overwrite prior entries.
- Entry format:
  ```
  ## <YYYY-MM-DD> — <one-line title>
  - bullet
  - bullet
  ```
- If `$ARGUMENTS` is given, use it as the entry's title/focus.
- Just write the file (don't commit/push unless I ask). Afterward, show me only
  the entry you added — not the whole file.
