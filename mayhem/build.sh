#!/usr/bin/env bash
#
# mayhem/build.sh — build the netlink workspace's two upstream cargo-fuzz targets
# (netlink-packet-audit/fuzz -> netlink-audit, netlink-packet-route/fuzz -> netlink-route)
# as sanitized libFuzzer binaries, plus the workspace's own test suite (normal flags)
# for mayhem/test.sh.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): this first (online) build populates the cargo
# registry + git-dep cache under $CARGO_HOME and writes Cargo.lock into the tree;
# the offline PATCH re-run resolves everything from that cache. Do NOT hard-code
# --offline here.
set -euo pipefail

# clang/rustc reject SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# SANITIZER off-switch (SPEC): the Dockerfile threads $SANITIZER_FLAGS (default asan+ubsan,
# halting). rustc ignores clang flags, so we DERIVE the rustc sanitizer flag from it: if
# $SANITIZER_FLAGS mentions "address" we add -Zsanitizer=address; an EMPTY value (built with
# --build-arg SANITIZER_FLAGS=) yields a natural, un-instrumented crash build.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all}"
RUST_SAN=""
CFZ_SANITIZER="none"   # cargo-fuzz's own -s flag; overridden below when ASan is requested
case "$SANITIZER_FLAGS" in
  *address*) RUST_SAN="-Zsanitizer=address"; CFZ_SANITIZER="address" ;;
esac

# DWARF < 4 contract (§6.2 item 10): thread RUST_DEBUG_FLAGS through RUSTFLAGS.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3}"

# OSS-Fuzz Rust libFuzzer+ASan flags. --cfg fuzzing matches libfuzzer-sys;
# force-frame-pointers aids ASan backtraces.
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers"

# libfuzzer-sys compiles a C++ runtime shim via the cc crate; clang defaults to DWARF-5,
# so pin the C/C++ objects to DWARF-3 too (the cc crate honors CFLAGS/CXXFLAGS).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The rustc nightly ships a PRECOMPILED ASan runtime (librustc-*_rt.asan.a) whose
# compiler-rt CUs carry DWARF-5 (clang default); those runtime CUs would land in the
# linked fuzz binary and (being emitted first) fail the DWARF < 4 gate. Triage does not
# need runtime debug symbols; strip them (the archive is writable, chowned to 2000).
for _asan in $(find /opt/toolchains/rust -name "librustc-*_rt.asan.a" 2>/dev/null); do
  echo "stripping DWARF-5 debug info from runtime archive: $_asan"
  objcopy --strip-debug "$_asan" "$_asan.tmp" && mv "$_asan.tmp" "$_asan"
done

TRIPLE="x86_64-unknown-linux-gnu"

# Upstream ships its own cargo-fuzz crates (workspace members), one binary each:
#   netlink-packet-audit/fuzz  -> bin netlink-audit
#   netlink-packet-route/fuzz  -> bin netlink-route
declare -A FUZZ_DIRS=(
  [netlink-audit]="netlink-packet-audit/fuzz"
  [netlink-route]="netlink-packet-route/fuzz"
)

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"

for t in netlink-audit netlink-route; do
  d="${FUZZ_DIRS[$t]}"
  echo "--- building fuzz target: $t (fuzz dir $d) ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$d" -s "$CFZ_SANITIZER" -O --debug-assertions "$t"
  # The fuzz crates are members of the ROOT workspace, so binaries land in the
  # workspace target dir, not <fuzz-dir>/target.
  bin="$SRC/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the workspace's OWN test suite with the project's NORMAL flags (no
# sanitizers), into a separate target dir so mayhem/test.sh only RUNS it.
# Default workspace members exclude the fuzz crates (upstream's default-members).
echo "=== building upstream test suite (normal flags) ==="
RUSTFLAGS="" CARGO_TARGET_DIR="$SRC/target-tests" cargo test --no-run

echo "build.sh complete"
