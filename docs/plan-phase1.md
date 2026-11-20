# Elefantas: Phase 1 (MVP) implementation plan

## Context
The PRD describes Elefantas, a native macOS client for PostgreSQL and TimescaleDB written in Swift, with Sequel Ace-like UX and built from scratch. This plan covers **Phase 1 (MVP) only**: Connection, Object Explorer, and Content (P0). The goal is a working prototype that can be used daily and that gives a performance baseline for the phase gate. Later phases (Query, Structure, Import/Export, Timescale) build on the layers set up here.

Current state: `/Users/hafiznugraha/Projects/Swift/elefantas/` is empty (greenfield, no git yet). Toolchain: Xcode 27, Swift 6.4, macOS 26.6, Homebrew, Docker, and a local PG 18.1 (DBngin) available for manual testing.

Decisions already made (from the PRD and Q&A):
- **macOS 15** minimum, universal (arm64 and x86_64)
- **SSH tunnel** through the system `/usr/bin/ssh -L` process. The app is not sandboxed and is distributed with Developer ID and notarization, not the Mac App Store.
- **libpq and OpenSSL** built statically by a script into an XCFramework in `Vendor/`
- **XcodeGen** (`project.yml`) for the app target, with core logic in local SPM packages that can be tested via `swift test`

## Step 0: Project rules and logs (first thing done after approval)
- `elefantas/CLAUDE.md` with these **Rules**:
  1. Read `MEMORY.md` at the start of every session before doing anything. Never contradict a logged decision without flagging it first.
  2. Check `ERRORS.md` before suggesting an approach to a task similar to a logged one. If the task matches a logged failure, say so and go straight to what worked.
  3. After every significant decision (direction, format, content, approach, strategy), append an entry to `MEMORY.md`: `## [Date], [Decision]` / **What was decided:** / **Why:** / **What was rejected:**.
  4. When an approach takes more than 2 attempts to work, log it in `ERRORS.md`: `## [Task]` / **What didn't work:** / **What worked:** / **Note for next time:**.
  5. End every coding task with a short status: Files changed / What was modified (one line per file) / Files intentionally not touched / Follow-up needed.
  6. Never commit or push unless the user explicitly asks.
- `elefantas/MEMORY.md`, seeded with dated 2026-11-20 entries for the decisions made so far: build from scratch instead of forking, Swift with SwiftUI and AppKit, static libpq and OpenSSL via a build script, macOS 15 minimum and universal, system ssh tunnel with no sandbox and Developer ID distribution, XcodeGen plus SPM modules, MVP scope limited to Connection, Explorer and Content, LIMIT/OFFSET paging with a reltuples estimate, edits only on tables with a PK or unique key.
- `elefantas/ERRORS.md`: header only.
- Also save the global preferences (the status-report format, and never commit or push unless asked) to Claude's auto-memory as feedback memories.

## Repository layout
```
elefantas/
  project.yml                 # XcodeGen: app target Elefantas, deps on local packages
  Makefile                    # make vendor | project | test | itest | app
  scripts/build-libpq.sh      # builds OpenSSL 3 + libpq (static, universal) -> Vendor/CLibPQ.xcframework
  Vendor/                     # build output (gitignored except README/LICENSES)
  Packages/
    PGKit/                    # thin Swift wrapper over libpq; no catalog/SQL knowledge
      Sources/CLibPQ/         # module.modulemap + shim header, binaryTarget -> xcframework
      Sources/PGKit/
      Tests/PGKitTests/
    ElefantasCore/            # app logic + dialect layer (the ONLY place with PG/Timescale SQL)
      Sources/ElefantasCore/{Connection,Dialect,Content,Storage,SSH}/
      Tests/ElefantasCoreTests/
  App/                        # SwiftUI + AppKit UI (no SQL here)
    ElefantasApp.swift, Windows/, Sidebar/, Content/, Connection/, Resources/
  docker/compose.yml          # postgres:17, postgres:18, timescale/timescaledb-ha (for itests)
  LICENSE (MIT, proposed), THIRD_PARTY_NOTICES.md (PostgreSQL, OpenSSL Apache-2.0)
```
Layer rule: `App` depends on `ElefantasCore`, and `ElefantasCore` depends on `PGKit`. Only `ElefantasCore/Dialect` writes SQL.

