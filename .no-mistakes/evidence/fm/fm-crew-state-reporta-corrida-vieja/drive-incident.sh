#!/usr/bin/env bash
# Live driver for the nutrifam-cerrar-allow-authenticated incident (2026-09-07).
#
# Stands up a real git worktree, a real firstmate state home, and a fake
# `no-mistakes` CLI on PATH that answers exactly as the real one did during the
# incident, then drives the REAL bin/fm-crew-state.sh and the REAL
# bin/fm-inactive-reconcile.sh (the watcher path that emitted the false wake).
#
# usage: drive-incident.sh <repo-root> <scratch-dir>
set -u
ROOT=$1
SCRATCH=$2
BRANCH=fm/nutrifam-cerrar-allow-authenticated
ID=nutrifamcerrar

rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fm@test.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fm@test.invalid

# --- the crew's task copy -----------------------------------------------------
WT="$SCRATCH/Nutrifam"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" commit -q --allow-empty -m 'baseline'
git -C "$WT" checkout -q -b "$BRANCH"
git -C "$WT" commit -q --allow-empty -m 'cerrar allow-authenticated'
SUBMITTED=$(git -C "$WT" rev-parse HEAD)

# The live run's head: the pipeline replayed the branch onto an advanced
# upstream, so its head resolves here (the pipeline pushed it) but neither
# commit descends from the other.
git -C "$WT" checkout -q --detach "$(git -C "$WT" rev-list --max-parents=0 HEAD)"
git -C "$WT" commit -q --allow-empty -m 'upstream advanced'
git -C "$WT" commit -q --allow-empty -m 'replayed onto the advanced upstream'
REBASED=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q "$BRANCH"

git -C "$WT" merge-base --is-ancestor "$SUBMITTED" "$REBASED" && { echo "FIXTURE BROKEN: rebased descends"; exit 1; }
git -C "$WT" merge-base --is-ancestor "$REBASED" "$SUBMITTED" && { echo "FIXTURE BROKEN: submitted descends"; exit 1; }
echo "worktree HEAD (submitted, where the DEAD run died): $SUBMITTED"
echo "live run head  (rebased onto advanced upstream):    $REBASED"
echo "neither commit is an ancestor of the other: confirmed"
echo

# --- the fake no-mistakes CLI, answering as it did on 2026-09-07 --------------
FB="$SCRATCH/fakebin"; mkdir -p "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift
    case "${1:-}" in
      status) shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
  daemon) printf 'daemon running (pid 4242)\n'; exit 0 ;;
esac
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"

# `axi status` answers with the PREVIOUS run: it died at this worktree's exact
# commit when review hit the quota limit.
export FM_FAKE_AXI_STATUS="run:
  id: \"01M1Y8WFNKZVWKTT544KRS4GXQ\"
  branch: $BRANCH
  status: completed
  head: \"$SUBMITTED\"
  pr: \"\"
  findings: none
outcome: failed"
export FM_FAKE_AXI_STATUS_RUN="" FM_FAKE_CI_LOGS=""

SHORT_SUB=$(git -C "$WT" rev-parse --short=7 "$SUBMITTED")
SHORT_REB=$(git -C "$WT" rev-parse --short=7 "$REBASED")
# The runs ledger: the live run newest, the dead one immediately older.
LEDGER_WITH_LIVE="  running    $BRANCH $SHORT_REB  2026-09-07 14:14
  failed     $BRANCH $SHORT_SUB  2026-09-07 09:48"
# Control ledger: the same dead run with NO live successor.
LEDGER_DEAD_ONLY="  failed     $BRANCH $SHORT_SUB  2026-09-07 09:48"

# --- the firstmate home the watcher scans ------------------------------------
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR"/{state,data,config,projects} "$SCRATCH/root"
"$ROOT/bin/fm-meta-write.sh" 2>/dev/null || true
cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
worktree=$WT
project=Nutrifam
harness=claude
kind=ship
mode=no-mistakes
yolo=off
spawn_gen=s$$.1
EOF
printf 'working: cerrar allow-authenticated\n' > "$HOME_DIR/state/$ID.status"
: > "$HOME_DIR/state/$ID.turn-ended"
OLD=$(( $(date +%s) - 600 ))
STAMP=$(date -r "$OLD" +%Y%m%d%H%M.%S)
touch -t "$STAMP" "$HOME_DIR/state/$ID.meta" "$HOME_DIR/state/$ID.status" "$HOME_DIR/state/$ID.turn-ended"

crew_state() { # <bin-dir>
  PATH="$FB:$PATH" FM_STATE_OVERRIDE="$HOME_DIR/state" "$1/fm-crew-state.sh" "$ID"
}
reconcile() {
  rm -f "$HOME_DIR/state/.inactive-outcome-reconcile"*
  PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$SCRATCH/root" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_INACTIVE_RECONCILE_SECS=60 \
    "$ROOT/bin/fm-inactive-reconcile.sh" scan
}
wakes() {
  grep -o 'inactive-outcome[^ ]*' "$HOME_DIR/state/.wake-queue" 2>/dev/null || true
  grep -rho 'state=[a-z]*' "$HOME_DIR/state/terminal-outcomes" 2>/dev/null || true
}
clear_wakes() { rm -rf "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/terminal-outcomes"; }

# --- a pre-fix copy of the product, to prove the incident reproduces ---------
PRE="$SCRATCH/prefix-bin"
cp -R "$ROOT/bin" "$PRE"
git -C "$ROOT" show "${BASE_COMMIT:?}:bin/fm-nm-run-lib.sh" > "$PRE/fm-nm-run-lib.sh"
git -C "$ROOT" show "${BASE_COMMIT}:bin/fm-crew-state.sh" > "$PRE/fm-crew-state.sh"
chmod +x "$PRE/fm-crew-state.sh"

echo "=== S1: the incident shape, PRE-FIX product (base $BASE_COMMIT) ==="
export FM_FAKE_RUNS_LIST="$LEDGER_WITH_LIVE"
crew_state "$PRE"
echo
echo "=== S1: the incident shape, FIXED product (HEAD) ==="
crew_state "$ROOT/bin"
echo
echo "=== S2: the watcher (bin/fm-inactive-reconcile.sh scan) over the same shape ==="
clear_wakes
reconcile; echo "scan exit: $?"
echo "wake/outcome records emitted: [$(wakes | tr '\n' ' ')]"
echo
echo "=== S3 control: the SAME dead run with no live successor still reports and wakes ==="
export FM_FAKE_RUNS_LIST="$LEDGER_DEAD_ONLY"
crew_state "$ROOT/bin"
clear_wakes
reconcile; echo "scan exit: $?"
echo "wake/outcome records emitted: [$(wakes | tr '\n' ' ')]"
