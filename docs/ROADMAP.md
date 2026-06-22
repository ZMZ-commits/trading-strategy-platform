# Roadmap — Custom Indicator/Strategy IDE, Data, Replay

> Living plan for the in-progress features. Captures decisions so a new session
> doesn't re-derive them. Pairs with [`ARCHITECTURE.md`](ARCHITECTURE.md) (current
> system) — this doc is the *future* system. **Last updated:** 2026-06-21.

---

## 1. Vision

A user (eventually any logged-in user) can author **custom indicators** and
**strategies** in a web IDE (JupyterLab), backed by Python, save them, select
them later, and **replay** them over any historical window to watch them work.

The end-state UX:
- Click **+ Add Indicator / + Add Strategy** → name it → a **Jupyter notebook**
  opens (left), with the **chart on the right**.
- Author a `compute(ctx)` (indicator) or `on_bar(ctx)` (strategy) using the
  **`tsp` SDK**; preview inline.
- **Publish** (login required) → it's saved, appears in the sidebar, and renders
  on the chart (indicators) or runs as a strategy (signals/metrics).
- **Bar Replay**: pick any time period / any length / any speed → watch the
  indicator extend or the strategy fire trades bar-by-bar.

---

## 2. Current state (built / deployed)

- **UI:** Navigator sidebar — **Indicators** (Overlays / Oscillators, searchable,
  `+` for custom) · **Strategies** (create/run/select, searchable, `+`) · **Saved
  Dashboard Views** (placeholder). Collapsible top/bottom panels. Chart with
  overlays + oscillator panes; ranges incl. 5D/3M/6M/YTD. Floating widget removed.
- **Backend:** FastAPI — stocks/indicators (yfinance), strategies (file store),
  engine execution, live-tick WebSocket, and **`/stocks/{ticker}/custom/{slug}`**
  (delegates to the sandbox to run published indicators).
- **Data:** yfinance (history/quotes) + Alpaca (live ticks via pipeline→Redis).
- **Infra:** Hetzner VM, Docker Compose — caddy, redis, pipeline, 3 backends,
  **jupyterlab** (owner-only authoring, localhost-only) + **sandbox** (now runs the
  real `tsp` worker, reads the registry JupyterLab publishes to). **Infra
  auto-deploys** on push to `main` (deploy/**), with GHCR login + sandbox image pull.
- **`tsp` SDK + execution loop (Phase 1b) — DONE & verified end-to-end:** author
  `compute(ctx)` → `publish()` → registry → backend `/custom` → sandbox runs it →
  series. Verified on dev (clean 404 for an unpublished slug = chain live).

**Not built yet:** chart wiring to *render* a custom indicator (#3), artifact
save/select + name→opens-notebook (Phase 2), side-by-side authoring layout
(Phase 3), auth, per-tab sessions (JupyterHub), Bar Replay, deep historical data.

---

## 3. Data sources

| Need | Source | Status |
|------|--------|--------|
| History / quotes / indices | **yfinance** | ✅ now |
| Live ticks | **Alpaca** (IEX free) → Redis | ✅ now |
| **Minute data over months** + custom date range | **Alpaca historical bars** (free IEX ~2.5% vol; or paid SIP ~100%) | ❌ planned |

**Why:** yfinance caps 1-minute data to ~7 days, so "1m on a 1M range" is greyed
out. Alpaca historical (same creds we already use) serves minute bars for years.
TradingView's data isn't usable (no public API; Cboe One is real-time-only, Cboe
DataShop is institutional files). **Decision pending:** free IEX vs. paid SIP.

---

## 4. Architecture for the IDE

**Split authoring from execution** (do NOT run live computes in the notebook kernel):
- **Author** in JupyterLab → write `compute(ctx)` / `on_bar(ctx)` with the `tsp` SDK.
- **Publish** → save the function source + metadata to a **registry**.
- **Execute** → the **backend** dispatches a job to the **sandbox** container,
  which runs the published code and returns the series/signals; the chart renders it.

```
+ Add → name → JupyterLab (author, tsp SDK) → Publish → Registry
                                                            ↓
                              Chart  ←  Backend  ←  Sandbox (runs published code)
```

**Containers:** existing stack + `jupyterlab` (authoring) + `sandbox` (execution).
1 shared each for now (owner-only); multi-user later.

**Sandbox placement:** own container (never inside Jupyter). Same VM now (trusted,
owner-only); separate "exec" VM + gVisor/Firecracker + ephemeral-per-run when
untrusted/multi-user. Hardening: resource/time caps, no prod mounts, no egress,
dependency allowlist.

**Multi-user + per-tab sessions + auth ⇒ JupyterHub.** Single JupyterLab (deployed
now) is the owner-only prototype; JupyterHub spawns per-user/per-tab kernels and
**culls them on disconnect/tab-close** — exactly requirements 5 & 6.

---

## 5. The `tsp` SDK contract (Phase 1b — DONE)

Authoring API available in the kernel (and used by the sandbox at execution time):
- `ctx.open/high/low/close/volume` — exported OHLCV metrics (pandas Series)
- `ctx.param(name, default)` — declared inputs
- indicator helpers: `ctx.sma/ema/rsi/macd/bbands/vwap/stoch(...)` (same math as backend)
- `ctx.plot(name, series, kind="overlay"|"oscillator")` — indicator output
- (strategy) `ctx.buy/sell/position`, `ctx.metric(...)` — strategy output
- `tsp.run_indicator(compute, bars, params)` — what the sandbox calls
- `tsp.publish(name, compute, kind, meta)` — register the artifact (login-gated)

Lives in the **engine repo** (`tsp/` package), pip-installable into Jupyter.

---

## 6. Bar Replay (Phase 6)

Pick any window/length/speed → feed bars to the artifact incrementally:
- **Indicator:** the series extends bar-by-bar as the chart reveals candles.
- **Strategy:** `on_bar` fires per bar → trade markers + live metrics (P&L, drawdown).
This is visual backtesting. Needs the **deep historical data** (§3) for intraday.

---

## 7. Phased plan

| Phase | Delivers | Requirements | Depends on |
|-------|----------|--------------|------------|
| **1a** | Jupyter + sandbox containers, infra auto-deploy | — | ✅ **done** |
| **1b** | `tsp` SDK → publish → sandbox → backend `/custom` (owner-only) | core loop | ✅ **done** (verified on dev) |
| **#3** | UI wiring: *render* a published custom indicator on the chart | render | 🔜 **next** |
| **2** | Artifact store; name-on-`+` opens seeded notebook; save; select/re-open; real sidebar lists | 1, 2 | 1b |
| **3** | Side-by-side layout: notebook (left) / chart (right) | 4 | 2 |
| **4** | Auth (login); anonymous can preview, must log in to publish/save | 5 | 2 |
| **5** | JupyterHub: per-tab kernel+sandbox, culled on tab close; multi-user | 6 | 4 |
| **6** | Bar Replay engine (any period/length/speed) | 3 | 1b + §3 data |

**Build order rationale:** prove the loop (1b) → usable solo (2,3) → open safely
(4,5) → make powerful (6). Auth (4) precedes multi-user sessions (5). Replay (6)
wants the Alpaca historical data first.

---

## 8. Open decisions
1. Data: **free IEX** vs **paid SIP** (start free?).
2. Public Jupyter URL (`lab.zemingzhang.com`) vs **SSH-tunnel only** (currently tunnel-only).
3. Auth provider (OAuth e.g. GitHub/Google vs email).
4. When to move sandbox to a separate exec VM / hard isolation (gVisor/Firecracker).
5. Registry storage: filesystem (like the strategy store) vs a DB.
