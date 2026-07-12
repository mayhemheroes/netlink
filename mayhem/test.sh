#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the netlink workspace's OWN upstream test suite (already
# compiled by mayhem/build.sh into $SRC/target-tests) and report a CTRF summary.
#
# This runs `cargo test --tests` over upstream's default workspace members (all 13
# netlink crates; the fuzz crates are excluded by upstream's own default-members).
# Doc-tests are skipped (--tests) so this script never compiles — build.sh already
# built every unit/integration test binary with the same (normal) flags.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

LOG=/tmp/cargo-test.log
# Three rtnetlink tests and one mptcp-pm test need root + CAP_NET_ADMIN / MPTCP sysctl (upstream's own CI runs that crate
# under `sudo -E`; see .github/workflows/main.yml). The commit image runs unprivileged,
# so those exact tests are skipped here and counted as skipped in the CTRF summary.
PRIV_SKIPS=(
  --skip traffic_control::add_qdisc::test::test_new_qdisc
  --skip traffic_control::add_filter::test::test_new_filter
  --skip link::test::create_get_delete_wg
  --skip test_mptcp_empty_addresses_and_limits
)
# Same env as build.sh's test build (RUSTFLAGS="" + target-tests) so nothing recompiles.
RUSTFLAGS="" CARGO_TARGET_DIR="$SRC/target-tests" cargo test --tests --no-fail-fast -- "${PRIV_SKIPS[@]}" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Sum every per-binary "test result: ok. X passed; Y failed; Z ignored; ..." line.
read -r P F S N <<<"$(awk '
  /^test result:/ {
    for (i=1;i<=NF;i++) {
      if ($(i+1) ~ /^passed/)  p += $i
      if ($(i+1) ~ /^failed/)  f += $i
      if ($(i+1) ~ /^ignored/) s += $i
    }
    n++
  }
  END { printf "%d %d %d %d", p+0, f+0, s+0, n+0 }' "$LOG")"

echo "parsed: $P passed, $F failed, $S ignored across $N test binaries (cargo rc=$rc)"

# No parseable results (or nothing ran) means the suite did NOT execute — fail loudly.
if [ "$N" -eq 0 ] || [ $(( P + F + S )) -eq 0 ]; then
  echo "ERROR: no test results parsed — upstream suite did not run" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi
[ "$rc" -ne 0 ] && [ "$F" -eq 0 ] && F=1   # cargo failed some other way — don't mask it

# ignored-by-harness + the 4 root-only tests skipped above
emit_ctrf "cargo-test" "$P" "$F" "$(( S + 4 ))"
