#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html> [--for <task-id>] [--agent-reply-file <path>]
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh reconciles <result-file>
#   fm-procevent-lavish.sh read <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh poll <artifact.html> [--agent-reply-file <path>]
#   fm-procevent-lavish.sh deliver-reply poll <artifact.html> --agent-reply-file <path>
#   fm-procevent-lavish.sh close-task <task-id> [--root <dir>]... [--save-into <dir>]
#   fm-procevent-lavish.sh close-sweep
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, disconnected, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The freeform message (tag=message) is its
#            own labeled field, printed first and distinct from per-element
#            annotations; it is labeled SESSION-ENDING MESSAGE, and counted as
#            session_ending_message_count, only when the session ended, and is
#            otherwise CAPTAIN MESSAGE and captain_message_count. Declared and
#            presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
#            Both table-form and list-form captures are supported; nested
#            targets and attachments are skipped while the item's own scalar
#            fields are retained. The shared parser below owns the wire format.
#            Malformed content or a declared/presented count mismatch yields
#            complete: no; inspect that verdict, not just the command's exit
#            status. A declared nonempty block parsed as empty is incomplete.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below. A staged reply still
#            present when it starts is posted before the long-poll: through
#            `lavish-axi reply` when supported, otherwise through the legacy
#            best-effort `poll --agent-reply` path.
# deliver-reply
#            Run by `fm-procevent.sh register-task` under the source lock, only
#            after the task is eligible to own the board, with the listener argv
#            it is about to publish. Exit 0 once Lavish accepts the staged reply,
#            3 when the installed Lavish is a confirmed older release without
#            synchronous reply so the listener keeps the legacy path, and any
#            other status when the reply failed or the version is unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#            Task-owned terminal rounds bypass generic silence so their owner
#            receives the stop-and-conclude instruction.
# close-task Close the Lavish pages of a finished task: bin/fm-teardown.sh
#            calls it before the task's copy is returned, and
#            bin/fm-captain-hold.sh answer calls it once a task's last open
#            captain call is answered. Prints one closed:, kept:, saved:,
#            conflict:, or warning: line per page.
# close-sweep
#            The regular check-up the watcher cycle and session start run:
#            close the pages of this home's finished tasks and retry earlier
#            failed close steps. Output is informational; it never refuses.
#
# PLAN PAGES CLOSE THEMSELVES, and this adapter is the one owner of how.
# A page is "this task's page" on exact evidence only: a task-owned listener
# registered for it in this home, or a session in Lavish's own store whose file
# lies under one of close-task's --root directories (compared by full real
# path) or, for the sweep, under this home's data/<task-id>/ for a task this
# home's backlog knows. The sweep closes such a folder-only page only when its
# file is gone or an earlier close-task for that task already saw it (recorded
# in state/lavish-close/task-<id>.pages), so a page opened after the task
# finished, such as its report shown to the captain, is left alone. If a listener and a folder name different tasks, the
# page is left alone and Firstmate is told once. A page with no such record is
# never touched, which is what keeps other homes' and projects' pages safe.
# The bearings board is never a sweep candidate.
#
# A page is kept open while its task still has an open captain call (bin/
# fm-captain-hold.sh open --with-origin: the task itself, or any call recorded
# with the task as its origin), its session is still open, and its file still
# exists; a page whose session already ended or whose file is gone is closed
# (never kept or saved), the call staying in the backlog. The
# sweep also leaves a page alone while its task is still running (state/<id>
# .meta present) and its file exists. When close-task has --save-into and a
# kept page lives under a root other than that directory - the copy about to
# be deleted - the page is copied into it, reopened there, listened on again
# with its answer binding carried over, and the old page closed; the saved:
# line names the new link to give the captain. A save that fails refuses.
#
# Unread captain words always win: a page whose listener holds an
# unacknowledged round carrying captain content (any prompt or feedback item,
# or a block this reader cannot prove empty) is never closed or saved, and a
# round is acknowledged only after that same check. close-task refuses naming the round and the acknowledgement that releases it;
# the sweep instead tells Firstmate once per round for a finished task's
# listener. An empty or failure-only round is acknowledged and closed.
#
# Closing a page is three idempotent steps, in order: stop listening (retire
# its listener), end its session (`lavish-axi end <file>` against the saved
# session's server when the file exists, otherwise Lavish's own per-page
# address POST /api/<key>/end, which must answer {"status":"ended"}), and close
# its tabs in Google Chrome on this Mac (only tabs whose address carries the
# page's /session/<key>; nothing when Chrome is not running or osascript is
# absent). Closing the tab is best effort: when it fails (Chrome automation not
# permitted, a timeout, any error) the page still counts as closed, nothing is
# retried, and Firstmate is told once per home. A failed listener or session
# step never blocks cleanup by itself: it is recorded under state/lavish-close/
# and retried at every later check-up, and only a second consecutive failure
# tells Firstmate, once, naming the page. Without
# lavish-axi both commands are silent no-ops, because the startup check already
# reports a missing Lavish. close-task exits 3 on a refusal, 1 when Lavish's
# page list cannot be read, and 0 otherwise.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds two narrow, positively-determined shapes -
# a session this adapter classifies `ended` that carries no queued content block
# at all, or `browser_disconnected`, which carries no answer while the session
# remains open - and every other result stays announced.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and any error all stay announced, because none of them
# positively proves nothing was said. Silence is only ever an absence this
# adapter can see in the result, never an absence it assumes.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# how to read a completed result, and how a finished task's pages close.
# Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# The published poll vocabulary includes feedback, ended, waiting, and
# browser_disconnected. A waiting result from this no-timeout poll means a
# second poller was present; it is not a normal idle round. browser_disconnected
# means the session remains open and is handled as a silent reconnect wait.
# Before each poll attempt, resolve the artifact's saved URL from Lavish's own
# session store (LAVISH_AXI_STATE_DIR/state.json, default ~/.lavish-axi/state.json)
# and use its host and port. Opening the board writes that URL; polling does not.
# This is a routing lookup before the blocking call, not presence polling or a
# second route record. Ambient/configured addresses must not retarget a reply.
# An unreadable or missing session stops before the staged reply is consumed.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
# `answers` and `reconciles` use the same parser as `read` for either emission
# form. Malformed content or a declared/parsed count mismatch prints a diagnostic
# to stderr and exits 3, even if valid choices were already printed to stdout;
# callers must not treat that output as a complete extraction.
#
# `read` is the presentation command summarized above; keyed intake remains
# the separate `answers` contract described here.
#
# It wraps the published `lavish-axi poll` and `lavish-axi reply` interfaces,
# verified against 0.1.80. `poll` long-polls indefinitely; `reply` exits only
# after the server confirms acceptance. Older compatible versions retain the
# legacy poll-with-reply path, without the synchronous handoff guarantee.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that exact response, with
# attempt starts at least POLL_RETRY_DELAY_DEFAULT seconds apart. The match is exact and
# deliberately narrow: real feedback, ended and missing sessions, any other
# SERVER_ERROR, and the same interruption still standing after the bound is
# spent are all printed straight through and captured normally. The retry is a
# Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

