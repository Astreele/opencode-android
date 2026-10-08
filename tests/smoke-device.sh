#!/usr/bin/env bash
# On-device acceptance smoke for an installed opencode2.
# RUNS ON: Termux on Android (NOT in CI, NOT on Linux) — the maintainer runs
# this on a real device before publishing a release and pastes the report
# block into the release notes.
#
# No provider auth is needed: every probe stays below the model-call line
# (server lifecycle, PTY spawn, session CRUD, TUI boot, watcher subscribe).
#
# Usage: bash tests/smoke-device.sh [--cmd NAME] [--keep]
#   --cmd   command to probe (default: opencode2)
#   --keep  leave the scratch project + raw captures for inspection
# Env: SMOKE_TUI_SECS (TUI probe window, default 25)
#
# Probes:
#   1. version ... wrapper resolves .bin, binary boots
#   2. service ... stop/start/status lifecycle of the background daemon
#   3. api ..... server answers server.info
#   4. pty ..... pty.create runs `echo` (daemon spawn on bionic), exits 0,
#                appears in pty.list, disappears after pty.remove
#   5. session . session.create/delete in the scratch project (no auth)
#   6. tui ..... renders frames under script(1) (embedded bionic renderer)
#   7. watcher . server log shows subscribe+started for the scratch project
#                (CLI path) and a live type=directory backend=inotify record
#                (patched parcel android->inotify path)
# Every captured output is also scanned for native-load failure signatures
# (__errno_location, libc.so.6, dlopen errors): the bug class this repo's
# patches exist to prevent must fail loudly here, not as a blank screen.
set -uo pipefail

CMD=opencode2
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cmd) [ $# -ge 2 ] || { echo "usage: $0 [--cmd NAME] [--keep]" >&2; exit 2; }; CMD="$2"; shift 2 ;;
        --cmd=*) CMD="${1#--cmd=}"; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) echo "usage: $0 [--cmd NAME] [--keep]"; exit 0 ;;
        *) echo "unknown option: $1" >&2; echo "usage: $0 [--cmd NAME] [--keep]" >&2; exit 2 ;;
    esac
done

