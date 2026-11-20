# Error log

Approaches that took more than 2 attempts to work. Check here before suggesting an approach for a similar task.

## Building static libpq (PostgreSQL 18) for macOS
**What didn't work:** (1) `"${arr[@]}"` on an empty array under `set -u` fails in macOS's bash 3.2 ("unbound variable"). (2) `make -C src/interfaces/libpq` / `make install` fails at `libpq-refs-stamp`: the check rejects the shared libpq because statically linked OpenSSL references `exit()`.
**What worked:** Expand with `${arr[@]+"${arr[@]}"}`. Build only `make -C src/interfaces/libpq all-lib`, then copy `libpq.a`, `src/common/libpgcommon_shlib.a`, `src/port/libpgport_shlib.a` and the headers by hand (no `make install`). Merge everything with `libtool -static`.
**Note for next time:** `libpq.a` does not include pgcommon/pgport, so static consumers must link them too. Cross-building x86_64 on arm64 works with `CC="clang -arch x86_64"` plus `--host/--build` triplets.