apply_session_host() {  # <artifact>
  local endpoint
  endpoint=$(perl -MJSON::PP -MCwd=realpath -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "cannot resolve board artifact\n";
    $real = decode("UTF-8", $real, FB_CROAK);
    open my $file, "<", $path or die "cannot read Lavish session store\n";
    -f $file or die "Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$file>) };
    !$@ or die "invalid Lavish session store\n";
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    my @sessions = grep {
      ref($_) eq "HASH" && defined($_->{file}) && $_->{file} eq $real
    } values %{$state->{sessions}};
    @sessions == 1 or die "board must have one saved Lavish session\n";
    my $url = $sessions[0]->{url} // "";
    $url =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/session/[0-9a-f]{16}(?:\?[^\s#]*)?\z}
      or die "invalid saved Lavish session URL\n";
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $host ne "0.0.0.0" && $host ne "::" && $port >= 1 && $port <= 65535
      or die "invalid saved Lavish server address\n";
    print "$host\n$port\n";
  ' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" "$1") \
    || die "cannot resolve the board server from its Lavish session: $1"
  LAVISH_AXI_HOST=${endpoint%$'\n'*}
  LAVISH_AXI_PORT=${endpoint##*$'\n'}
  export LAVISH_AXI_HOST LAVISH_AXI_PORT
}

lavish_reply_compatible() {
  local status=0
  "$FM_ROOT/bin/fm-bootstrap.sh" lavish-reply-compatible >/dev/null 2>&1 || status=$?
  case "$status" in
    0|1) return "$status" ;;
  esac
  die "cannot confirm a supported lavish-axi version, so the staged reply was not posted; retry once \`lavish-axi --version\` reports a supported release"
}

post_lavish_reply() {  # <artifact> <reply-file>
  local output
  if ! output=$(lavish-axi reply "$1" --agent-reply-file "$2" 2>&1); then
    [ -n "$output" ] || output="lavish-axi reply exited nonzero"
    die "Lavish did not accept the staged reply: $output"
  fi
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact='' task='' reply_file='' id real owner listening
  local -a listener=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for)
        [ "$#" -ge 2 ] || usage
        task=$2
        shift 2
        ;;
      --agent-reply-file)
        [ "$#" -ge 2 ] || usage
        reply_file=$2
        shift 2
        ;;
      --*) usage ;;
      *)
        [ -z "$artifact" ] || usage
        artifact=$1
        shift
        ;;
    esac
  done
  [ -n "$artifact" ] || usage
  [ -z "$reply_file" ] || [ -n "$task" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  listener=("$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real")
  [ -z "$reply_file" ] || listener+=(--agent-reply-file "$reply_file")
  if [ -n "$task" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register-task lavish "$id" "$task" -- \
      "${listener[@]}" || exit 1
  else
    # This adapter's own listener command, which runs the plain blocking form
    # with no --timeout-ms so completion is a server event, and absorbs only
    # the exact transient interruption.
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
      -- "${listener[@]}" || exit 1
  fi
  # Registration is not a running listener. Readiness is the process-event
  # owner's evidence for this generation; a miss retires a source that never
  # started so arm does not leave it registered.
  listening=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" || listening=$?
  if [ "$listening" -eq 3 ]; then
    printf 'still-listening: %s\n' "$id"
    printf 'artifact: %s\n' "$real"
    [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
    printf 'note: an earlier listener is still live and serving this board; this registration takes effect only after the source is retired and armed again\n'
    exit 0
  fi
  if [ "$listening" -ne 0 ]; then
    owner=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
      | awk -v id="$id" '$1 == id { print $3; exit }')
    case "$owner" in
      live|orphaned|task:*/listening|task:*/round-open) ;;
      *) FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true ;;
    esac
    exit 1
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
}

cmd_deliver_reply() {
  [ "$#" -eq 4 ] && [ "$1" = poll ] && [ "$3" = --agent-reply-file ] || usage
  lavish_reply_compatible || exit 3
  apply_session_host "$2"
  post_lavish_reply "$2" "$4"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MIN=1
POLL_RETRY_DELAY_MAX=60

# Exit 0 only for the exact two-line interruption, and nothing else. The whole
# response must be those two lines with those exact bytes: whitespace variants,
# a longer response that merely opens with them, and any other SERVER_ERROR are
# genuine errors this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $expected = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      my $room = length($expected) + 1 - length($candidate);
      my $take = length($chunk) < $room ? length($chunk) : $room;
      my $prefix = substr($chunk, 0, $take);
      $candidate .= $prefix;
      write_all($staged, $prefix);
      my $matches_prefix = length($candidate) <= length($expected)
        && substr($expected, 0, length($candidate)) eq $candidate;
      if (!$matches_prefix) {
        write_all(*STDOUT, $candidate);
        write_all(*STDOUT, substr($chunk, $take));
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && $candidate eq $expected;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Minimum seconds between retry attempt starts. FM_LAVISH_POLL_RETRY_DELAY is a
# bounded test override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -ge "$POLL_RETRY_DELAY_MIN" ] && [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

poll_iteration_started() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)'
}

poll_iteration_floor_wait() {
  perl -MTime::HiRes=clock_gettime,sleep,CLOCK_MONOTONIC -e '
    my ($started, $floor) = @ARGV;
    my $remaining = $floor - (clock_gettime(CLOCK_MONOTONIC) - $started);
    sleep($remaining) if $remaining > 0;
  ' "$1" "$2"
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc iteration_started
  local pipeline_status reply_file=''
  local reply_text='' reply_pending=0
  [ -n "$artifact" ] || usage
  if [ "$#" -eq 3 ] && [ "${2-}" = --agent-reply-file ]; then
    reply_file=$3
  elif [ "$#" -ne 1 ]; then
    usage
  fi
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    iteration_started=$(poll_iteration_started) || die "cannot start the poll rate governor"
    [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -r "$artifact" ] \
      || die "artifact is no longer a readable file: $artifact"
    apply_session_host "$artifact"
    # Newer Lavish builds expose a one-shot reply command whose success is the
    # server's acceptance receipt. Consume the staged file only after that
    # confirmation; older compatible builds retain the published poll reply
    # behavior and its best-effort delivery boundary.
    if [ -f "$reply_file" ] && [ ! -L "$reply_file" ]; then
      if lavish_reply_compatible; then
        post_lavish_reply "$artifact" "$reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
      else
        reply_text=$(cat -- "$reply_file") \
          || die "cannot read agent reply file: $reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
        reply_pending=1
      fi
    fi
    if [ "$reply_pending" -eq 1 ]; then
      lavish-axi poll "$artifact" --agent-reply "$reply_text" | poll_response_filter "$response"
    else
      lavish-axi poll "$artifact" | poll_response_filter "$response"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    reply_pending=0
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          poll_iteration_floor_wait "$iteration_started" "$delay" \
            || die "cannot enforce the poll rate governor"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  return "$rc"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback)            printf 'feedback\n'; return 0 ;;
    ended)               printf 'ended\n'; return 0 ;;
    waiting)             printf 'waiting\n'; return 0 ;;
    browser_disconnected) printf 'disconnected\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Print the shared result parser described in its own leading comment, for
