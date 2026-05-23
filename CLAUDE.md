# Trading Strategy Platform

## Branching Strategy

This repository follows a **prod → staging → feature** branching model.

### Branches

| Branch | Purpose | Protected |
|--------|---------|----------|
| `main` | Production. Never push directly. | Yes |
| `deployment` | Staging / integration. Always exists, always branched from `main`. | Yes |
| `feature/*` | All dev work. Branched from `deployment`. | No |

### Rules

1. **`main` is production** — direct pushes are forbidden. Changes reach `main` only via PR from `deployment`.
2. **`deployment` is staging** — always exists. It is always branched off `main` and is the base for all feature work. Changes reach `deployment` only via PR from a feature branch.
3. **Feature branches** — branch from `deployment`, not `main`. Name them `feature/<short-description>`. When done, open a PR back into `deployment`.

### Workflow

```
main (prod)
  └── deployment (staging)       ← always branched from main
        ├── feature/my-feature   ← branched from deployment
        ├── feature/another      ← branched from deployment
        └── ...
```

**Merge flow:**
```
feature/* → deployment → main
```

### Quick-start for a new feature

```bash
# 1. Make sure your local deployment branch is up to date
git checkout deployment
git pull origin deployment

# 2. Branch off deployment
git checkout -b feature/my-feature

# 3. Do your work, then push
git push -u origin feature/my-feature

# 4. Open a PR: feature/my-feature → deployment
# 5. After review + merge, open a PR: deployment → main
```

### For AI agents (Claude Code)

- **Never push directly to `main` or `deployment`.**
- All development work goes on a `feature/*` branch cut from `deployment`.
- PRs target `deployment` first, then `deployment` targets `main`.
- When creating a new repository under this project, apply the same three-tier structure.
