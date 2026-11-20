# Error log

Approaches that took more than 2 attempts to work. Check here before suggesting an approach for a similar task.

## Building static libpq (PostgreSQL 18) for macOS
**What didn't work:** (1) `"${arr[@]}"` on an empty array under `set -u` fails in macOS's bash 3.2 ("unbound variable"). (2) `make -C src/interfaces/libpq` / `make install` fails at `libpq-refs-stamp`: the check rejects the shared libpq because statically linked OpenSSL references `exit()`.
**What worked:** Expand with `${arr[@]+"${arr[@]}"}`. Build only `make -C src/interfaces/libpq all-lib`, then copy `libpq.a`, `src/common/libpgcommon_shlib.a`, `src/port/libpgport_shlib.a` and the headers by hand (no `make install`). Merge everything with `libtool -static`.
**Note for next time:** `libpq.a` does not include pgcommon/pgport, so static consumers must link them too. Cross-building x86_64 on arm64 works with `CC="clang -arch x86_64"` plus `--host/--build` triplets.

## Reordering arrays in a non-SwiftUI package
**What didn't work:** `Array.move(fromOffsets:toOffset:)` and then `remove(atOffsets:)` in ElefantasCore. Both are SwiftUI extensions, so they don't compile without `import SwiftUI`.
**What worked:** A manual version: collect the moving items, filter them out, then insert at `destination - source.count(in: 0..<destination)`.
**Note for next time:** Don't use SwiftUI collection helpers in ElefantasCore/PGKit. Core must stay UI-free.

## Driving the Elefantas UI with AppleScript (smoke tests)
**What didn't work:** `every text field of entire contents of w` and `whose description is ...` filters (error -1700). Clicking buttons by title (SwiftUI buttons have no AX title). `screencapture` from the terminal triggers a macOS screen-recording privacy prompt for the terminal app.
**What worked:** Dump `entire contents of window 1`, split on commas, grep for the element type, then address elements by index path (e.g. `button 3 of group 2 of splitter group 1 of group 1 of window 1` = Connect). Fill fields with `set focused ... to true` + `keystroke`. Select sidebar rows with `set selected of row N of outline 1 ... to true`. Verify by reading `value of every static text` and `count of rows of table 1`, with no screenshots needed.
**Note for next time:** Accessibility paths change when the layout changes, so dump the tree first. Prefer AX reads over screenshots.