command -v "$CMD" >/dev/null 2>&1 || { echo "FAILED: command not found: $CMD" >&2; exit 1; }
command -v script >/dev/null 2>&1 || { echo "FAILED: 'script' missing (pkg install util-linux)" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "FAILED: 'timeout' missing (pkg install coreutils)" >&2; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/opencode-smoke.XXXXXX")"
PROJ="$SCRATCH/proj"
CAP="$SCRATCH/captures"
mkdir -p "$PROJ" "$CAP"

cleanup() {
    # Best effort: remove test sessions/ptys even on failure, drop scratch.
    if [ -n "${PTY_ID:-}" ]; then
        "$CMD" api DELETE "/api/pty/$PTY_ID" >/dev/null 2>&1 || true
    fi
    if [ -n "${SES_ID:-}" ]; then
        "$CMD" session delete "$SES_ID" >/dev/null 2>&1 || true
    fi
    # The TUI probe may auto-create sessions in the scratch project; sweep
    # anything left behind (scoped to $PROJ only).
    for sid in $("$CMD" api GET "/api/session?directory=$PROJ" 2>/dev/null \
        | grep -o '"id":"ses_[^"]*"' | cut -d'"' -f4); do
        "$CMD" session delete "$sid" >/dev/null 2>&1 || true
    done
    if [ "${WAS_RUNNING:-0}" = 1 ]; then
        "$CMD" service start >/dev/null 2>&1 || true
    fi
    if [ "$KEEP" = 0 ]; then
        rm -rf "$SCRATCH"
    else
        echo "kept: $SCRATCH"
    fi
}
trap cleanup EXIT

PASS=0
FAIL=0
REPORT_LINES=""

# Native-load failure signatures: any match fails the probe being scanned.
NATIVE_SIG='__errno_location|libc\.so\.6|libm\.so\.6|dlopen failed|cannot load|Failed to load|MODULE_NOT_FOUND|ERR_DLOPEN|cannot open shared'

pass() {
    PASS=$((PASS + 1))
    REPORT_LINES="${REPORT_LINES}
- $1: PASS$2"
    echo "PASS: $1$2"
}

fail() {
    FAIL=$((FAIL + 1))
    REPORT_LINES="${REPORT_LINES}
- $1: FAIL ($2)"
    echo "FAIL: $1 ($2)"
}

# scan_native <probe> <file>: fail the probe if native-load signatures appear.
scan_native() {
    if grep -aEq "$NATIVE_SIG" "$2"; then
        fail "$1" "native-load signature in output: $(grep -aoE "$NATIVE_SIG" "$2" | head -1)"
        return 1
    fi
    return 0
}

echo "== smoke-device: probing '$CMD' (scratch: $SCRATCH)"

# ── 1. version ─────────────────────────────────────────────────────────
if "$CMD" --version >"$CAP/version.out" 2>&1 \
    && grep -q "opencode v" "$CAP/version.out"; then
    if scan_native "version" "$CAP/version.out"; then
        pass "version" " ($(cat "$CAP/version.out"))"
    fi
else
    fail "version" "unexpected output: $(head -c 120 "$CAP/version.out" 2>/dev/null)"
fi

# ── server log window: only lines written from here on count ──────────
LOG_FILE=""
if LOG_CANDIDATE="$("$CMD" debug paths 2>/dev/null | awk '$1 == "log" { $1 = ""; sub(/^ +/, ""); print; exit }')"; then
    if [ -n "$LOG_CANDIDATE" ] && [ -f "$LOG_CANDIDATE/opencode.log" ]; then
        LOG_FILE="$LOG_CANDIDATE/opencode.log"
    fi
fi
if [ -z "$LOG_FILE" ] && [ -f "$HOME/.local/share/opencode/log/opencode.log" ]; then
    LOG_FILE="$HOME/.local/share/opencode/log/opencode.log"
fi
if [ -n "$LOG_FILE" ]; then
    LOG_MARK="$(wc -c <"$LOG_FILE")"
else
    echo "NOTE: server log not found; watcher probe will SKIP"
    LOG_MARK=0
fi
log_window() {
    if [ -n "$LOG_FILE" ]; then
        tail -c +"$((LOG_MARK + 1))" "$LOG_FILE" 2>/dev/null || true
    fi
}

# ── 2. service lifecycle (save + restore maintainer state) ────────────
if "$CMD" service status >"$CAP/status.before" 2>&1 && grep -q "http" "$CAP/status.before"; then
    WAS_RUNNING=1
else
    WAS_RUNNING=0
fi
"$CMD" service stop >"$CAP/service.stop" 2>&1 || true
sleep 2
STOP_OK=0
"$CMD" service status >"$CAP/status.stopped" 2>&1 || true
if ! grep -q "http" "$CAP/status.stopped" 2>/dev/null; then
    STOP_OK=1
fi
"$CMD" service start >"$CAP/service.start" 2>&1
sleep 3
if "$CMD" service status >"$CAP/status.started" 2>&1 && grep -q "http" "$CAP/status.started"; then
    START_OK=1
else
    START_OK=0
fi
if [ "$STOP_OK" = 1 ] && [ "$START_OK" = 1 ] \
    && scan_native "service" "$CAP/service.start"; then
    pass "service" " (stop/start/status round-trip; was running: $WAS_RUNNING)"
else
    fail "service" "stop_ok=$STOP_OK start_ok=$START_OK (was running: $WAS_RUNNING)"
fi

# ── 3. server.info ────────────────────────────────────────────────────
if "$CMD" api GET /api/info >"$CAP/info.out" 2>&1 \
    && grep -q '"version"' "$CAP/info.out" \
    && scan_native "api/info" "$CAP/info.out"; then
    pass "api/info" " ($(grep -o '"version":"[^"]*"' "$CAP/info.out" | head -1))"
else
    fail "api/info" "server.info did not answer"
fi

# ── 4. pty lifecycle (daemon spawn on bionic) ─────────────────────────
PTY_ID=""
if "$CMD" api POST /api/pty \
    -d "{\"command\":\"echo\",\"args\":[\"smoke-pty-ok\"],\"cwd\":\"$PROJ\"}" \
    >"$CAP/pty.create" 2>&1; then
    PTY_ID="$(grep -o '"id":"pty_[^"]*"' "$CAP/pty.create" | head -1 | cut -d'"' -f4)"
fi
PTY_OK=0
if [ -n "$PTY_ID" ] && scan_native "pty" "$CAP/pty.create"; then
    for _ in $(seq 1 15); do
        if "$CMD" api GET "/api/pty/$PTY_ID" >"$CAP/pty.get" 2>/dev/null \
            && grep -q '"status":"exited"' "$CAP/pty.get"; then
            if grep -q '"exitCode":0' "$CAP/pty.get"; then PTY_OK=1; fi
            break
        fi
        sleep 2
    done
    if [ "$PTY_OK" = 1 ] && "$CMD" api GET /api/pty >"$CAP/pty.list" 2>/dev/null \
        && grep -q "$PTY_ID" "$CAP/pty.list" \
        && "$CMD" api DELETE "/api/pty/$PTY_ID" >/dev/null 2>&1 \
        && "$CMD" api GET /api/pty >"$CAP/pty.list2" 2>/dev/null \
        && ! grep -q "$PTY_ID" "$CAP/pty.list2"; then
        pass "pty" " (create/run/exit-0/list/remove $PTY_ID)"
        PTY_ID=""
    else
        fail "pty" "lifecycle incomplete for ${PTY_ID:-<none>}"
    fi
else
    fail "pty" "pty.create failed"
fi

# ── 5. session create/delete (no auth) ───────────────────────────────
SES_ID=""
if "$CMD" api POST /api/session \
    -d "{\"title\":\"smoke-device\",\"location\":{\"directory\":\"$PROJ\"}}" \
    >"$CAP/session.create" 2>&1; then
    SES_ID="$(grep -o '"id":"ses_[^"]*"' "$CAP/session.create" | head -1 | cut -d'"' -f4)"
fi
if [ -n "$SES_ID" ] && scan_native "session" "$CAP/session.create" \
    && "$CMD" session delete "$SES_ID" >"$CAP/session.delete" 2>&1; then
    pass "session" " (create/delete $SES_ID)"
    SES_ID=""
else
    fail "session" "session.create/delete failed"
fi

# ── 6. TUI renders frames under a pty ────────────────────────────────
# Window tunable for slow/flaky environments; the default suits releases.
TUI_SECS="${SMOKE_TUI_SECS:-25}"
if printf 'q' | TERM=xterm-256color timeout "$TUI_SECS" script -qec "$CMD $PROJ --print-logs" /dev/null \
    >"$CAP/tui.out" 2>&1; then
    : # 'q' quit cleanly before the timeout
fi
TUI_SIZE="$(wc -c <"$CAP/tui.out" | tr -d ' ')"
if [ "$TUI_SIZE" -ge 4096 ] \
    && grep -qaF "$(printf '\033[?1049h')" "$CAP/tui.out" \
    && scan_native "tui" "$CAP/tui.out"; then
    pass "tui" " (${TUI_SIZE} bytes of frames, alt-screen init seen)"
else
    fail "tui" "no TUI frames (captured ${TUI_SIZE} bytes)"
fi
sleep 2  # let the server flush watch lines to its log

# ── 7. watcher evidence in the server log ────────────────────────────
if [ -z "$LOG_FILE" ]; then
    REPORT_LINES="${REPORT_LINES}
- watcher: SKIP (server log not found)"
    echo "SKIP: watcher (server log not found)"
else
    WIN="$CAP/log.window"
    log_window >"$WIN"
    if grep -q "watcher subscribe.*$PROJ" "$WIN" \
        && grep -q "watcher started.*$PROJ.*backend=" "$WIN"; then
        pass "watcher" " (subscribe+started for scratch project)"
    else
        fail "watcher" "no subscribe/started lines for scratch project"
    fi
    if grep -q "type=directory backend=inotify" "$WIN"; then
        pass "watcher/inotify" " (live directory/inotify record)"
    else
        fail "watcher/inotify" "no type=directory backend=inotify record"
    fi
fi

# ── report block for the release notes ───────────────────────────────
VERSION="$(cat "$CAP/version.out" 2>/dev/null | head -1)"
ANDROID="$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
echo
echo "SMOKE REPORT (paste into release notes):"
echo '```'
echo "Device smoke — $VERSION ($(date -u +%Y-%m-%d))"
echo "Device: $(uname -m), Android $ANDROID, Termux"
echo "$REPORT_LINES" | sed '/^$/d'
echo '```'
echo
echo "smoke-device: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
