# design-reference/

**Read-only.** This is the frozen prototype from Claude Design and the single source
of truth for Phase 8 frontend implementation.

Expected files (commit before Phase 8 begins):

- `Dynasty Projection Model.html` — entry point
- `app.jsx` — root component, tabs, state shape
- `left-panel.jsx` — filters, scoring config, data sources
- `center.jsx` — ranking board + backtest view
- `right-panel.jsx` — weight sliders + player deep-dive
- `components.jsx` — `PosPill`, `MiniBar`, `ScoreCell`, `Delta`, `fmt` helpers
- `data.js` — sample `ROOKIES`, `HISTORICAL`, `CORRELATIONS`
- `styles.css` — full quant-terminal stylesheet (`--bg-0` … `--accent-bg`)

## Phase 8 rules

1. **Read these in full before writing a single component.**
2. Match the visual output exactly — same CSS variables, fonts, density, hover/selected
   states, status bar.
3. Port `styles.css` to `web/src/styles/globals.css` verbatim as a baseline.
   Tailwind for layout primitives only — keep CSS variables.
4. Translate `window.X` globals + Babel-in-browser → ES modules + TypeScript strict.

## Deliberate deviations

Any deviation from the prototype must be documented in `web/DESIGN_NOTES.md` with rationale.

---

**Status:** placeholder. The prototype files have not yet been committed to this repo.
Until they are, Phase 8 is blocked.
