#!/usr/bin/env bash
# Build + run the dev.cajeta.xref unit tests.
#
# The suite lives under src/test/cajeta and is driven by cajeta-unit's
# reflective @Test discovery (dev.cajeta.unit.Runner). It compiles ONLY the
# test sources into an executable, with the xref library and cajeta-unit
# supplied as .cja classpath dependencies.
#
# Override paths via env:
#   CAJETA    — compiler binary (default: cajeta on PATH)
#   UNIT_CJA  — an explicit dev.cajeta.unit archive, used verbatim
#   UNIT_REPO — a cajeta-unit CHECKOUT to build the archive from (opt-in)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-cajeta}"

# Scratch stays inside the repo (gitignored). A shared /tmp has killed a
# session here before, and the fixtures the suite writes have to land
# somewhere the developer can still look at afterwards.
out="$here/tmp/testbuild"
rm -rf "$out"
mkdir -p "$out" "$here/tmp"

OLLA_HOME="${OLLA_HOME:-$HOME/.olla}"
OLLA_URL="${OLLA_URL:-https://olla.cajeta.dev}"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# cajeta-unit resolution: $UNIT_CJA, then the local store, then the registry,
# both at the version cajeta.json pins. Building from a sibling CHECKOUT is
# opt-in via UNIT_REPO rather than the default the rest of the fleet uses.
# Two reasons, both met head-on while writing this: a checkout links whatever
# that tree happens to hold instead of the pin, so the gate stops being a
# statement about a published artifact; and a `cajeta build` fired into a
# checkout somebody else is mid-build in fails on their half-written cache
# ("unusable cached bitcode ... rebuild without --cache-manifest").
unit_cja="${UNIT_CJA:-}"
UNIT_VER="$(sed -n 's/.*"dev\.cajeta\.unit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$here/cajeta.json" | head -1)"
[[ -n "$UNIT_VER" ]] || { echo "no dev.cajeta.unit pin in cajeta.json" >&2; exit 1; }

if [[ -z "$unit_cja" ]]; then
    store_cja="$OLLA_HOME/dev.cajeta.unit/$UNIT_VER/dev.cajeta.unit-$UNIT_VER.cja"
    cache_cja="$here/build/.unit-cache/dev.cajeta.unit-$UNIT_VER.cja"
    if   [[ -f "$store_cja" ]]; then unit_cja="$store_cja"
    elif [[ -f "$cache_cja" ]]; then unit_cja="$cache_cja"
    elif meta="$(curl -fsS "$OLLA_URL/v2/resolve?name=dev.cajeta.unit&version=$UNIT_VER" 2>/dev/null)"; then
        echo ">> fetching dev.cajeta.unit $UNIT_VER from $OLLA_URL"
        sha="$(printf '%s' "$meta" | sed -n 's/.*"sha256":"sha256:\([0-9a-f]*\)".*/\1/p')"
        [[ -n "$sha" ]] || { echo "/v2/resolve gave no sha256 for $UNIT_VER" >&2; exit 1; }
        mkdir -p "$(dirname "$cache_cja")"
        curl -fsS -o "$cache_cja" "$OLLA_URL/v2/blob/$sha"
        got="$(sha256_of "$cache_cja")"
        [[ "$got" == "$sha" ]] || { rm -f "$cache_cja"
            echo "sha256 mismatch fetching dev.cajeta.unit $UNIT_VER" >&2; exit 1; }
        unit_cja="$cache_cja"
    fi
fi
if [[ -z "$unit_cja" && -n "${UNIT_REPO:-}" && -d "${UNIT_REPO}" ]]; then
    echo ">> building cajeta-unit from checkout ($UNIT_REPO)"
    ( cd "$UNIT_REPO" && "$CAJETA" build >/dev/null )
    unit_cja="$( cd "$UNIT_REPO" && "$CAJETA" artifact-path 2>/dev/null || true )"
fi
[[ -n "$unit_cja" && -f "$unit_cja" ]] || {
    echo "could not resolve dev.cajeta.unit $UNIT_VER — not in $OLLA_HOME, not on $OLLA_URL." >&2
    echo "Set UNIT_CJA to an archive, or UNIT_REPO to a cajeta-unit checkout." >&2
    exit 1; }
echo ">> cajeta-unit: $unit_cja"

echo ">> building the xref library .cja"
( cd "$here" && "$CAJETA" build >/dev/null )
lib_cja="$( cd "$here" && "$CAJETA" artifact-path 2>/dev/null || true )"
if [[ -z "$lib_cja" || ! -f "$lib_cja" ]]; then
    lib_cja="$(ls -t "$here"/build/archive/dev.cajeta.xref-*.cja 2>/dev/null | head -1)"
fi
[[ -f "$lib_cja" ]] || { echo "no dev.cajeta.xref archive after build" >&2; exit 1; }
echo ">> xref library: $lib_cja"

echo ">> building the test binary"
"$CAJETA" --emit=exe --profile=test \
    --classpath="$lib_cja,$unit_cja" \
    -o "$out/xreftests" \
    dev.cajeta.xref.selftest.TestMain.run "$here/src/test/cajeta" "$out" >/dev/null

# The index the compiler emits today for this library's own sources: the suite reads it back,
# so a change in the format fails here before it reaches a consumer.
mkdir -p "$here/tmp"
"$CAJETA" --lint "$here/src/main/cajeta" --emit-xref="$here/tmp/xref-self.json" >/dev/null
[[ -s "$here/tmp/xref-self.json" ]] || { echo "the compiler wrote no xref index" >&2; exit 1; }

# The suite writes its fixtures to tmp/ relative to the working directory.
cd "$here"
"$out/xreftests"
