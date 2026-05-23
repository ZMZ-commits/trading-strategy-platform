# Contributing

Please read the branching strategy in [CLAUDE.md](../CLAUDE.md) before contributing.

## Branch rules (enforced)

- `main` — production, **no direct pushes**.
- `deployment` — staging, **no direct pushes**; PRs only from `feature/*` branches.
- `feature/*` — your working branch, cut from `deployment`.

## Opening a PR

- Feature work → open PR into **`deployment`**.
- Release to prod → open PR from **`deployment`** into **`main`**.
