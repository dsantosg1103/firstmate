#!/usr/bin/env bash
# tests/fm-procevent-lavish-close-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still lets bin/fm-procevent-lavish.sh close a page whose
# file is gone.
#
# Why this file exists: `lavish-axi end <file>` resolves the file's real path
# before it asks the server anything, so a page whose file was deleted with its
# task's copy cannot be ended that way. close-task and close-sweep then end it
# through Lavish's own per-page address, POST /api/<key>/end, the route the
# page's End button uses, and accept only {"status":"ended"}. That address is a
# vendor surface a release can change without notice, and the portable tests in
# tests/fm-procevent.test.sh can only confirm what their stand-in was written to
# answer, so this guard runs the real close path against a real, throwaway
# Lavish server and fails naming the installed version if it stops working.
#
# Everything runs in an isolated lab: its own LAVISH_AXI_STATE_DIR, its own
# server port, LAVISH_AXI_NO_OPEN so no browser tab opens, and a stand-in
# osascript so the tab step never reaches a real browser. The server is
# stopped again before the guard returns. Standard CI has no lavish-axi, so this
# reports a capability skip there; it spends no model tokens, so it runs by
# default wherever lavish-axi and curl are installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LAVISH_CLOSE_LIVE lavish-axi curl perl

note() { printf '# %s\n' "$1"; }

LAB=''
PORT=''
cleanup() {
  fm_test_reap_procevent_homes
  # Only the lab's own port is ever stopped, never the operator's server.
  [ -z "$PORT" ] || lavish-axi stop --port "$PORT" >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf "$LAB"
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lavish-close-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
HOME_DIR="$LAB/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/live-task" "$LAB/lavish-state" "$LAB/bin"
fm_test_track_procevent_home "$HOME_DIR" "$LAB/claims"

PORT=$(perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0) or exit 1;
  print $s->sockport, "\n";') || fail "cannot pick a free port for the throwaway Lavish server"
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT="$PORT" LAVISH_AXI_NO_OPEN=1
unset LAVISH_AXI_HOST LAVISH_AXI_LINK_HOST LAVISH_AXI_ALLOWED_HOSTS

cat > "$LAB/bin/osascript" <<'SH'
#!/usr/bin/env bash
printf 'tab %s\n' "${!#}" >> "$(dirname "$0")/../tabs.log"
SH
chmod +x "$LAB/bin/osascript"

PAGE="$HOME_DIR/data/live-task/plan.html"
printf '<!doctype html><title>close guard</title><h1>close guard</h1>\n' > "$PAGE"
open_out=$(lavish-axi "$PAGE" 2>&1) \
  || fail "lavish-axi ${VERSION:-version-unknown} could not open a scratch page: $open_out"
url=$(printf '%s\n' "$open_out" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
key=${url##*/session/}
key=${key%%\?*}
case "$key" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) fail "lavish-axi ${VERSION:-version-unknown} no longer prints a /session/<key> page address: $open_out" ;;
esac
rm -f "$PAGE"

rc=0
close_out=$(PATH="$LAB/bin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" \
  "$ROOT/bin/fm-procevent-lavish.sh" close-task live-task --root "$HOME_DIR/data/live-task" 2>&1) || rc=$?
[ "$rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown}: close-task exited $rc on a gone-file page: $close_out"
case "$close_out" in
  *"closed: $url"*) ;;
  *) fail "lavish-axi ${VERSION:-version-unknown}: a page whose file is gone is no longer ended through POST /api/$key/end - $close_out" ;;
esac
status=$(perl -MJSON::PP -e '
  local $/; open my $f, "<", $ARGV[0] or exit 1;
  my $s = decode_json(<$f>); print(($s->{sessions}{$ARGV[1]} || {})->{status} // "absent");
' "$LAVISH_AXI_STATE_DIR/state.json" "$key") || status=unreadable
[ "$status" = ended ] \
  || fail "lavish-axi ${VERSION:-version-unknown} still records the gone-file page as $status after POST /api/$key/end"
grep -Fxq "tab /session/$key" "$LAB/tabs.log" 2>/dev/null \
  || fail "close-task did not ask to close the gone-file page's own tab"
pass "lavish-axi ${VERSION:-version-unknown} ends a page whose file is gone through its own address"