## Step 1: Vendor libpq (`scripts/build-libpq.sh`)
- Download pinned tarballs of OpenSSL 3.x and PostgreSQL 18.x and verify their SHA256.
- For each arch, build OpenSSL with `no-shared`. Configure PostgreSQL with `--with-ssl=openssl --without-icu --without-readline --without-zlib`, then build only `src/interfaces/libpq` plus its `src/common` and `src/port` dependencies.
- Combine the arches with `lipo`, then run `xcodebuild -create-xcframework` with `libpq.a`, `libssl.a`, `libcrypto.a`, and the headers (`libpq-fe.h`, `pg_config_ext.h`, `postgres_ext.h`).
- Set `MACOSX_DEPLOYMENT_TARGET=15.0`. The output is committed as a build artifact or produced in CI. `make vendor` is idempotent.

## Step 2: PGKit (libpq wrapper)
Key types in `Packages/PGKit/Sources/PGKit/`:
- `PGConnection` (final class, `Sendable`): owns a `PGconn*` plus a **dedicated serial DispatchQueue** where all blocking libpq calls run, exposed through `async` methods via continuations. This is simpler and safer than non-blocking polling and keeps the main thread free.
  - `static func connect(_ params: ConnectParams) async throws -> PGConnection` uses `PQconnectdbParams` with keyword arrays for host, port, dbname, user, password, sslmode, sslrootcert, connect_timeout, application_name=Elefantas, and keepalives.
  - `execute(_ sql: String, params: [PGValue?]) async throws -> PGResult` uses `PQexecParams` in text format.
  - `stream(_ sql:, params:, chunkSize:) -> AsyncThrowingStream<PGRowBatch, Error>` uses `PQsendQueryParams` + `PQsetChunkedRowsMode` (libpq 17+; this is a client-side feature that works against any server version). Each batch is copied out of the `PGresult` immediately and cleared, so memory stays bounded.
  - `cancel()` uses `PQcancelCreate`/`PQcancelBlocking` from another thread, which is thread-safe.
  - `status`/`reset()`: detect `CONNECTION_BAD` and reconnect with `PQreset` on request.
  - `serverVersion`, `parameterStatus(_:)`, and `escapeIdentifier(_:)` (wraps `PQescapeIdentifier`).
- `PGResult`/`PGRowBatch`: column metadata (name, type OID, table OID, column number) and cell values stored compactly as `[UInt8]?` per cell, with a lazy `String` view. NULL is kept distinct from an empty string.
- `PGError`: SQLSTATE, message, detail, hint, and position, taken from `PQresultErrorField`.
- Tests: unit tests for the value/NULL handling. Integration tests (env `ELEFANTAS_ITEST=1`) cover connect, params, streaming 1M rows with bounded RSS, cancelling `pg_sleep`, and bad-password errors.

