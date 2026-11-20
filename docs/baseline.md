# Phase 1 baseline measurements

First rough numbers from the prototype. They are not yet compared against Sequel Ace or DBeaver (see the PRD metrics).

| Date | Build | Scenario | Result |
|---|---|---|---|
| 2026-11-20 | Release, universal, 16 MB .app | Idle on the connection screen, ~3 s after launch | RSS 121 MB |
| 2026-11-20 | Release | Connected to local Docker PG 18.7, `app.events` (1M rows) open, 1000-row page | RSS 175 MB |
| 2026-11-20 | Release | After paging forward 20× (21,000 rows fetched in total) | RSS 176 MB (flat: only the current page is held) |

Machine: Apple Silicon, macOS 26.6. Server: local Docker (no network latency).

Still to measure: cold start time, idle RSS with 3 connections, scroll smoothness (Instruments), remote server over SSH, and the same scenarios in Sequel Ace and DBeaver.
