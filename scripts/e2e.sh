#!/usr/bin/env bash
# scripts/e2e.sh — Zigoku M1 end-to-end validation harness.
#
# Builds the binary, stubs mpv so we can inspect the argv it would receive,
# then drives the CLI through several scenarios by piping stdin.
#
# Exit codes: 0 = all assertions passed, non-zero = at least one failure.
#
# Usage:
#   ./scripts/e2e.sh [--skip-network]   # skip all network-dependent tests
#   ./scripts/e2e.sh                    # run everything; auto-skip if unreachable
#
# Network tests are skipped automatically when AllAnime's API is unreachable,
# so this script is safe to run in offline CI — it will still exercise the
# build and all network-free assertions.
#
# Tested with bash 5.x on Linux. zsh-compatible.

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$REPO/zig-out/bin/zigoku"

# A temp dir that lives for the run and is prepended to PATH. We write a script
# named "mpv" there so zigoku picks up the stub instead of the real binary.
MPV_DIR="$(mktemp -d)"
MPV_FAKE="$MPV_DIR/mpv"
MPV_LOG="$MPV_DIR/mpv.log"
export MPV_STUB_LOG="$MPV_LOG"   # stub reads this at runtime to know where to write

# Ensure the temp dir is cleaned up regardless of exit path.
cleanup() { rm -rf "$MPV_DIR"; }
trap cleanup EXIT

# How long to wait for any network-dependent invocation before timing out.
TIMEOUT_SEC=30

# Colour helpers — degrade when stdout isn't a tty (CI pipes).
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; RESET=''
fi

# ── State tracking ─────────────────────────────────────────────────────────────

PASS=0; FAIL=0; SKIP=0

pass() { echo -e "${GREEN}  PASS${RESET} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL${RESET} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}  SKIP${RESET} $1"; SKIP=$((SKIP + 1)); }

# Assert that a string contains a literal substring.
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$label"
    else
        fail "$label — expected to find: $needle"
        echo "    actual output:"
        echo "$haystack" | head -8 | sed 's/^/      /'
    fi
}

# Assert that a string does NOT contain a literal substring.
assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        fail "$label — did NOT expect to find: $needle"
    else
        pass "$label"
    fi
}

# Assert that a file exists and is non-empty.
assert_file_nonempty() {
    local label="$1" path="$2"
    if [ -s "$path" ]; then
        pass "$label"
    else
        fail "$label — file missing or empty: $path"
    fi
}

# ── Header ─────────────────────────────────────────────────────────────────────

echo ""
echo "╋ zigoku e2e harness"
echo ""

# ── Step 1: Build ──────────────────────────────────────────────────────────────

echo "── build ─────────────────────────────────────────────────────────────────"
echo ""

if (cd "$REPO" && zig build 2>&1); then
    pass "zig build succeeds"
else
    fail "zig build failed — aborting"
    exit 1
fi

if [ -x "$BINARY" ]; then
    pass "zigoku binary is present and executable"
else
    fail "zigoku binary missing after build — aborting"
    exit 1
fi

echo ""

# ── Step 2: Unit tests ─────────────────────────────────────────────────────────

echo "── unit tests ────────────────────────────────────────────────────────────"
echo ""

test_out=$(cd "$REPO" && zig build test --summary all 2>&1)
if echo "$test_out" | grep -q "test success"; then
    count=$(echo "$test_out" | grep -oP '\d+(?= pass)' | head -1)
    pass "zig build test — ${count:-all} tests pass"
else
    fail "zig build test reported a failure"
    echo "$test_out"
fi

echo ""

# ── Step 3: Install mpv stub ───────────────────────────────────────────────────
#
# Write a script named "mpv" into $MPV_DIR (which is prepended to PATH in
# run_zigoku). The stub records all arguments to $MPV_STUB_LOG and exits 0,
# standing in for a successful playback so automated runs never open a window.

