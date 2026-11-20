# Elefantas

Native macOS client for PostgreSQL and TimescaleDB (Swift), with Sequel Ace-style UX. The PRD is in `docs/PRD.md` and the Phase 1 plan is in `docs/plan-phase1.md`.

## Rules
1. **Read `MEMORY.md` at the start of every session before doing anything.** Never contradict a logged decision without flagging it first.
2. **Check `ERRORS.md` before suggesting an approach** to a task similar to a logged one. If the task matches a logged failure, say so and go straight to what worked.
3. After every significant decision (direction, format, content, approach, strategy), append an entry to `MEMORY.md`:
   ```
   ## [Date], [Decision]
   **What was decided:** ...
   **Why:** ...
   **What was rejected:** ...
   ```
4. When an approach takes more than 2 attempts to work, log it in `ERRORS.md`:
   ```
   ## [Task type or description]
   **What didn't work:** ...
   **What worked:** ...
   **Note for next time:** ...
   ```
5. End every coding task with a short status (not a recap):
   - Files changed: list every file touched
   - What was modified: one line per file
   - Files intentionally not touched: if relevant
   - Follow-up needed: anything that needs the user's attention or a decision
6. **Never commit or push** unless the user explicitly asks.

## Architecture
- `Packages/PGKit`: thin libpq wrapper. It has no catalog or SQL knowledge.
- `Packages/ElefantasCore`: app logic. `Dialect/` is the **only** place that writes Postgres or Timescale SQL.
- `App/`: SwiftUI shell plus AppKit (`NSTableView` grid). No SQL here.
- Dependency direction: App → ElefantasCore → PGKit.

## Commands
`make vendor` (static libpq + OpenSSL) · `make project` (xcodegen) · `make test` · `make itest` (Docker) · `make app`
