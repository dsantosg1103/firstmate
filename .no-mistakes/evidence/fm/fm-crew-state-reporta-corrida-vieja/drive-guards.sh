#!/usr/bin/env bash
# Adversarial driver: the boundaries the incident fix must NOT cross.
# Drives the REAL bin/fm-crew-state.sh over real git repos + a fake
# `no-mistakes` CLI, for the ledger shapes that try to abuse the new
# "unbindable live newest row reaches the anchor" rule.
# usage: drive-guards.sh <repo-root> <scratch-dir>
set -u
ROOT=$1; SCRATCH=$2
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fm@test.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fm@test.invalid

FB="$SCRATCH/fakebin"; mkdir -p "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi) shift; case "${1:-}" in
      status) shift; if [ "${1:-}" = --run ]; then printf '\n'; else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
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
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"

setup_case() { # <name> <branch> -> sets WT, HOME_DIR, ID
  NAME=$1; BR=$2; ID=$1
  WT="$SCRATCH/$NAME/wt"; HOME_DIR="$SCRATCH/$NAME/home"
  mkdir -p "$WT" "$HOME_DIR/state"
  git -C "$WT" init -q
  git -C "$WT" commit -q --allow-empty -m baseline
  git -C "$WT" checkout -q -b "$BR"
  cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
worktree=$WT
project=p
harness=claude
kind=ship
EOF
}
arm_busy() { # make the pane a definitive busy answer, so a non-binding run row
  # falls to an unambiguous pane verdict instead of "harness unavailable".
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$ID")
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$ID" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}
crew_state() { PATH="$FB:$PATH" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-crew-state.sh" "$ID"; }
prefix_crew_state() { PATH="$FB:$PATH" FM_STATE_OVERRIDE="$HOME_DIR/state" "$SCRATCH/prefix-bin/fm-crew-state.sh" "$ID"; }
short() { git -C "$WT" rev-parse --short=7 "$1"; }

PRE="$SCRATCH/prefix-bin"; cp -R "$ROOT/bin" "$PRE"
git -C "$ROOT" show "${BASE_COMMIT:?}:bin/fm-nm-run-lib.sh" > "$PRE/fm-nm-run-lib.sh"

# --- G1: live NEWEST row whose head is a STRICT ANCESTOR of the worktree HEAD,
# with a perfect exact-head terminal anchor immediately behind it. That run is
# superseded local history, not an unprovable pipeline continuation.
setup_case ancestorlive fm/g-ancestor
git -C "$WT" commit -q --allow-empty -m 'abandoned run launched here'
OLDER=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" commit -q --allow-empty -m 'local work advanced past it'
HEADC=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" merge-base --is-ancestor "$OLDER" "$HEADC" || { echo "FIXTURE BROKEN"; exit 1; }
export FM_FAKE_AXI_STATUS="run:
  id: \"01OTHER\"
  branch: fm/some-other-crew
  status: running
  head: \"aaaaaaa\"
  pr: \"\"
  findings: none"
export FM_FAKE_RUNS_LIST="  running    fm/other aaaaaaa  2026-09-07 15:00
  running    fm/g-ancestor $(short "$OLDER")  2026-09-07 14:14
  failed     fm/g-ancestor $(short "$HEADC")  2026-09-07 09:48"
arm_busy
echo "=== G1 strict-ancestor live newest row (head $(short "$OLDER") is an ancestor of HEAD $(short "$HEADC")) ==="
echo "  pre-fix : $(prefix_crew_state)"
echo "  fixed   : $(crew_state)"
echo

# --- G2: DIVERGED TERMINAL newest row with a perfect exact-head anchor behind.
setup_case divterm fm/g-divterm
git -C "$WT" commit -q --allow-empty -m 'the work this crew submitted'
HEADC=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q --detach "$(git -C "$WT" rev-list --max-parents=0 HEAD)"
git -C "$WT" commit -q --allow-empty -m 'upstream advanced'
git -C "$WT" commit -q --allow-empty -m 'another task replayed onto it'
DIV=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q fm/g-divterm
export FM_FAKE_RUNS_LIST="  running    fm/other aaaaaaa  2026-09-07 15:00
  failed     fm/g-divterm $(short "$DIV")  2026-09-07 14:14
  completed  fm/g-divterm $(short "$HEADC")  2026-09-07 09:48"
arm_busy
echo "=== G2 diverged TERMINAL newest row + perfect exact-head anchor behind it ==="
echo "  fixed   : $(crew_state)"
echo

# --- G3: rebased live newest row whose anchor row is a DESCENDANT, not the
# exact worktree commit. The anchor is exact-equality only.
setup_case noanchor fm/g-noanchor
git -C "$WT" commit -q --allow-empty -m 'the work this crew submitted'
HEADC=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" commit -q --allow-empty -m 'a later commit'
DESC=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" reset -q --hard "$HEADC"
git -C "$WT" checkout -q --detach "$(git -C "$WT" rev-list --max-parents=0 HEAD)"
git -C "$WT" commit -q --allow-empty -m 'upstream advanced'
git -C "$WT" commit -q --allow-empty -m 'replayed onto it'
REB=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q fm/g-noanchor
export FM_FAKE_RUNS_LIST="  running    fm/other aaaaaaa  2026-09-07 15:00
  running    fm/g-noanchor $(short "$REB")  2026-09-07 14:14
  failed     fm/g-noanchor $(short "$DESC")  2026-09-07 09:48"
arm_busy
echo "=== G3 rebased live row whose anchor is a DESCENDANT, not the exact commit ==="
echo "  fixed   : $(crew_state)"
echo

# --- G4: the reverted sibling rule. Terminal newest row AT the worktree commit
# (binds), live sibling behind it with a DIVERGED head. Round-4 decision: the
# sibling widening was reverted, so the terminal answer stands.
setup_case sibling fm/g-sibling
git -C "$WT" commit -q --allow-empty -m 'the work this crew submitted'
HEADC=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q --detach "$(git -C "$WT" rev-list --max-parents=0 HEAD)"
git -C "$WT" commit -q --allow-empty -m 'upstream advanced'
git -C "$WT" commit -q --allow-empty -m 'replayed onto it'
REB=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q fm/g-sibling
export FM_FAKE_RUNS_LIST="  failed     fm/g-sibling $(short "$HEADC")  2026-09-07 14:14
  running    fm/g-sibling $(short "$REB")  2026-09-07 09:48"
echo "=== G4 terminal row at the worktree commit, diverged live sibling behind it ==="
echo "  pre-fix : $(prefix_crew_state)"
echo "  fixed   : $(crew_state)"