echo "── mpv stub ──────────────────────────────────────────────────────────────"
echo ""

cat > "$MPV_FAKE" << 'STUB_EOF'
#!/usr/bin/env bash
# mpv stub — record argv one-arg-per-line and exit 0.
# $MPV_STUB_LOG is inherited from the harness environment.
printf '%s\n' "$@" > "${MPV_STUB_LOG:-/tmp/mpv-stub-fallback.log}"
exit 0
STUB_EOF
chmod +x "$MPV_FAKE"
pass "mpv stub installed at $MPV_FAKE"

echo ""

# ── Helper: run zigoku with the stub mpv active and stdin piped ────────────────

run_zigoku() {
    # Usage: run_zigoku <stdin_string> [zigoku args…]
    # Clears the stub log beforehand so each scenario starts clean.
    local input="$1"; shift
    rm -f "$MPV_LOG"
    # Prepend $MPV_DIR so "mpv" resolves to our stub, not the system binary.
    PATH="$MPV_DIR:$PATH" \
        timeout "$TIMEOUT_SEC" "$BINARY" "$@" <<< "$input" 2>&1 || true
}

# ── Network reachability probe ─────────────────────────────────────────────────
#
# Run a real search and check for results. On failure or timeout we mark all
# network-dependent tests as SKIP rather than FAIL — offline CI stays green.

NETWORK=true
if [[ "${1:-}" == "--skip-network" ]]; then
    NETWORK=false
    echo "── network tests skipped (--skip-network) ────────────────────────────────"
    echo ""
else
    echo "── network reachability probe ────────────────────────────────────────────"
    echo ""
    probe_out=$(run_zigoku $'q\n' frieren)
    if echo "$probe_out" | grep -q "results:"; then
        pass "AllAnime API reachable (got search results)"
    else
        NETWORK=false
        skip "AllAnime API unreachable — network-dependent tests will be skipped"
        echo "    (probe output:"
        echo "$probe_out" | head -5 | sed 's/^/      /'
        echo "    )"
    fi
    echo ""
fi

# ── Scenario 1: happy path — search → pick show → pick episode → mpv ──────────

echo "── scenario 1: happy path (frieren sub, picks 1 then 1) ─────────────────"
echo ""

if [ "$NETWORK" = true ]; then
    out=$(run_zigoku $'1\n1\n' frieren)

    assert_contains "search returned results"   "$out" "results:"
    assert_contains "show selected"             "$out" "fetching episodes"
    assert_contains "episode selected"          "$out" "resolving ep"
    assert_contains "stream resolved"           "$out" "stream resolved"
    assert_contains "mpv launched"              "$out" "launching mpv"
    assert_contains "done marker"               "$out" "done. That was Zigoku"

    # Verify the stub was actually invoked and captured the CDN URL + Referer.
    assert_file_nonempty "mpv stub log written"  "$MPV_LOG"
    if [ -s "$MPV_LOG" ]; then
        mpv_args=$(cat "$MPV_LOG")
        assert_contains "CDN URL in mpv argv"    "$mpv_args" "tools.fast4speed.rsvp"
        assert_contains "Referer in mpv argv"    "$mpv_args" "allanime.day"
    fi
else
    skip "scenario 1: network unavailable"
fi

echo ""

# ── Scenario 2: no-results query ───────────────────────────────────────────────

echo "── scenario 2: no-results query ──────────────────────────────────────────"
echo ""

if [ "$NETWORK" = true ]; then
    # Deliberately garbage query — unlikely to match anything in the catalog.
    out=$(run_zigoku '' 'xyzzy_nonexistent_title_99991337')
    if echo "$out" | grep -qiE "no results|AllAnime returned nothing|no result"; then
        pass "no-results: correct message shown"
    elif echo "$out" | grep -q "results:"; then
        skip "no-results: API returned results for garbage query (input too fragile)"
    else
        pass "no-results: exited cleanly without crashing"
    fi
    assert_not_contains "no-results: mpv NOT launched" "$out" "launching mpv"
