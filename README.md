# Elefantas

A native macOS client for **PostgreSQL** and **TimescaleDB**, written in Swift, with a workflow familiar to Sequel Ace users.

> Status: early Phase 1 (MVP: connections, object explorer, Content tab). Not ready for daily use yet.
> Elefantas is an independent project and is not affiliated with Sequel Ace or Sequel Pro.

## Features (Phase 1)
- Connections: host/port, SSL modes, SSH tunnel (system `ssh`, works with ssh-agent and `~/.ssh/config`), favorites, with passwords stored in the Keychain
- Object explorer: schemas, tables, views, materialized views, functions, and fuzzy filtering
- Content: server-side paging, sorting and filtering on large tables; edit cells, add and delete rows (on tables with a primary or unique key)

See [`docs/PRD.md`](docs/PRD.md) for the full product plan (Query, Structure, Import/Export, and TimescaleDB features come next) and [`docs/NEXT.md`](docs/NEXT.md) for the current task list.

## Requirements
- macOS 15 or later (Apple Silicon or Intel)
- Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Docker (only for integration tests)

## Build
```sh
make vendor    # builds static libpq + OpenSSL into Packages/PGKit/Vendor (first run takes a few minutes)
make project   # generates Elefantas.xcodeproj
open Elefantas.xcodeproj
```

## Test
```sh
make test      # unit tests
make itest     # integration tests against PostgreSQL 17, 18 and TimescaleDB in Docker
```

## Layout
- `Packages/PGKit`: thin Swift wrapper over libpq
- `Packages/ElefantasCore`: app logic. `Dialect/` is the only place that writes SQL
- `App/`: SwiftUI shell with an AppKit (`NSTableView`) data grid

## License
[MIT](LICENSE). Bundled libraries: libpq (PostgreSQL License) and OpenSSL (Apache 2.0); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