## Step 3: ElefantasCore
**Connection/**
- `ConnectionConfig` (Codable): id, name, color, host, port, database, user, sslMode (disable/prefer/require/verify-ca/verify-full), sslRootCert path, and an optional ssh block (host, port, user, auth: agent/key path/password, plus key passphrase). It contains no secrets.
- `ConnectionSession` (`@MainActor @Observable`): connects (starting the tunnel first if configured), holds the `PGConnection`, tracks state (connecting/connected/lost/error), and on loss offers to reconnect. Switching databases means a new `PGConnection`, because PG cannot switch DB in-session. The previous connection is closed.
- `testConnection(config)`: connect, then `SELECT version()`, then close. Returns server version and SSL status (`PQsslInUse`).

**SSH/** `SSHTunnel`
- Picks a free local port by binding to `127.0.0.1:0` and reading the port back, then launches `Process` `/usr/bin/ssh -N -L 127.0.0.1:<lport>:<dbhost>:<dbport> -p <port> user@host -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o BatchMode=<yes unless password>` with `-i key` if one is set.
- Password or passphrase auth: set `SSH_ASKPASS` to a small helper script bundled in the app and `SSH_ASKPASS_REQUIRE=force`. The helper reads the secret from an env var the app passes in, so it is never written to disk.
- Readiness: poll the local port until it accepts a connection or a timeout fires. stderr is captured for error messages, including host-key prompts. Unknown host keys are shown with an explicit "trust" action that runs `-o StrictHostKeyChecking=accept-new` once.
- Lifecycle: terminate on session close or app quit, and watch for unexpected exit so the connection is marked lost.

**Storage/**
- `FavoritesStore`: JSON at `~/Library/Application Support/Elefantas/favorites.json`, holding favorites and groups in a user-defined order.
- `KeychainStore`: `SecItem*` generic passwords, service `id.elefantas.app`, account `<configID>.db|ssh|sshkey`. Every secret goes through this.

**Dialect/** (`protocol Dialect`, `struct PostgresDialect`)
- `quoteIdent`, `qualified(schema, name)`
- Catalog queries, parameterized, using `pg_catalog` rather than `information_schema` for speed:
  - databases: `pg_database WHERE datallowconn AND NOT datistemplate`
  - schemas: `pg_namespace`, excluding `pg_toast`/`pg_temp_*` and hiding system schemas by default with a toggle
  - relations per schema: `pg_class` relkind in (r, p, v, m, f) with `reltuples` estimate
  - functions: `pg_proc` with prokind
  - columns for a relation: `pg_attribute` + `format_type` + `pg_attrdef` + not-null
  - primary key or unique-not-null key: `pg_index indisprimary` / `indisunique`
- Content SQL builders (pure functions, unit tested): `selectPage(rel, columns, filter, sort, limit, offset)`, `count(rel, filter)`, `update(rel, keyCols, keyVals, col, val) RETURNING *`, `insert(rel, values) RETURNING *`, `delete(rel, keyCols, keyVals[])`. All values go in as `$n` params, and identifiers are always quoted.
- `Filter` model in the style of Sequel Ace: column + operator (=, ≠, <, >, LIKE, ILIKE, IS NULL, IS NOT NULL, IN, BETWEEN) + value. Values are compiled to params. A raw-WHERE option is clearly labeled.

**Content/** `ContentController` (`@MainActor @Observable`)
- State: relation, columns, key columns, page (default 1000 rows), offset, sort, filter, rows for the current page only, an estimated or exact total, loading/error.
- Server-side pagination with `LIMIT/OFFSET`. The total starts from the `reltuples` estimate ("~1.2M rows"), with an exact `count(*)` on demand, which is cancellable. Rows are streamed in through `PGConnection.stream`, so the first batch renders fast.
- Editing: only allowed when the relation has a PK or unique-not-null key. Otherwise the table is read-only with a banner (no ctid fallback in the MVP). On commit: UPDATE … RETURNING, then replace the row. Errors are shown inline and the cell is reverted.
- Add row: a draft row stays at the end until it's committed (INSERT … RETURNING). Delete rows: a confirmation sheet with the count, run in one transaction.
- Every in-flight query can be cancelled, and changing page or filter cancels the previous fetch.

## Step 4: App UI (SwiftUI shell + AppKit grid)
- `ElefantasApp`: a `WindowGroup` where each window is one connection, like Sequel Ace. `Cmd+N` opens a new window and `Cmd+T` a new tab using native window tabbing.
- **Connection screen** (window with no session): `NavigationSplitView` with a favorites list on the left (drag reorder, color tags, groups, duplicate/delete) and a form on the right with Standard / SSH tabs plus SSL settings, and Test / Save / Connect buttons. Secrets go to Keychain on Save.
- **Main window** (connected):
  - Toolbar: database picker popup, then a segmented Structure / **Content** / Query control (Structure and Query visible but disabled with "Phase 2"), plus refresh and a connection status indicator.
  - Sidebar: source-list `List` grouped as Schema, then Tables / Views / Materialized views / Functions, with SF Symbols per kind and a filter field at the bottom (`Cmd+Opt+F`) for client-side fuzzy filtering. Schemas load lazily on expand.
  - Content: a filter bar on top, then the grid, then a footer with row range, estimated or exact total, page prev/next, Add/Delete buttons, and a page-size control.
- **Grid** `DataGridView: NSViewRepresentable` wraps `NSTableView` (view-based, cell reuse, columns built dynamically, fixed row height, `usesAutomaticRowHeights = false`). Header click sorts server-side. Double-click or Return starts inline editing, and NULL is shown as a dimmed italic `NULL`. Editing to NULL goes through the context menu "Set NULL". Copy supports rows as TSV and a cell value. The data source reads straight from the controller's page buffer, never through SwiftUI `ForEach`.
- Shortcuts follow Sequel Ace where they apply (`Cmd+R` refresh, `Cmd+Delete` delete row, `Cmd+Opt+A` add row, `Cmd+F` focus filter).
- Dark mode works out of the box with system colors. UI strings use `String(localized:)` with an English base. The Indonesian localization is Phase 4, but the catalog (`Localizable.xcstrings`) is set up now.

## Step 5: Tooling and tests
- `Makefile`:
  - `vendor` runs the script
  - `project` runs `xcodegen generate`
  - `test` runs `swift test` in both packages
  - `itest` runs `docker compose up -d`, then `ELEFANTAS_ITEST=1 swift test`
  - `app` runs `xcodebuild -scheme Elefantas build`
- `docker/compose.yml`: postgres 17 and 18, plus timescaledb-ha on PG17. A seed SQL file creates sample schemas, a 1M-row table, a table without a PK, a view, a materialized view, functions, and (on timescale) a hypertable for later phases.
- Unit tests: dialect SQL builders (quoting, params, filters), Codable for configs, and parsing of the SSH arg builder.
- Integration tests: catalog queries against each PG version, plus the content round trip (page, sort, filter, edit, insert, delete).
- `git init` with a `.gitignore` for build/, Vendor/ artifacts, and *.xcodeproj (since it's generated). **No commits or pushes** unless the user asks.

## Implementation order
1. Scaffold (git, layout, project.yml, Makefile, compose)
2. build-libpq.sh, then PGKit with its tests
3. Dialect and catalog, with tests
4. Storage/Keychain and the connection screen
5. SSHTunnel
6. Main window and sidebar
7. ContentController and the grid
8. Editing
9. Polish and metrics

Implementation work is delegated to executor agents per step. Each step ends green on `make test`.

## Verification
- `make vendor && make test && make itest` all pass, on both PG 17 and PG 18.
- `make project && make app` builds a universal app, and `lipo -info` on the binary shows arm64 x86_64. `otool -L` shows **no** libpq or libssl dylib dependency, which confirms static linking.
- Manual run:
  - connect to local DBngin PG 18 directly
  - connect through Docker PG with `sslmode=require`
  - connect through an SSH tunnel to a remote host (or localhost sshd)
  - browse the 1M-row table, sort, filter, edit a cell, add and delete a row
  - confirm the no-PK table is read-only
  - kill the server and check the "connection lost" message and reconnect
- Phase-gate baseline, recorded in `docs/baseline.md`:
  - cold start time
  - idle RSS with 3 connections
  - RSS while paging the 1M-row table, which should stay flat
  - smooth scrolling, checked with Instruments
  - comparison against Sequel Ace and DBeaver

## Out of scope for this plan
Query editor, Structure tab, Postgres type-specific editors, Import/Export, Timescale features, signing and notarization pipeline (only noted). The open PRD questions about name availability and the final license stay open. MIT is proposed as a placeholder.
