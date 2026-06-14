# AI Onboarding & Context Protocol

> **Purpose:** give any AI assistant (Claude Code, a cloud agent, or any other)
> the *latest* understanding of this platform at the start of a session, and a
> repeatable routine for keeping that understanding documented so the next
> session starts warm. This solves the "context resets every session" problem.

---

## 0. Read this first, every session (the bootstrap prompt)

Copy/paste this at the start of a new session, or rely on the pointer in the
platform `CLAUDE.md` (auto-loaded by Claude Code):

> **START-OF-SESSION PROTOCOL — do this before any work:**
> 1. Read `docs/ARCHITECTURE.md` (overall system, diagram, deploy topology).
> 2. Read the `AI_CONTEXT.md` of every repo you'll touch (its functions,
>    features, and "Latest Changes (Living)").
> 3. **Recompute the live git state** — do NOT trust the dated snapshots in the
>    docs. Run the "newest branch" one-liner (§2). The newest branch per repo is
>    the source of truth for "latest", even if that's `staging` or `dev`, not
>    `main`.
> 4. Only then start the task.

---

## 1. The 5 repositories (and where they live locally)

| Repo | Local path | Deep-dive doc |
|------|-----------|---------------|
| platform | `F:\Projects\trading-strategy-platform` | `docs/ARCHITECTURE.md` (this is the hub) |
| backend | `F:\Projects\trading-strategy-backend` | `AI_CONTEXT.md` |
| engine | `F:\Projects\trading-strategy-engine` | `AI_CONTEXT.md` |
| data-pipeline | `F:\Projects\trading-strategy-data-pipeline` | `AI_CONTEXT.md` |
| ui | `F:\Projects\trading-strategy-ui` | `AI_CONTEXT.md` |

Progress / project-management history lives in **GitLab**, not in these docs.
These docs describe **what exists in the code now** and **what's changed lately**
— they are not a sprint log.

---

## 2. How to find the *latest* code (don't assume `main`)

The branching model is `feature/* → dev → staging → main`. Promotion is by PR, so
at any moment `dev` or `staging` may be **ahead of** `main` with work that isn't
in production yet. To find the freshest branch per repo:

```bash
for r in trading-strategy-platform trading-strategy-backend \
         trading-strategy-data-pipeline trading-strategy-engine \
         trading-strategy-ui; do
  git -C "F:/Projects/$r" fetch -q --all
  latest=$(for b in dev staging main; do \
    echo "$(git -C F:/Projects/$r log -1 --format='%ct' origin/$b) $b"; \
  done | sort -rn | head -1 | awk '{print $2}')
  echo "$r → newest branch = $latest"
done
```

To see *what* is newer (e.g. what's in `staging` but not yet in `main`):

```bash
git -C F:/Projects/<repo> log origin/main..origin/staging --no-merges --oneline
```

---

## 3. The maintenance routine (keep docs current)

Run this **at the end of any session that changed code**, or whenever asked to
"update the context / readmes". Do it for each repo you touched:

1. **Re-derive the facts from the repo**, don't guess:
   - Functions/features changed → update that repo's `AI_CONTEXT.md`
     "Functions & Modules" and "Features" sections.
   - New commits → prepend a bullet to "Latest Changes (Living)" with the date
     and the branch the change is on.
2. **Update the cross-repo view** in `docs/ARCHITECTURE.md`:
   - If connectivity/deploy changed → update §2/§3 and the Mermaid diagram.
   - Refresh the "Last synced" date and the §5 Live state dashboard snapshot
     (re-run the one-liner in §2 above to get accurate branch state).
3. **Keep it honest:** the docs are a *convenience snapshot*. Live `git` state
   always wins. If a doc and the repo disagree, fix the doc and trust the repo.
4. **Don't duplicate:** per-repo detail lives in that repo's `AI_CONTEXT.md`;
   `ARCHITECTURE.md` only carries the cross-cutting/system view and links out.

### Commit rules (important)
`main`, `staging`, `dev` are protected — **never commit doc updates directly to
them.** Put doc changes on a `feature/*` branch cut from `dev` and PR up the
chain, exactly like code (see `CLAUDE.md`). Each repo owns *its own* `AI_CONTEXT.md`;
the platform repo owns `docs/`.

---

## 4. Optional: make the bootstrap automatic

- **Already wired:** the platform `CLAUDE.md` has a "START HERE" block at the top.
  Because Claude Code auto-loads `CLAUDE.md`, every session sees the pointer.
- **Stronger option (SessionStart hook):** add a hook in
  `.claude/settings.json` that prints a reminder to read these docs at the start
  of every session. Example:
  ```json
  {
    "hooks": {
      "SessionStart": [
        { "hooks": [ { "type": "command",
          "command": "echo '📖 Read docs/ARCHITECTURE.md + each repo AI_CONTEXT.md, then recompute the newest branch per repo (docs/AI_ONBOARDING.md §2) before starting.'" } ] }
      ]
    }
  }
  ```
  This makes the reminder fire automatically, not just when `CLAUDE.md` is read.

---

## 5. Document map (what to read for what)

| You need… | Read |
|-----------|------|
| The big picture / how things connect | `docs/ARCHITECTURE.md` §1–3 |
| Which branch is newest / what's unreleased | `docs/ARCHITECTURE.md` §5 + the §2 one-liner here |
| What a specific repo's code does | that repo's `AI_CONTEXT.md` |
| Recent changes in a repo | that repo's `AI_CONTEXT.md` → "Latest Changes (Living)" |
| Branching/PR rules | `CLAUDE.md` |
| How to deploy | `DEPLOY.md`, `DEPLOY_AWS.md`, `deploy/README.md` |
