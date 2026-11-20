# Next work

Status as of 2026-11-20: the Phase 1 MVP (Connection, Object Explorer, Content) is implemented. Core tests pass on PG 17, PG 18 and TimescaleDB, and the app was smoke-tested against Docker PG 18. The items below are needed to pass the **Phase 1 gate**: the MVP is used for real work on your own servers without switching back to another client.

## Phase 1: finish and verify
### Manual testing (not yet tested from the UI)
- [ ] SSH tunnel to a real server: ssh-agent, key file + passphrase, password, the "Trust unknown host" flow, and the error for a changed host key
- [ ] SSL: `require` and `verify-full` with a root certificate (needs a Docker PG with SSL enabled)
- [ ] Editing in the grid: double-click / Return, Esc to cancel, Set NULL, the Add Row sheet, delete confirmation, and errors (constraint violation)
- [ ] Connection lost: stop the server, check the banner, then Reconnect. Repeat with the SSH tunnel dropped
- [ ] Switch databases from the toolbar, and Cmd+T (new tab) / Cmd+N (new window)
- [ ] Favorites: save, reorder, duplicate, delete (and confirm the Keychain entry is removed)

### Quality and performance
- [ ] Investigate idle memory (about 121 MB RSS at launch, see `docs/baseline.md`)
- [ ] Complete the baseline: cold start time, 3 open connections, scroll smoothness (Instruments), comparison with Sequel Ace and DBeaver
- [ ] CI with GitHub Actions: `make test`, plus `make itest` using Postgres/Timescale service containers

### Release and legal
- [x] LICENSE: MIT, plus `THIRD_PARTY_NOTICES.md` (libpq, OpenSSL)
- [ ] Check name availability for "Elefantas" (GitHub, domain, trademark)
- [ ] App icon (original, not taken from Sequel Ace)
- [ ] Developer ID signing and notarization (ad-hoc builds trigger Keychain prompts after every rebuild)

### Known MVP limitations (revisit if they get in the way)
- Child partitions are hidden in the sidebar (only the parent is shown)
- Updatable views are always read-only
- Long or multi-line values are edited in a single-line field, and the Add Row sheet is used instead of an inline draft row
- Favorites have no groups
- Stream backpressure: fine for paging, but must be added before Export (Phase 3)

## Phase 2 (after the Phase 1 gate)
- [ ] Query tab: SQL editor (NSTextView + syntax highlighting), streamed results, cancel, history, favorite queries
- [ ] Structure tab: columns, indexes, constraints, foreign keys, triggers, DDL view, and changing the structure
- [ ] Cell editors per Postgres type: array, JSONB, enum, range, UUID, timestamptz
