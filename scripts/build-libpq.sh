#!/usr/bin/env bash
# Builds static, universal (arm64 + x86_64) libpq + OpenSSL and packages them as
# Packages/PGKit/Vendor/CLibPQ.xcframework (one combined static lib + headers + modulemap).
# Idempotent: skips work if the xcframework already matches the pinned versions.
set -euo pipefail

PG_VERSION="18.7"
PG_SHA256="441dfae4280cae3e0425e5f876f80559fb0731c140f1aae22b3e5a54d0411bfd"
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
MIN_MACOS="15.0"
ARCHS=(arm64 x86_64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/vendor"
OUT_DIR="$ROOT/Packages/PGKit/Vendor"
XCFW="$OUT_DIR/CLibPQ.xcframework"
STAMP="$OUT_DIR/.versions"
WANT_STAMP="pg=$PG_VERSION openssl=$OPENSSL_VERSION min=$MIN_MACOS archs=${ARCHS[*]}"

if [[ -d "$XCFW" && -f "$STAMP" && "$(cat "$STAMP")" == "$WANT_STAMP" && "${FORCE:-0}" != 1 ]]; then
  echo "CLibPQ.xcframework is up to date ($WANT_STAMP). Set FORCE=1 to rebuild."
  exit 0
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"
HOST_ARCH="$(uname -m)"
mkdir -p "$WORK/src"

fetch() { # url sha256 dest
  local url="$1" sum="$2" dest="$3"
  if [[ ! -f "$dest" ]]; then
    echo "==> Downloading $(basename "$dest")"
    curl -fL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  echo "$sum  $dest" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $dest" >&2; rm -f "$dest"; exit 1; }
}

PG_TAR="$WORK/src/postgresql-$PG_VERSION.tar.bz2"
OSSL_TAR="$WORK/src/openssl-$OPENSSL_VERSION.tar.gz"
fetch "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" "$PG_SHA256" "$PG_TAR"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256" "$OSSL_TAR"

build_openssl() { # arch
  local arch="$1" target
  local prefix="$WORK/$arch/openssl"
  [[ -f "$prefix/lib/libssl.a" ]] && return
  case "$arch" in
    arm64) target=darwin64-arm64-cc ;;
    x86_64) target=darwin64-x86_64-cc ;;
  esac
  echo "==> OpenSSL $OPENSSL_VERSION ($arch)"
  local src="$WORK/$arch/openssl-src"
  rm -rf "$src" && mkdir -p "$src"
  tar -xzf "$OSSL_TAR" -C "$src" --strip-components=1
  (
    cd "$src"
    ./Configure "$target" no-shared no-tests no-docs no-module no-engine \
      --prefix="$prefix" --openssldir=/private/etc/ssl --libdir=lib \
      -mmacosx-version-min="$MIN_MACOS" -isysroot "$SDK" >/dev/null
    make -j"$JOBS" build_libs >/dev/null
    make install_dev >/dev/null
  )
}

build_libpq() { # arch
  local arch="$1"
  local prefix="$WORK/$arch/libpq"
  local ossl="$WORK/$arch/openssl"
  [[ -f "$prefix/lib/libpq.a" ]] && return
  echo "==> libpq $PG_VERSION ($arch)"
  local src="$WORK/$arch/pg-src"
  rm -rf "$src" && mkdir -p "$src"
  tar -xjf "$PG_TAR" -C "$src" --strip-components=1
  local hostflags=()
  local build_triplet="${HOST_ARCH/arm64/aarch64}-apple-darwin"
  local host_triplet="${arch/arm64/aarch64}-apple-darwin"
  [[ "$arch" != "$HOST_ARCH" ]] && hostflags=(--host="$host_triplet" --build="$build_triplet")
  (
    cd "$src"
    CC="clang -arch $arch" \
    CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS -isysroot $SDK" \
    LDFLAGS="-mmacosx-version-min=$MIN_MACOS -isysroot $SDK" \
    ./configure ${hostflags[@]+"${hostflags[@]}"} --prefix="$prefix" \
      --with-ssl=openssl --with-includes="$ossl/include" --with-libraries="$ossl/lib" \
      --without-icu --without-readline --without-zlib --without-zstd --without-lz4 \
      --without-gssapi --without-libcurl >/dev/null
    # Only `all-lib`: the default target also runs libpq-refs-stamp, which rejects the
    # shared lib because statically linked OpenSSL references exit(). We ship only libpq.a.
    make -j"$JOBS" -C src/interfaces/libpq all-lib >/dev/null
    mkdir -p "$prefix/lib" "$prefix/include"
    cp src/interfaces/libpq/libpq.a "$prefix/lib/"
    # libpq.a does not contain these; static consumers must link them too.
    cp src/common/libpgcommon_shlib.a src/port/libpgport_shlib.a "$prefix/lib/"
    cp src/interfaces/libpq/libpq-fe.h src/interfaces/libpq/libpq-events.h src/include/postgres_ext.h "$prefix/include/"
    [[ -f src/include/pg_config_ext.h ]] && cp src/include/pg_config_ext.h "$prefix/include/"
    true
  )
}

for arch in "${ARCHS[@]}"; do
  build_openssl "$arch"
  build_libpq "$arch"
  # One combined static archive per arch.
  libtool -static -o "$WORK/$arch/libCLibPQ.a" \
    "$WORK/$arch/libpq/lib/libpq.a" \
    "$WORK/$arch/libpq/lib/libpgcommon_shlib.a" \
    "$WORK/$arch/libpq/lib/libpgport_shlib.a" \
    "$WORK/$arch/openssl/lib/libssl.a" \
    "$WORK/$arch/openssl/lib/libcrypto.a" 2>/dev/null
done

echo "==> Creating universal archive + xcframework"
UNI="$WORK/universal"
rm -rf "$UNI" && mkdir -p "$UNI/include"
lipo -create $(for a in "${ARCHS[@]}"; do echo "$WORK/$a/libCLibPQ.a"; done) -output "$UNI/libCLibPQ.a"

INC="$WORK/${ARCHS[0]}/libpq/include"
for h in libpq-fe.h libpq-events.h postgres_ext.h pg_config_ext.h; do
  [[ -f "$INC/$h" ]] && cp "$INC/$h" "$UNI/include/"
done
cat > "$UNI/include/CLibPQ.h" <<'EOF'
#include "libpq-fe.h"
#include "libpq-events.h"
EOF
cat > "$UNI/include/module.modulemap" <<'EOF'
module CLibPQ {
    umbrella header "CLibPQ.h"
    export *
}
EOF

rm -rf "$XCFW" && mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework -library "$UNI/libCLibPQ.a" -headers "$UNI/include" -output "$XCFW" >/dev/null

# License texts for redistribution.
mkdir -p "$OUT_DIR/LICENSES"
tar -xjf "$PG_TAR" -C "$OUT_DIR/LICENSES" --strip-components=1 "postgresql-$PG_VERSION/COPYRIGHT"
mv "$OUT_DIR/LICENSES/COPYRIGHT" "$OUT_DIR/LICENSES/PostgreSQL-COPYRIGHT.txt"
tar -xzf "$OSSL_TAR" -C "$OUT_DIR/LICENSES" --strip-components=1 "openssl-$OPENSSL_VERSION/LICENSE.txt"
mv "$OUT_DIR/LICENSES/LICENSE.txt" "$OUT_DIR/LICENSES/OpenSSL-LICENSE.txt"

echo "$WANT_STAMP" > "$STAMP"
lipo -info "$UNI/libCLibPQ.a"
echo "Done: $XCFW"
