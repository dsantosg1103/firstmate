#!/usr/bin/env bash
# Live driver: real lavish-axi + throwaway server/port/store, real fm scripts,
# stand-in osascript only (never touches the captain's Chrome).
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lavish-live.XXXXXX"); LAB=$(cd -P "$LAB" && pwd -P)
PORT=$(perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(Listen=>1,LocalAddr=>"127.0.0.1",LocalPort=>0) or exit 1;print $s->sockport')
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT="$PORT" LAVISH_AXI_NO_OPEN=1
unset LAVISH_AXI_HOST LAVISH_AXI_ALLOWED_HOSTS
mkdir -p "$LAB/bin"
cat > "$LAB/bin/osascript" <<'SH'
#!/usr/bin/env bash
printf 'tab %s\n' "${!#}" >> "$(dirname "$0")/../tabs.log"; printf '1\n'
SH
chmod +x "$LAB/bin/osascript"; : > "$LAB/tabs.log"
FAILS=0
cleanup(){ fm_test_reap_procevent_homes; lavish-axi stop --port "$PORT" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
ok(){ printf 'PASS  %s\n' "$1"; }
bad(){ printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
status_of(){ perl -MJSON::PP -e 'local $/; open F,"<",$ARGV[0] or do{print "absent";exit}; my $s=decode_json(<F>); print(($s->{sessions}{$ARGV[1]}||{})->{status}//"absent")' "$LAVISH_AXI_STATE_DIR/state.json" "$1"; }
mkhome(){ local h="$LAB/$1"; mkdir -p "$h/state" "$h/data" "$h/config"; fm_test_tasks_toml "$h/.tasks.toml"; printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$h/data/backlog.md"; fm_test_track_procevent_home "$h" "$LAB/claims"; echo "$h"; }
env_h(){ local h=$1; shift; PATH="$LAB/bin:$PATH" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" "$@"; }
lav(){ local h=$1; shift; env_h "$h" "$ROOT/bin/fm-procevent-lavish.sh" "$@"; }
page(){ mkdir -p "$(dirname "$2")"; printf '<!doctype html><body style="background:#fff"><h1>plan</h1>\n' > "$2"; local o; o=$(lavish-axi "$2" 2>&1); local u; u=$(printf '%s\n' "$o" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"'); k=${u##*/session/}; echo "${k%%\?*}"; }
meta(){ printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$2" "$1" "$2" > "$1/state/$2.meta"; }
hold(){ env_h "$1" "$ROOT/bin/fm-captain-hold.sh" hold "$2" --title "Call $2" --reason "decide $2" --repo sample --origin "$3" >/dev/null || bad "fixture hold $2"; }
tabs(){ grep -c "/session/$1" "$LAB/tabs.log" || true; }
echo "# lavish-axi $(lavish-axi --version) on throwaway port $PORT"

echo; echo "== S1 close-task ends a finished task's page (file present) and closes only its tab"
H=$(mkhome s1); meta "$H" crew-a
k=$(page "$H" "$H/data/crew-a/plan.html"); ko=$(page "$H" "$H/data/crew-b/plan.html")
lav "$H" arm "$H/data/crew-a/plan.html" --for crew-a >/dev/null
out=$(lav "$H" close-task crew-a --root "$H/data/crew-a" 2>&1); rc=$?; echo "$out | rc=$rc"
[ $rc = 0 ] && [ "$(status_of $k)" = ended ] && [ "$(status_of $ko)" = open ] && [ "$(tabs $k)" = 1 ] && [ "$(tabs $ko)" = 0 ] && [ ! -e "$H/state/procevent/lavish-$k.source" ] \
  && ok "S1 page ended in real Lavish store, listener retired, own tab only" || bad "S1 (status=$(status_of $k) other=$(status_of $ko) tabs=$(tabs $k))"
out2=$(lav "$H" close-task crew-a --root "$H/data/crew-a" 2>&1); echo "rerun: '${out2}'"
[ "$(status_of $k)" = ended ] && [ ! -e "$H/state/procevent/lavish-$k.source" ] && ! printf "%s" "$out2" | grep -qE "^(warning|conflict|kept|saved):" && ok "S1b rerun is safe: page stays ended, no listener, no error (only a repeat best-effort tab close)" || bad "S1b rerun"

echo; echo "== S2 open captain call keeps the page"
H=$(mkhome s2); k=$(page "$H" "$H/data/scout-h/plan.html")
env_h "$H" tasks-axi add scout-h "Held scout" --kind scout --file "$H/data/backlog.md" >/dev/null; hold "$H" scout-h-call scout-h
out=$(lav "$H" close-task scout-h --root "$H/data/scout-h" 2>&1); echo "$out"
case "$out" in *"kept: "*"/session/$k"*) [ "$(status_of $k)" = open ] && [ "$(tabs $k)" = 0 ] && ok "S2 kept: line, page still open" || bad S2;; *) bad "S2 no kept line";; esac

echo; echo "== S3 decision 4: open-call page inside a doomed copy is saved into data/<id> and reopened; ended page beside it is not resurrected"
H=$(mkhome s3); meta "$H" crew-s
env_h "$H" tasks-axi add crew-s "Crew q" --kind task --file "$H/data/backlog.md" >/dev/null; hold "$H" crew-s-call crew-s
k=$(page "$H" "$H/worktree-crew-s/.lavish/decision.html")
ke=$(page "$H" "$H/worktree-crew-s/.lavish/old.html"); lavish-axi end "$H/worktree-crew-s/.lavish/old.html" >/dev/null 2>&1
lav "$H" arm "$H/worktree-crew-s/.lavish/decision.html" --for crew-s >/dev/null
env_h "$H" "$ROOT/bin/fm-captain-hold.sh" bind "lavish-$k" >/dev/null || bad "fixture bind"
echo "ended page status before: $(status_of $ke)"
out=$(lav "$H" close-task crew-s --root "$H/worktree-crew-s" --root "$H/data/crew-s" --save-into "$H/data/crew-s" 2>&1); rc=$?; echo "$out | rc=$rc"
nk=$(perl -MCwd=realpath -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex(realpath($ARGV[0])),0,16)' "$H/data/crew-s/decision.html" 2>/dev/null)
[ $rc = 0 ] && [ -f "$H/data/crew-s/decision.html" ] && [ "$(status_of $nk)" = open ] && [ "$(status_of $k)" = ended ] && [ -e "$H/state/procevent/lavish-$nk.source" ] \
  && case "$out" in *saved:*"/session/$nk"*) true;; *) false;; esac && ok "S3 saved: new link $nk open in real Lavish, old $k ended, listener carried" || bad "S3 (new=$nk:$(status_of $nk) old=$(status_of $k))"
[ ! -e "$H/data/crew-s/old.html" ] && [ "$(status_of $ke)" = ended ] && ! printf "%s" "$out" | grep -E "^(saved|kept):" | grep -q "$ke" \
  && ok "S3b already-ended page neither copied, reopened, nor reported saved/kept" || bad "S3b ended page resurrected"

echo; echo "== S4 decision 3: answering the last open call closes the page; one of two does not"
H=$(mkhome s4); env_h "$H" tasks-axi add scout-a "Scout" --kind scout --file "$H/data/backlog.md" >/dev/null
hold "$H" scout-a-1 scout-a; hold "$H" scout-a-2 scout-a; k=$(page "$H" "$H/data/scout-a/plan.html"); echo "Go." > "$H/d.txt"
env_h "$H" "$ROOT/bin/fm-captain-hold.sh" answer scout-a-1 --decision-file "$H/d.txt" 2>&1 | tail -3
s_mid=$(status_of $k)
env_h "$H" "$ROOT/bin/fm-captain-hold.sh" answer scout-a-2 --decision-file "$H/d.txt" 2>&1 | tail -3
[ "$s_mid" = open ] && [ "$(status_of $k)" = ended ] && [ "$(tabs $k)" = 1 ] && ok "S4 open after 1st answer, ended+tab closed after last answer" || bad "S4 (mid=$s_mid end=$(status_of $k))"

echo; echo "== S5 answer --release leaves the resuming task's page open and listening"
H=$(mkhome s5); meta "$H" crew-r; env_h "$H" tasks-axi add crew-r "Running" --kind task --file "$H/data/backlog.md" >/dev/null
hold "$H" crew-r-call crew-r; k=$(page "$H" "$H/data/crew-r/plan.html"); lav "$H" arm "$H/data/crew-r/plan.html" --for crew-r >/dev/null; echo "Carry on." > "$H/d.txt"
env_h "$H" "$ROOT/bin/fm-captain-hold.sh" answer crew-r-call --decision-file "$H/d.txt" --release 2>&1 | tail -3
[ "$(status_of $k)" = open ] && [ -e "$H/state/procevent/lavish-$k.source" ] && [ "$(tabs $k)" = 0 ] && ok "S5 --release kept page open, listener armed" || bad "S5 status=$(status_of $k)"
echo "== S5b plain answer of a running task's last call still closes"
H=$(mkhome s5b); meta "$H" crew-n; env_h "$H" tasks-axi add crew-n "Running" --kind task --file "$H/data/backlog.md" >/dev/null
hold "$H" crew-n-call crew-n; k=$(page "$H" "$H/data/crew-n/plan.html"); lav "$H" arm "$H/data/crew-n/plan.html" --for crew-n >/dev/null; echo "Ok." > "$H/d.txt"
env_h "$H" "$ROOT/bin/fm-captain-hold.sh" answer crew-n-call --decision-file "$H/d.txt" 2>&1 | tail -3
[ "$(status_of $k)" = ended ] && ok "S5b running task page closed on plain answer" || bad "S5b status=$(status_of $k)"

echo; echo "== S6 close-sweep: finished-task page and gone-file page (Ponytail-like) end; bearings board and running task untouched"
H=$(mkhome s6); meta "$H" crew-g; meta "$H" crew-k; meta "$H" crew-live
kg=$(page "$H" "$H/data/crew-g/plan.html"); kk=$(page "$H" "$H/worktree-crew-k/.lavish/ponytail.html")
kb=$(page "$H" "$H/.lavish/bearings-board.html"); kl=$(page "$H" "$H/data/crew-live/plan.html")
lav "$H" arm "$H/data/crew-g/plan.html" --for crew-g >/dev/null; lav "$H" arm "$H/worktree-crew-k/.lavish/ponytail.html" --for crew-k >/dev/null
lav "$H" arm "$H/data/crew-live/plan.html" --for crew-live >/dev/null
rm -f "$H/state/crew-g.meta" "$H/state/crew-k.meta"; rm -rf "$H/worktree-crew-k"
out=$(lav "$H" close-sweep 2>&1); echo "$out"
[ "$(status_of $kg)" = ended ] && [ "$(status_of $kk)" = ended ] && [ "$(status_of $kb)" = open ] && [ "$(status_of $kl)" = open ] && [ "$(tabs $kk)" = 1 ] && [ "$(tabs $kb)" = 0 ] \
  && ok "S6 sweep ended finished + gone-file (via its own key) pages; bearings and running page stay open" || bad "S6 g=$(status_of $kg) k=$(status_of $kk) b=$(status_of $kb) live=$(status_of $kl)"
out=$(lav "$H" close-sweep 2>&1); [ -z "$out" ] && ok "S6b repeated sweep is silent" || bad "S6b: $out"

echo; echo "== S7 no lavish-axi on PATH: silent no-op"
H=$(mkhome s7); out=$(PATH="/usr/bin:/bin" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" "$ROOT/bin/fm-procevent-lavish.sh" close-task x --root "$H/data/x" 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "S7 silent no-op" || bad "S7 rc=$rc out=$out"

echo; echo "tabs.log:"; cat "$LAB/tabs.log"
echo "FAILURES=$FAILS"; exit $FAILS