# prepending to a command's perl program.
lavish_result_parser() {
  cat <<'PERL'
use strict; use warnings;
# The one reader of a captured result's queued-content block, shared by `read`,
# `answers`, and `reconciles` so the two emission forms are parsed in exactly one
# place. lavish-axi encodes its response as TOON and picks the form itself:
#
#   table form, when every item carries the same scalar fields:
#     prompts[N]{uid,prompt,selector,tag,text}:
#       "1","a comment",div#a,div,"Element text"
#   list form, when items differ, for example when some carry a nested
#   `target` object or an `attachments` table:
#     prompts[N]:
#       - uid: "1"
#         prompt: "a comment"
#         target:
#           type: table-cell
#
# Only a column-zero header opens a block, and the block is the indented lines
# that follow it. Every captain-supplied value is a single encoded line, so an
# item or field boundary is only ever an indentation the encoder wrote: in list
# form an item starts at the first item's hyphen indent, its own fields sit one
# indent deeper, and anything deeper still is skipped only beneath a field that
# opened a nested object or array. Only an item's own scalar fields are
# returned. A line or item the parser cannot fully account for is counted as
# malformed rather than dropped, and a column-zero line that names the block
# but is not a recognized header makes the whole result malformed, so a form
# this reader does not know can never look like a complete, empty result.
#
# lavish_result(<path>, <block-name-regex>) returns
# (form, declared, [item hashes], malformed), with form one of none, table,
# list, or unrecognized.
sub lavish_unescape {
  my ($v) = @_;
  $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
  return $v;
}
sub lavish_table_rows {
  my ($fields, $rows) = @_;
  my (@items, $malformed);
  $malformed = 0;
  for my $row (@$rows) {
    $row =~ s/^\s+//;
    my @vals;
    while (length $row) {
      if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
        push @vals, $1;
      } else {
        $row =~ s/^([^,]*)//;
        push @vals, $1;
      }
      last unless $row =~ s/^,//;
    }
    # An unquoted prompt or text value may carry commas; rejoin the surplus
    # into that one field rather than shifting every later column.
    if (@vals > @$fields) {
      my ($preserve) = grep { $fields->[$_] eq "prompt" } 0 .. $#$fields;
      ($preserve) = grep { $fields->[$_] eq "text" } 0 .. $#$fields unless defined $preserve;
      if (defined $preserve) {
        my $count = @vals - @$fields + 1;
        my @parts = splice @vals, $preserve, $count;
        splice @vals, $preserve, 0, join(",", @parts);
      }
    }
    if (@vals != @$fields) {
      $malformed++;
      next;
    }
    my %f;
    $f{$fields->[$_]} = lavish_unescape($vals[$_]) for 0 .. $#$fields;
    push @items, \%f;
  }
  return (\@items, $malformed);
}
sub lavish_list_items {
  my ($lines) = @_;
  my (@items, $unit, $cur, $bad, $nested, %keys);
  my ($malformed, $stray) = (0, 0);
  my $finish = sub {
    return unless $cur;
    if ($bad || !%$cur) { $malformed++ } else { push @items, $cur }
    ($cur, $bad, $nested) = (undef, 0, 0);
  };
  my $field = sub {
    my ($s) = @_;
    my $key;
    if ($s =~ s/^"((?:[^"\\]|\\.)*)"//) {
      $key = lavish_unescape($1);
    } elsif ($s =~ s/^([A-Za-z_][A-Za-z0-9_.]*)//) {
      $key = $1;
    } else {
      $bad = 1;
      return;
    }
    $bad = 1 if $keys{$key}++;
    $nested = 0;
    if ($s =~ /^(?::|\[\d+\](?:\{[^}]*\})?:)\s*$/) {
      $nested = 1;
    } elsif ($s =~ /^\[\d+\]: /) {
      # An inline primitive array is not an item field this adapter reads.
    } elsif ($s =~ /^: (.*)$/) {
      my $v = $1;
      if ($v =~ /^"/) {
        if ($v =~ /^"((?:[^"\\]|\\.)*)"\s*$/) {
          $cur->{$key} = lavish_unescape($1);
        } else {
          $bad = 1;
        }
      } else {
        $v =~ s/\s+$//;
        $cur->{$key} = $v;
      }
    } else {
      $bad = 1;
    }
  };
  for my $line (@$lines) {
    $line =~ /^( *)(.*)$/s;
    my ($ind, $rest) = (length $1, $2);
    $unit = $ind if !defined($unit) && $ind > 0 && $rest =~ /^-(?: |$)/;
    if (defined($unit) && $ind == $unit && $rest =~ /^-(?: (.*))?$/s) {
      my $first = $1;
      $finish->();
      ($cur, $bad, $nested) = ({}, 0, 0);
      %keys = ();
      if (defined $first) { $field->($first) } else { $bad = 1 }
    } elsif ($cur && $ind == 2 * $unit) {
      $field->($rest);
    } elsif ($cur && $nested && $ind > 2 * $unit) {
      next;
    } elsif ($cur) {
      $bad = 1;
    } else {
      $stray = 1;
    }
  }
  $finish->();
  return (\@items, $malformed + $stray);
}
sub lavish_result {
  my ($path, $names) = @_;
  open my $fh, "<", $path or return;
  my ($form, $want, @fields, @body) = ("none", 0);
  while (my $line = <$fh>) {
    chomp $line;
    if ($form eq "none") {
      next unless $line =~ /^(?:$names)/;
      if ($line =~ /^(?:$names)\[(\d+)\]\{([^}]*)\}:\s*$/) {
        ($form, $want, @fields) = ("table", $1, split /,/, $2);
      } elsif ($line =~ /^(?:$names)\[(\d+)\]:\s*$/) {
        ($form, $want) = ("list", $1);
      } else {
        $form = "unrecognized";
        $want = $1 if $line =~ /^(?:$names)\[(\d+)\]/;
        last;
      }
      next;
    }
    last unless $line =~ /^\s/;
    last if $form eq "table" && @body >= $want;
    push @body, $line;
  }
  close $fh;
  return ($form, $want, [], 1) if $form eq "unrecognized";
  return ($form, $want, [], 0) if $form eq "none";
  my ($items, $malformed) = $form eq "table"
    ? lavish_table_rows(\@fields, \@body)
    : lavish_list_items(\@body);
  return ($form, $want, $items, $malformed);
}
PERL
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` table header, or a `prompts[N]:` list header, whose items
# are INDENTED, so this anchors on column zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\](\{[^}]*\})?:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = disconnected ] && return 0
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for each non-reconcile structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake.
# A `keep-open` selection, or a versioned row with a note and no selection,
# instead carries mode `keep` and the captain's note (or `(no note)`) as the
# answer, overriding the card's declared mode.
# Items come from the shared result parser above, in either emission form, and
# only items whose `tag` field is `choice` are read.
# The header owns the partial-output and failure contract.
# A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and the versioned `selection` and `note` fields inside its `Context data:` block
# is skipped. A time-limited rollout branch accepts the old question/answer
# shape only for ordinary answers and rejects its bare or annotated reconcile
# values because old rows do not separate the selected option from its note.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_choice_rows() {
  local selection=$1 file=${2-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($selection, $path) = @ARGV;
    my ($form, $want, $items, $malformed) = lavish_result($path, "prompts");
    defined $form or exit 1;
    my %seen;
    my @choices;
    for my $item (@$items) {
      my %f = %$item;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my ($key, $selected, $note, $answer, $legacy);
      if (defined($data->{schema}) && !ref($data->{schema})
          && $data->{schema} eq "fm-bearings-answer.v1") {
        $key = $data->{question};
        $selected = $data->{selection};
        $note = $data->{note};
        next if !defined($key) || ref($key) || !defined($selected) || ref($selected)
          || !defined($note) || ref($note);
        next unless $selected eq "" || $selected =~ /\A[A-Za-z0-9._-]{1,128}\z/;
        next unless length($note) <= 512;
        next unless length($selected) || length($note);
        $answer = length($selected) ? $selected : $note;
        $legacy = 0;
      # Time-limited compatibility for captures from pre-change boards; remove
      # once no board carrying the old question/answer context can remain armed.
      } elsif (!exists($data->{schema}) && !exists($data->{selection})
          && !exists($data->{note})) {
        $key = $data->{question};
        $answer = $data->{answer};
        next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
        next unless length($answer) && length($answer) <= 512;
        next if $answer eq "reconcile" || index($answer, "reconcile - ") == 0;
        $selected = "";
        $note = "";
        $legacy = 1;
      } else {
        next;
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      # Keep-open, and a note with no selected option, are not final answers:
      # whatever the card declared, they keep the call open with the
      # words of the captain (docs/captain-hold-lifecycle.md owns the meaning).
      if (!$legacy && ($selected eq "keep-open" || !length($selected))) {
        $mode = "keep";
        $answer = length($note) ? $note : "(no note)";
      }
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $note, $label);
      $label = substr($label, 0, 512);
      if (defined $seen{$key}) { $choices[$seen{$key}] = undef }
      $seen{$key} = scalar @choices;
      push @choices, {
        key => $key, selection => $selected, note => $note, legacy => $legacy,
        answer => $answer, label => $label, mode => $mode
      };
    }
    for my $choice (grep { defined } @choices) {
      if ($selection eq "reconciles") {
        next if $choice->{legacy};
        if ($choice->{selection} eq "reconcile") {
          print length($choice->{note})
            ? "$choice->{key}\t$choice->{note}\n"
            : "$choice->{key}\n";
        }
        next;
      }
      next if $choice->{selection} eq "reconcile";
      print length $choice->{mode}
        ? "$choice->{key}\t$choice->{answer}\t$choice->{label}\t$choice->{mode}\n"
        : "$choice->{key}\t$choice->{answer}\t$choice->{label}\n";
    }
    if ($malformed || @$items != $want) {
      print STDERR "error: the result is not fully accounted for: declared $want, parsed ",
        scalar(@$items), ", malformed $malformed\n";
      exit 3;
    }
  ' "$selection" "$file"
}

cmd_answers() { cmd_choice_rows answers "$@"; }
cmd_reconciles() { cmd_choice_rows reconciles "$@"; }

# Present one already-captured result for a handler. Body lines are prefixed
# so a captain-supplied string cannot forge a section label. A freeform message
# is printed before the count line and before any annotation, because that is
# the field a truncated grep of the raw capture historically dropped.
# A non-choice annotation that carries a freeform `prompt` prints that comment
# as its own field; a selector must not hide the typed words, even when the
# comment matches the captured element text. Choice rows keep Context data
# out of that field. A pure annotation has no prompt.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  perl -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($path, $lifecycle, $session_ended) = @ARGV;
    my ($form, $want, $items, $malformed) = lavish_result($path, "prompts|feedback");
    defined $form or exit 1;
    my @parsed = @$items;
    my $presented = scalar @parsed;
    my $complete = ($presented == $want && !$malformed) ? "yes" : "no";
    my @messages;
    my @annotations;
    for my $f (@parsed) {
      my $tag = defined $f->{tag} ? $f->{tag} : "";
      if ($tag eq "message") {
        push @messages, $f;
      } else {
        push @annotations, $f;
      }
    }
    sub emit_body {
      my ($text) = @_;
      $text = "" unless defined $text;
      $text =~ s/\r\n/\n/g;
      $text =~ s/\r/\n/g;
      my @lines = split /\n/, $text, -1;
      pop @lines if @lines && $lines[-1] eq "";
      return if !@lines || (@lines == 1 && $lines[0] eq "");
      print "| $_\n" for @lines;
    }
    my $ended = $session_ended =~ /^(?:true|True|TRUE)$/;
    if (@messages) {
      my $message_label = $ended ? "SESSION-ENDING MESSAGE" : "CAPTAIN MESSAGE";
      print "$message_label\n";
      for my $i (0 .. $#messages) {
        print "$message_label PART ", ($i + 1), " of ", scalar(@messages), "\n" if @messages > 1;
        my $body = defined $messages[$i]{prompt} && length $messages[$i]{prompt}
          ? $messages[$i]{prompt}
          : (defined $messages[$i]{text} ? $messages[$i]{text} : "");
        emit_body($body);
      }
      print "END $message_label\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "declared_items: $want\n";
    print "presented_items: $presented\n";
    print "malformed_items: $malformed\n";
    print "complete: $complete\n";
    print "lifecycle: $lifecycle\n";
    print "session_ended: ", (length $session_ended ? $session_ended : "(unset)"), "\n";
    print "annotation_count: ", scalar(@annotations), "\n";
    my $message_count_key = $ended ? "session_ending_message_count" : "captain_message_count";
    print "$message_count_key: ", scalar(@messages), "\n";
    print "\n";
    if (@annotations) {
      print "ANNOTATIONS\n";
      my $n = 0;
      for my $f (@annotations) {
        $n++;
        my $uid = defined $f->{uid} ? $f->{uid} : "";
        my $selector = defined $f->{selector} ? $f->{selector} : "";
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        print "ANNOTATION $n of ", scalar(@annotations), "\n";
        print "element_uid: $uid\n";
        print "element_selector: $selector\n";
        print "tag: $tag\n";
        print "text:\n";
        my $elem = defined $f->{text} ? $f->{text} : "";
        my $comment = defined $f->{prompt} ? $f->{prompt} : "";
        my $body = length $elem ? $elem : $comment;
        emit_body($body);
        if ($tag ne "choice" && length $comment) {
          print "prompt:\n";
          emit_body($comment);
        }
      }
      print "END ANNOTATIONS\n";
    } else {
      print "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
  ' "$file" "$lifecycle" "$session_ended"
}

# --- plan pages close themselves (see the header) ----------------------------

CLOSE_STATE_DIR="$STATE/lavish-close"
CLOSE_END_SECONDS=30
CLOSE_TAB_SECONDS=10
CLOSE_REFUSED=0

lavish_store_file() { printf '%s/state.json\n' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}"; }

close_realpath() {  # <path>: its real path when it exists, else the path itself
  perl -MCwd=realpath -e '
    my $p = $ARGV[0];
    my $r = -e $p ? realpath($p) : undef;
    $p =~ s{/+\z}{} if $p ne "/";
    print defined($r) ? $r : $p, "\n";
  ' "$1"
}

close_under() {  # <path> <root>
  case "$1" in "$2"|"$2"/*) return 0 ;; esac
  return 1
}

# One line per session in Lavish's own store: key, status, url, file, tab
# separated. A session whose fields cannot be carried safely is skipped; an
# address that is not a saved http session URL for that same key is dropped.
close_store_sessions() {  # <store>
  perl -MJSON::PP -MEncode=encode -e '
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or die "cannot read the Lavish session store\n";
    -f $fh or die "the Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$fh>) };
    !$@ && ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    for my $name (sort keys %{$state->{sessions}}) {
      my $s = $state->{sessions}{$name};
      next unless ref($s) eq "HASH";
      my ($key, $status, $url, $file) =
        map { defined($_) && !ref($_) ? $_ : "" } @$s{qw(key status url file)};
      next unless $key =~ /\A[0-9a-f]{16}\z/ && $key eq $name;
      next unless length($file) && $file =~ m{\A/} && $file !~ /[\t\n\r]/;
      $status = "unknown" unless $status =~ /\A[a-z_]+\z/;
      $url = "" unless $url =~ m{\Ahttp://(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):[0-9]+/session/\Q$key\E(?:\?[^\s#]*)?\z};
      print join("\t", $key, $status, $url, encode("UTF-8", $file)), "\n";
    }
  ' "$1"
}

close_session_field() {  # <key> <field-number>: from CLOSE_SESSIONS
  printf '%s\n' "$CLOSE_SESSIONS" | awk -F '\t' -v k="$1" -v f="$2" '$1 == k { print $f; exit }'
}

# This home's Lavish listeners as `<key><TAB><owner>`: the owner task of a
# task-owned listener, or `-` for one firstmate holds.
close_sources_load() {
  local out
  CLOSE_SOURCES=
  [ -d "$STATE/procevent" ] || return 0
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null) || return 1
  CLOSE_SOURCES=$(printf '%s\n' "$out" | awk '
    $2 == "lavish" && length($1) == 23 && $1 ~ /^lavish-[0-9a-f]+$/ {
      owner = "-"
      if ($3 ~ /^task:/) { owner = substr($3, 6); sub(/\/[^\/]*$/, "", owner) }
      printf "%s\t%s\n", substr($1, 8), owner
    }')
}

close_source_owner() {  # <key>: prints the owner field, or nothing when unregistered
  printf '%s\n' "$CLOSE_SOURCES" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'
}

# Set CLOSE_CALL to a task's open-call state, cached for one run: 0 open,
# 1 none, 2 cannot tell, 3 a task this home's backlog does not know and no call
# names. Call it in this shell, never in a command substitution, so the cache
# survives.
close_call_state() {  # <task-id>
  local rc=0
  CLOSE_CALL=$(printf '%s\n' "${CLOSE_CALL_CACHE-}" | awk -F '\t' -v t="$1" '$1 == t { print $2; exit }')
  [ -z "$CLOSE_CALL" ] || return 0
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" --with-origin --distinguish-absent >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|1|3) ;; *) rc=2 ;; esac
  CLOSE_CALL_CACHE="${CLOSE_CALL_CACHE-}$1"$'\t'"$rc"$'\n'
  CLOSE_CALL=$rc
}

# This home's data/<task-id>/ owner of a page file, or nothing.
close_data_owner() {  # <file>
  local rest id
  [ -n "${CLOSE_DATA_REAL-}" ] || return 0
  close_under "$1" "$CLOSE_DATA_REAL" || return 0
  rest=${1#"$CLOSE_DATA_REAL"/}
  case "$rest" in */*) id=${rest%%/*} ;; *) return 0 ;; esac
  fm_pr_task_id_valid "$id" || return 0
  printf '%s\n' "$id"
}

# Unacknowledged captured rounds of one listener, oldest first.
close_pending_rounds() {  # <source-id>
  local result
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    case "${result##*/}" in "$1".*.result) printf '%s\n' "$result" ;; esac
  done < <(fm_procevent_pending "$STATE")
}

close_round_sequence() {  # <result-file>
  local base=${1##*/}
  base=${base%.result}
  printf '%s\n' "${base##*.}"
}

# Exit 0 when a captured round carries captain content or cannot be proved
# empty; 1 only when every prompt or feedback block is provably empty.
close_round_has_words() {  # <result-file>
  perl -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or exit 0;
    my @lines = <$fh>;
    close $fh;
    for my $name ("prompts", "feedback") {
      my @heads = grep { /^\Q$name\E(?![A-Za-z0-9_])/ } @lines;
      next unless @heads;
      exit 0 if @heads > 1;
      next if $heads[0] =~ /^\Q$name\E: \[\]\s*$/;
      my ($form, $want, $items, $malformed) = lavish_result($path, $name);
      exit 0 if !defined($form) || $form eq "unrecognized" || $malformed || $want > 0 || @$items > 0;
    }
    exit 1;
  ' "$1"
}

# The first round of a listener that carries captain words, if any.
close_worded_round() {  # <source-id>
  local result
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    if close_round_has_words "$result"; then
      printf '%s\n' "$result"
      return 0
    fi
  done < <(close_pending_rounds "$1")
  return 1
}

close_notice_once() {  # <key> <kind> <generation> <payload>
  local marker="$CLOSE_STATE_DIR/$1.$2.noticed" previous
  previous=$(cat -- "$marker" 2>/dev/null || true)
  [ "$previous" != "$3" ] || return 0
  (umask 077; mkdir -p "$CLOSE_STATE_DIR" && printf '%s\n' "$3" > "$marker") || return 1
  if ! fm_wake_append check "lavish-close:$1:$2:$3" "check: $4"; then
    rm -f -- "$marker"
    return 1
  fi
}

close_record_read() {  # <key> <field>
  sed -n "s/^$2=//p" "$CLOSE_STATE_DIR/$1.failed" 2>/dev/null | head -1
}

close_record_failure() {  # <key> <owner> <label> <detail>
  local key=$1 owner=$2 label=$3 detail=$4 count tmp
  count=$(close_record_read "$key" count)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  (umask 077; mkdir -p "$CLOSE_STATE_DIR") || return 1
  tmp=$(umask 077; mktemp "$CLOSE_STATE_DIR/.$key.XXXXXX") || return 1
  if ! printf 'count=%s\nowner=%s\n' "$count" "$owner" > "$tmp" \
    || ! mv -f -- "$tmp" "$CLOSE_STATE_DIR/$key.failed"; then
    rm -f -- "$tmp"
    return 1
  fi
  [ "$count" -ge 2 ] || return 0
  close_notice_once "$key" failed 1 \
    "Lavish page $label of task $owner could not be fully closed after $count tries ($detail). Firstmate retries it at every check-up; if it keeps failing, end it from the page itself and close its tab by hand."
}

close_record_clear() {  # <key>
  rm -f -- "$CLOSE_STATE_DIR/$1.failed" "$CLOSE_STATE_DIR/$1.failed.noticed"
}

close_host_port() {  # <url>: prints host and port on two lines
  perl -e '
    $ARGV[0] =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/} or exit 1;
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $port >= 1 && $port <= 65535 or exit 1;
    print "$host\n$port\n";
  ' "$1"
}

# Close every Chrome tab whose address carries this page's session path. The
# Chrome-specific part compiles only once Chrome is known to be running, so a
# Mac without Chrome never fails here.
close_tabs() {  # <key>
  command -v osascript >/dev/null 2>&1 || return 0
  fm_run_timed "$CLOSE_TAB_SECONDS" osascript \
    -e 'on run argv' \
    -e 'set needle to item 1 of argv' \
    -e 'try' \
    -e 'set chromeRunning to (application id "com.google.Chrome" is running)' \
    -e 'on error' \
    -e 'set chromeRunning to false' \
    -e 'end try' \
    -e 'if not chromeRunning then return "0"' \
    -e 'return run script "on run {needle}
set closedCount to 0
tell application id \"com.google.Chrome\"
repeat with w in (every window)
repeat with i from (count of tabs of w) to 1 by -1
if (URL of tab i of w) contains needle then
close tab i of w
set closedCount to closedCount + 1
end if
end repeat
end repeat
end tell
return closedCount
end run" with parameters {needle}' \
    -e 'end run' \
    "/session/$1" >/dev/null 2>&1
}

close_end_session() {  # <key> <url> <file>: prints a failure detail and returns 1 on failure
  local key=$1 url=$2 file=$3 endpoint host port out
  if [ -z "$url" ]; then
    printf 'no saved session address'
    return 1
  fi
  endpoint=$(close_host_port "$url") || { printf 'unusable session address'; return 1; }
  host=${endpoint%$'\n'*}
  port=${endpoint##*$'\n'}
  if [ -f "$file" ]; then
    out=$(LAVISH_AXI_HOST=$host LAVISH_AXI_PORT=$port \
      fm_run_timed "$CLOSE_END_SECONDS" lavish-axi end "$file" 2>&1) && return 0
    printf 'lavish-axi end failed: %s' "$(printf '%s' "$out" | head -1)"
    return 1
  fi
  case "$host" in *:*) host="[$host]" ;; esac
  out=$(fm_run_timed "$CLOSE_END_SECONDS" curl -sS --max-time 15 -X POST \
    "http://$host:$port/api/$key/end" 2>&1) || {
    printf 'the page address did not answer: %s' "$(printf '%s' "$out" | head -1)"
    return 1
  }
  if printf '%s' "$out" | perl -MJSON::PP -e '
      local $/; my $r = eval { decode_json(<STDIN>) };
      exit((ref($r) eq "HASH" && defined($r->{status}) && $r->{status} eq "ended") ? 0 : 1);'; then
    return 0
  fi
  printf 'Lavish %s answered the page address with %s instead of {"status":"ended"}' \
    "$(lavish-axi --version 2>/dev/null | head -1)" "$(printf '%s' "$out" | head -1)"
  return 1
}

close_refuse_words() {  # <label> <owner> <key> <result-file>
  local seq
  seq=$(close_round_sequence "$4")
  close_refuse "$1 (task $2) has unread captain words in round lavish-$3 $seq; read them with bin/fm-procevent-lavish.sh read $4, then acknowledge with bin/fm-procevent.sh handled lavish-$3 $seq"
}

# Stop listening, end the session, close the tab. Each step is idempotent; a
# listener or session failure is recorded for the next check-up instead of
# stopping cleanup. Returns 1, closing nothing more, when a round carrying
# captain words turns up: close-task refuses, the sweep leaves it for later.
close_finish_page() {  # <mode> <key> <owner>
  local mode=$1 key=$2 owner=$3 url status file label failed='' detail result seq
  url=$(close_session_field "$key" 3)
  status=$(close_session_field "$key" 2)
  file=$(close_session_field "$key" 4)
  label=${url:-lavish-$key}
  if [ -n "$(close_source_owner "$key")" ]; then
    while IFS= read -r result <&7; do
      [ -n "$result" ] || continue
      if close_round_has_words "$result"; then
        [ "$mode" != task ] || close_refuse_words "$label" "$owner" "$key" "$result"
        return 1
      fi
      seq=$(close_round_sequence "$result")
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" handled "lavish-$key" "$seq" >/dev/null 2>&1 \
        || failed="$failed; acknowledging round $seq failed"
    done 7< <(close_pending_rounds "lavish-$key")
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "lavish-$key" >/dev/null 2>&1 \
      || failed="$failed; stopping its listener failed"
  fi
  if [ "$status" = open ]; then
    detail=$(close_end_session "$key" "$url" "$file") || failed="$failed; ending it failed: $detail"
  fi
  if ! close_tabs "$key"; then
    close_notice_once chrome tabs 1 \
      "Firstmate could not close a finished Lavish page's Chrome tab on this Mac (Chrome automation may not be permitted for the terminal, or Chrome did not answer). Pages are still ended; close leftover tabs by hand, or allow the terminal to control Google Chrome in System Settings > Privacy & Security > Automation." || true
  fi
  if [ -z "$failed" ]; then
    close_record_clear "$key"
    printf 'closed: %s (task %s)\n' "$label" "$owner"
    return 0
  fi
  failed=${failed#; }
  printf 'warning: %s (task %s): %s; retried at the next check-up\n' "$label" "$owner" "$failed"
  close_record_failure "$key" "$owner" "$label" "$failed" || true
}

close_refuse() {  # <message>
  printf 'refused: %s\n' "$1" >&2
  CLOSE_REFUSED=1
}

# Decision 4: copy a page out of a copy about to be deleted, reopen it in
# <save-into>, carry its listener and answer binding over, then close the old.
close_save_page() {  # <key> <owner> <save-into>
  local key=$1 owner=$2 into=$3 url file base stem ext target out new_url new_key binding
  url=$(close_session_field "$key" 3)
  file=$(close_session_field "$key" 4)
  if ! (umask 077; mkdir -p "$into") 2>/dev/null || [ ! -d "$into" ]; then
    close_refuse "cannot save page $file of task $owner, which still has an open captain call, into $into; cleanup stopped so the page is not lost"
    return 0
  fi
  base=${file##*/}
  target="$into/$base"
  if [ -e "$target" ] && ! cmp -s "$file" "$target"; then
    case "$base" in
      *.*) stem=${base%.*}; ext=.${base##*.} ;;
      *) stem=$base; ext= ;;
    esac
    target="$into/$stem-$key$ext"
  fi
  if [ -e "$target" ] && ! cmp -s "$file" "$target"; then
    close_refuse "cannot save page $file of task $owner into $into: $target already holds a different page; cleanup stopped so the page is not lost"
    return 0
  fi
  if [ ! -e "$target" ] && ! cp -p "$file" "$target" 2>/dev/null; then
    rm -f -- "$target"
    close_refuse "cannot copy page $file of task $owner into $into; cleanup stopped so the page is not lost"
    return 0
  fi
  if ! out=$(fm_run_timed "$CLOSE_END_SECONDS" lavish-axi "$target" 2>&1); then
    close_refuse "saved page $file of task $owner as $target but Lavish could not reopen it: $(printf '%s' "$out" | head -1)"
    return 0
  fi
  new_url=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
  new_key=$(cmd_source_id "$target" 2>/dev/null) || new_key=
  new_key=${new_key#lavish-}
  if [ -n "$(close_source_owner "$key")" ]; then
    binding=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "lavish-$key" 2>/dev/null) || binding=
    if [ -n "$binding" ] && [ -n "$new_key" ]; then
      if [ "$binding" = '(any)' ]; then
        "$SCRIPT_DIR/fm-captain-hold.sh" bind "lavish-$new_key" >/dev/null 2>&1 || binding=failed
      else
        "$SCRIPT_DIR/fm-captain-hold.sh" bind "lavish-$new_key" "$binding" >/dev/null 2>&1 || binding=failed
      fi
      if [ "$binding" = failed ]; then
        close_refuse "saved page $file of task $owner as $target but could not carry its answer binding over"
        return 0
      fi
    fi
    if ! out=$(cmd_arm "$target" 2>&1); then
      close_refuse "saved page $file of task $owner as $target but could not listen on it: $(printf '%s' "$out" | tail -1)"
      return 0
    fi
  fi
  [ -z "$new_key" ] || close_task_pages_note "$owner" "$new_key"
  close_finish_page task "$key" "$owner" || return 0
  printf 'saved: %s -> %s (%s; task %s still has an open captain call; give the captain the new link)\n' \
    "${url:-lavish-$key}" "${new_url:-$target}" "$target" "$owner"
}

# Decide and act on one page. <mode> is task (close-task) or sweep.
close_consider() {  # <mode> <key> <owner> <evidence> [save-into] [root...]
  local mode=$1 key=$2 owner=$3 evidence=$4 into=${5-} url status file label src calls result seq root doomed=0
  shift 5 2>/dev/null || shift "$#"
  url=$(close_session_field "$key" 3)
  status=$(close_session_field "$key" 2)
  file=$(close_session_field "$key" 4)
  label=${url:-lavish-$key}
  src=$(close_source_owner "$key")
  # The sweep leaves a running task's page alone unless its file is known gone.
  if [ "$mode" = sweep ] && [ -f "$STATE/$owner.meta" ]; then
    [ -n "$file" ] && [ ! -e "$file" ] || return 0
  fi
  if [ -n "$src" ] && result=$(close_worded_round "lavish-$key"); then
    seq=$(close_round_sequence "$result")
    if [ "$mode" = task ]; then
      close_refuse_words "$label" "$owner" "$key" "$result"
    elif [ "$src" != - ]; then
      close_notice_once "$key" unread "$seq" \
        "Lavish page $label of finished task $owner holds unread captain words in round lavish-$key $seq, which no worker will read. Read them with bin/fm-procevent-lavish.sh read $result, then acknowledge with bin/fm-procevent.sh handled lavish-$key $seq so the page can close." || true
    fi
    return 0
  fi
  close_call_state "$owner"
  calls=$CLOSE_CALL
  if [ "$mode" = sweep ] && [ "$evidence" = path ] && [ "$calls" = 3 ]; then
    return 0
  fi
  if { [ "$calls" = 0 ] || [ "$calls" = 2 ]; } && [ "$status" = open ] && [ -n "$file" ] && [ -e "$file" ]; then
    if [ -n "$into" ] && ! close_under "$file" "$into"; then
      for root in "$@"; do
        if close_under "$file" "$root"; then doomed=1; break; fi
      done
    fi
    if [ "$doomed" = 1 ]; then
      close_save_page "$key" "$owner" "$into"
      return 0
    fi
    close_record_clear "$key"
    printf 'kept: %s (task %s still has an open captain call)\n' "$label" "$owner"
    return 0
  fi
  close_finish_page "$mode" "$key" "$owner" || true
}

close_task_pages_file() {  # <task-id>
  printf '%s/task-%s.pages\n' "$CLOSE_STATE_DIR" "$1"
}

# Remember which pages close-task saw for a task, so the sweep closes only
# folder pages that already existed then.
close_task_pages_note() {  # <task-id> <key>...
  local file
  [ "$#" -ge 2 ] || return 0
  file=$(close_task_pages_file "$1")
  shift
  (umask 077; mkdir -p "$CLOSE_STATE_DIR" && printf '%s\n' "$@" >> "$file") 2>/dev/null || true
}

close_task_page_seen() {  # <task-id> <key>
  grep -Fxq -- "$2" "$(close_task_pages_file "$1")" 2>/dev/null
}

close_sessions_load() {
  CLOSE_SESSIONS=
  if [ -e "$CLOSE_STORE" ] || [ -L "$CLOSE_STORE" ]; then
    CLOSE_SESSIONS=$(close_store_sessions "$CLOSE_STORE") \
      || die "cannot read Lavish's page list at $CLOSE_STORE; repair or move it, then retry"
  fi
}

# A cheap guard before parsing the store: no session file can lie under a root
# the store's bytes never mention. Roots holding characters JSON would escape
# are always parsed.
close_store_mentions() {  # <root>...
  local root
  [ -e "$CLOSE_STORE" ] || return 1
  for root in "$@"; do
    case "$root" in *'"'*|*\\*) return 0 ;; esac
    grep -F -q -- "$root" "$CLOSE_STORE" 2>/dev/null && return 0
  done
  return 1
}

cmd_close_task() {
  local task=${1-} into='' root key owner evidence path_owner file seen=$'\n'
  local -a roots=()
  [ -n "$task" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; roots+=("$(close_realpath "$2")"); shift 2 ;;
      --save-into) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; into=$(close_realpath "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  fm_pr_task_id_valid "$task" || die "task id is invalid: $task"
  command -v lavish-axi >/dev/null 2>&1 || return 0
  CLOSE_STORE=$(lavish_store_file)
  close_sources_load || die "cannot read this home's Lavish listeners"
  if [ -z "$(printf '%s\n' "$CLOSE_SOURCES" | awk -F '\t' -v t="$task" '$2 == t')" ] \
    && { [ "${#roots[@]}" -eq 0 ] || ! close_store_mentions "${roots[@]}"; }; then
    return 0
  fi
  close_sessions_load
  CLOSE_DATA_REAL=$(close_realpath "${FM_DATA_OVERRIDE:-$FM_HOME/data}")
  while IFS=$'\t' read -r key owner <&7; do
    [ -n "$key" ] || continue
    if [ "$owner" = "$task" ]; then
      case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
      seen+="$key"$'\n'
      path_owner=$(close_data_owner "$(close_session_field "$key" 4)")
      if [ -n "$path_owner" ] && [ "$path_owner" != "$task" ]; then
        close_call_state "$path_owner"
        if [ "$CLOSE_CALL" != 3 ]; then
          close_conflict "$key" "$task" "$path_owner"
          continue
        fi
      fi
      close_consider task "$key" "$task" source "$into" "${roots[@]+"${roots[@]}"}"
    fi
  done 7<<EOF
$CLOSE_SOURCES
EOF
  while IFS=$'\t' read -r key _ _ file <&7; do
    [ -n "$key" ] || continue
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    evidence=
    for root in "${roots[@]+"${roots[@]}"}"; do
      if close_under "$file" "$root"; then evidence=path; break; fi
    done
    [ -n "$evidence" ] || continue
    seen+="$key"$'\n'
    owner=$(close_source_owner "$key")
    if [ -n "$owner" ] && [ "$owner" != - ] && [ "$owner" != "$task" ]; then
      close_conflict "$key" "$owner" "$task"
      continue
    fi
    close_consider task "$key" "$task" path "$into" "${roots[@]+"${roots[@]}"}"
  done 7<<EOF
$CLOSE_SESSIONS
EOF
  # shellcheck disable=SC2086  # $seen holds one 16-hex key per line.
  close_task_pages_note "$task" $seen
  [ "$CLOSE_REFUSED" = 0 ] || exit 3
}

close_conflict() {  # <key> <listener-task> <folder-task>
  local label
  label=$(close_session_field "$1" 3)
  label=${label:-lavish-$1}
  printf 'conflict: %s (its listener belongs to task %s but its file lies in task %s'"'"'s folder; left open)\n' \
    "$label" "$2" "$3"
  close_notice_once "$1" conflict "$2-$3" \
    "Lavish page $label was left open: its listener belongs to task $2 but its file lies in task $3's folder, so Firstmate cannot tell whose page it is. Close it by hand once you know." || true
}

close_failures_recorded() {
  local record
  for record in "$CLOSE_STATE_DIR"/*.failed; do
    [ -f "$record" ] && return 0
  done
  return 1
}

cmd_close_sweep() {
  local key owner status file path_owner src rec seen=$'\n' bearings record
  [ "$#" -eq 0 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || return 0
  CLOSE_STORE=$(lavish_store_file)
  CLOSE_DATA_REAL=$(close_realpath "${FM_DATA_OVERRIDE:-$FM_HOME/data}")
  close_sources_load || die "cannot read this home's Lavish listeners"
  if [ -z "$(printf '%s\n' "$CLOSE_SOURCES" | awk -F '\t' '$2 != "-" && $2 != ""')" ] \
    && ! close_failures_recorded \
    && ! close_store_mentions "$CLOSE_DATA_REAL/"; then
    return 0
  fi
  close_sessions_load
  bearings=$(close_realpath "$FM_HOME/.lavish/bearings-board.html")
  # Listeners this home's finished tasks own.
  while IFS=$'\t' read -r key src <&7; do
    [ -n "$key" ] && [ "$src" != - ] || continue
    seen+="$key"$'\n'
    file=$(close_session_field "$key" 4)
    [ "$file" != "$bearings" ] || continue
    path_owner=$(close_data_owner "$file")
    if [ -n "$path_owner" ] && [ "$path_owner" != "$src" ]; then
      close_call_state "$path_owner"
      if [ "$CLOSE_CALL" != 3 ]; then
        close_conflict "$key" "$src" "$path_owner"
        continue
      fi
    fi
    close_consider sweep "$key" "$src" source
  done 7<<EOF
$CLOSE_SOURCES
EOF
  # Open pages in this home's task folders.
  while IFS=$'\t' read -r key status _ file <&7; do
    [ -n "$key" ] && [ "$status" = open ] || continue
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    [ "$file" != "$bearings" ] || continue
    path_owner=$(close_data_owner "$file")
    [ -n "$path_owner" ] || continue
    [ ! -e "$file" ] || close_task_page_seen "$path_owner" "$key" || continue
    seen+="$key"$'\n'
    close_consider sweep "$key" "$path_owner" path
  done 7<<EOF
$CLOSE_SESSIONS
EOF
  # Earlier close steps that failed are retried with the owner they recorded.
  for record in "$CLOSE_STATE_DIR"/*.failed; do
    [ -f "$record" ] || continue
    key=${record##*/}
    key=${key%.failed}
    case "$key" in *[!0-9a-f]*|'') continue ;; esac
    [ "${#key}" -eq 16 ] || continue
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen+="$key"$'\n'
    rec=$(close_record_read "$key" owner)
    fm_pr_task_id_valid "$rec" || continue
    close_consider sweep "$key" "$rec" record
  done
  return 0
}

case "${1-}" in
  close-task) shift; cmd_close_task "$@" ;;
  close-sweep) shift; cmd_close_sweep "$@" ;;
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  deliver-reply) shift; cmd_deliver_reply "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
