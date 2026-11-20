# Decision log

## 2026-11-20, Build from scratch instead of forking Sequel Ace
**What was decided:** Write Elefantas from scratch in Swift. Sequel Ace is used only as a reference for flow and look.
**Why:** Sequel Ace is about 108k lines of Obj-C plus 42k lines of Swift, with 76 files coupled to MySQL. Starting fresh keeps the app light and Postgres-first.
**What was rejected:** Forking Sequel Ace, because it inherits the MySQL coupling and legacy weight.

## 2026-11-20, UI stack: SwiftUI shell + AppKit for grid/editor
**What was decided:** SwiftUI for general screens. NSTableView for the data grid and NSTextView for the SQL editor.
**Why:** SwiftUI Table and List are not smooth enough for millions of rows. AppKit gives cell reuse and fine control.
**What was rejected:** Pure SwiftUI, for the performance risk. Webview UI, because it goes against the native-first principle.

## 2026-11-20, macOS 15 minimum, universal binary
**What was decided:** Deployment target macOS 15.0, built for arm64 and x86_64.
**Why:** Covers the current release plus about two older ones, and gets Observation, modern SwiftUI and Swift 6 concurrency.
**What was rejected:** macOS 14 (more workarounds), macOS 26-only (too narrow).

## 2026-11-20, SSH tunnel via system /usr/bin/ssh
**What was decided:** Spawn `/usr/bin/ssh -N -L` as a Process, with SSH_ASKPASS for password or passphrase auth. The app is not sandboxed and is distributed with Developer ID and notarization.
**Why:** Zero dependencies, and it respects ~/.ssh/config, ssh-agent and keys. This is the same approach Sequel Ace uses.
**What was rejected:** libssh2 or SwiftNIO SSH (more dependencies, OpenSSL coupling, more code). Deferring SSH (it's a core use case).

## 2026-11-20, libpq + OpenSSL statically linked via build script
**What was decided:** `scripts/build-libpq.sh` builds OpenSSL 3 and libpq from source as static universal libraries, packaged as an XCFramework in Vendor/.
**Why:** Self-contained, with no dylib dependencies at runtime, which keeps distribution and notarization simple and matches the PRD.
**What was rejected:** Dynamically linking Homebrew libpq, because the app wouldn't be distributable.

## 2026-11-20, XcodeGen + local SPM packages
**What was decided:** `project.yml` generates the .xcodeproj, which is gitignored. Logic lives in the local SPM packages PGKit and ElefantasCore, testable with `swift test`.
**Why:** The project definition is diffable text, suits AI-assisted edits, and the core can be tested without Xcode.
**What was rejected:** A hand-maintained .xcodeproj, because it's opaque and conflict-prone.

## 2026-11-20, MVP scope = Connection, Object Explorer, Content
**What was decided:** Phase 1 delivers only connection management, the sidebar explorer, and Content browse and edit. Structure and Query are visible but disabled.
**Why:** The biggest risk is scope creep. A small MVP gets into daily use sooner.
**What was rejected:** Including Query or Structure in the MVP.

## 2026-11-20, Content paging: LIMIT/OFFSET + reltuples estimate
**What was decided:** Server-side LIMIT/OFFSET with a default page of 1000 rows. The total starts as the `pg_class.reltuples` estimate, with an exact count on demand that can be cancelled.
**Why:** Matches Sequel Ace's behaviour, and the estimate avoids slow count(*) queries on large tables.
**What was rejected:** Keyset pagination (complex with arbitrary sorts, maybe later). Always running an exact count (slow on big tables).

## 2026-11-20, Edit only tables with PK or unique-not-null key
**What was decided:** Cell edit, insert and delete are enabled only when a PK or unique-not-null key exists. Otherwise the table is read-only with a banner.
**Why:** Gives safe, unambiguous row identity.
**What was rejected:** A ctid fallback, because ctid is unstable after updates or VACUUM and risks editing the wrong row.

## 2026-11-20, libpq access model: serial DispatchQueue per connection
**What was decided:** Each PGConnection runs its blocking libpq calls on its own serial queue, bridged to async/await. Results stream through chunked rows mode, and cancel goes through PQcancelBlocking from another thread.
**Why:** Simpler and safer than non-blocking PQconnectPoll/socket polling, and keeps the main thread free.
**What was rejected:** Non-blocking libpq with a socket DispatchSource (more complex, little gain for a desktop client).

## 2026-11-20, Pinned vendor versions and xcframework location
**What was decided:** Pin PostgreSQL 18.7 (libpq) and OpenSSL 3.5.9 (LTS) with their SHA256. Output one combined static archive (libpq + pgcommon + pgport + ssl + crypto) as `Packages/PGKit/Vendor/CLibPQ.xcframework` with module `CLibPQ`.
**Why:** SwiftPM local binaryTargets must live inside the package directory. A single archive keeps link settings trivial, and libpq 18 gives chunked rows mode plus the new cancel API.
**What was rejected:** A root-level `Vendor/` as in the original plan (SwiftPM rejects paths outside the package). OpenSSL 3.6 (not LTS). Separate .a files per library (more link configuration).

## 2026-11-20, No Dialect protocol yet; single PostgresDialect struct
**What was decided:** `PostgresDialect` is a concrete struct of pure SQL-building functions. `Catalog` executes them.
**Why:** Only one dialect exists, so a protocol adds indirection for nothing. Timescale queries will be added as a separate extension or struct in Phase 3.
**What was rejected:** A `protocol Dialect` as sketched in the plan (YAGNI).

## 2026-11-20, Public GitHub repo
**What was decided:** The code is published at https://github.com/manusiakemos/elefantas (public), on branch `main`.
**Why:** The user's choice, in line with the PRD goal of being free and open source.
**What was rejected:** Private for now. Note that there is no LICENSE file yet (the PRD question is still open), so legally nobody can reuse the code until one is added.

## 2026-11-20, MVP UI simplifications vs. plan
**What was decided:** (1) Favorites are a flat, reorderable list with color tags, no groups. (2) Add Row uses a sheet with one field per column (empty = default, NULL checkbox) instead of an inline draft row. (3) Cmd+T opens a new connection window and merges it as a native tab (`addTabbedWindow`). (4) One PGConnection per window, shared by the sidebar and Content (its serial queue orders the work).
**Why:** Each is the smallest thing that delivers the PRD use case. An inline draft row in NSTableView needs much more state handling, and groups are not needed for the first daily use.
**What was rejected:** Favorite groups (later, if needed). An inline draft row (could come with Phase 2 type editors). A separate connection for the sidebar (more server sessions, little benefit yet).

## 2026-11-20, App depends only on ElefantasCore
**What was decided:** The App target links only ElefantasCore. PGKit types the UI needs are re-exported as typealiases (`SSLMode`) in `ElefantasCore/Connection/Reexports.swift`.
**Why:** Keeps the layer rule App → Core → PGKit enforceable.
**What was rejected:** `@_exported import PGKit` (leaks all of libpq's wrapper into the UI). Linking PGKit directly in the app.

## 2026-11-20, License: MIT
**What was decided:** Elefantas is licensed under MIT (Copyright (c) 2026 Hafiz Nugraha). Bundled third-party licenses are listed in `THIRD_PARTY_NOTICES.md`.
**Why:** The user's choice. It matches the MIT-style license of Sequel Ace, is permissive, and is compatible with libpq (PostgreSQL License) and OpenSSL (Apache 2.0).
**What was rejected:** Apache-2.0 or GPL (not needed; GPL would hinder reuse). Staying unlicensed (the repo is public, so nobody could legally reuse it).