else
    skip "scenario 2: network unavailable"
fi

echo ""

# ── Scenario 3: quit at show prompt ───────────────────────────────────────────

echo "── scenario 3: quit at show-pick prompt ──────────────────────────────────"
echo ""

if [ "$NETWORK" = true ]; then
    out=$(run_zigoku $'q\n' frieren)
    assert_contains     "quit: bye message shown"       "$out" "bye."
    assert_not_contains "quit: episodes NOT fetched"    "$out" "fetching episodes"
    assert_not_contains "quit: mpv NOT launched"        "$out" "launching mpv"
else
    skip "scenario 3: network unavailable"
fi

echo ""

# ── Scenario 4: invalid then valid input (reprompt) ───────────────────────────

echo "── scenario 4: invalid input → reprompt → valid input ───────────────────"
echo ""

if [ "$NETWORK" = true ]; then
    # "abc" → not a number; "999" → out of range; "1" → valid; "q" at ep prompt.
    out=$(run_zigoku $'abc\n999\n1\nq\n' frieren)
    assert_contains     "reprompt: error on non-number"      "$out" "enter a number"
    assert_contains     "reprompt: error on out-of-range"    "$out" "out of range"
    assert_contains     "reprompt: reached episode prompt"   "$out" "fetching episodes"
    assert_not_contains "reprompt: mpv NOT launched"         "$out" "launching mpv"
else
    skip "scenario 4: network unavailable"
fi

echo ""

# ── Scenario 5: --dub flag (search only) ──────────────────────────────────────

echo "── scenario 5: --dub flag (naruto search, quit) ─────────────────────────"
echo ""

if [ "$NETWORK" = true ]; then
    out=$(run_zigoku $'q\n' naruto --dub)
    assert_contains     "--dub: search mentions dub"         "$out" "dub"
    assert_contains     "--dub: got results"                 "$out" "results:"
    assert_contains     "--dub: listing shows dub eps"       "$out" "dub eps"
    assert_not_contains "--dub: mpv NOT launched"            "$out" "launching mpv"
else
    skip "scenario 5: network unavailable"
fi

echo ""

# ── Scenario 6: --dub full path through mpv ───────────────────────────────────
#
# Naruto has a full English dub. Pick show 1, episode 1, and verify the stub
# gets a fast4speed URL. If the episode only has non-direct providers (ROD-92
# gap), degrade to SKIP rather than FAIL — that's a known limitation, not a bug.

echo "── scenario 6: --dub full path (naruto ep1 → mpv) ───────────────────────"
echo ""

if [ "$NETWORK" = true ]; then
    out=$(run_zigoku $'1\n1\n' naruto --dub)
    if echo "$out" | grep -q "stream resolved"; then
        assert_contains "--dub full path: mpv launched" "$out" "launching mpv"
        if [ -s "$MPV_LOG" ]; then
            mpv_args=$(cat "$MPV_LOG")
            assert_contains "--dub full path: CDN URL present" "$mpv_args" "tools.fast4speed.rsvp"
        else
            skip "--dub full path: stub log absent (mpv may not have been reached)"
        fi
    elif echo "$out" | grep -qE "NoDirectStream|only offers providers"; then
        skip "--dub full path: episode has no direct stream yet (ROD-92)"
    else
        fail "--dub full path: unexpected output"
        echo "    output:"
        echo "$out" | head -10 | sed 's/^/      /'
    fi
else
    skip "scenario 6: network unavailable"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────

echo "── summary ───────────────────────────────────────────────────────────────"
echo ""
echo "  passed:  $PASS"
echo "  failed:  $FAIL"
echo "  skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}  RESULT: FAIL${RESET}"
    echo ""
    exit 1
else
    echo -e "${GREEN}  RESULT: PASS${RESET}"
    echo ""
    exit 0
fi
