#!/usr/bin/env bash
# Shared stand-ins for the Lavish plan-page close tests
# (bin/fm-procevent-lavish.sh close-task and close-sweep).
#
# Source this after tests/lib.sh, then call fm_lavish_close_fakes <dir> to write
# a stand-in lavish-axi, curl, and osascript into <dir>. The stand-in Lavish
# keeps sessions in the same LAVISH_AXI_STATE_DIR/state.json shape the real CLI
# does (sessions keyed by the first 16 hex digits of the file's realpath
# digest, each with key, file, status, and url), so no real page, server, or
# browser tab is ever touched. Every stand-in appends what it was asked to do
# to $CLOSE_LOG:
#   open <key>                    lavish-axi <file>
#   end <key> <host>:<port>       lavish-axi end <file>, with the server it was pointed at
#   curl-end <key> <base-url>     POST <base-url>/api/<key>/end
#   tab /session/<key>            the Chrome tab close
# `lavish-axi poll <file>` blocks until $CLOSE_ROUNDS/<key> exists, then prints
# and consumes it, so a test controls exactly what a board's listener captures.
# Failure switches: CLOSE_END_FAIL=1, CLOSE_CURL_FAIL=1, CLOSE_CURL_BODY=<body>,
# CLOSE_TAB_FAIL=1.
set -u

if [ -n "${FM_LAVISH_CLOSE_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_LAVISH_CLOSE_HELPERS_SOURCED=1

fm_lavish_close_fakes() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/close-store" <<'PERL'
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP; use Cwd qw(realpath); use Digest::SHA qw(sha256_hex);
my ($op, $arg) = @ARGV;
my $path = "$ENV{LAVISH_AXI_STATE_DIR}/state.json";
my $state = { sessions => {} };
if (-f $path) { open my $in, "<", $path or die; local $/; $state = decode_json(<$in>); }
my $save = sub { open my $out, ">", $path or die; print $out encode_json($state); };
my $enoent = "error: ENOENT: no such file or directory, realpath '" . ($arg // "") . "'\n";
if ($op eq "open") {
  my $real = realpath($arg) // die $enoent;
  -f $real or die $enoent;
  my $key = substr(sha256_hex($real), 0, 16);
  my $url = "http://127.0.0.1:14399/session/$key";
  $state->{sessions}{$key} = { key => $key, file => $real, status => "open", url => $url };
  $save->();
  print "session:\n  url: $url\n  status: opened\n";
} elsif ($op eq "end-file") {
  my $real = realpath($arg) // die $enoent;
  -f $real or die $enoent;
  my $key = substr(sha256_hex($real), 0, 16);
  $state->{sessions}{$key} or die "error: No active Lavish Editor session\n";
  $state->{sessions}{$key}{status} = "ended";
  $state->{sessions}{$key}{ended_by} = "agent";
  $save->();
  print "session:\n  file: $real\n  status: ended\n";
} elsif ($op eq "end-key") {
  $state->{sessions}{$arg} or die "not found\n";
  $state->{sessions}{$arg}{status} = "ended";
  $state->{sessions}{$arg}{ended_by} = "user";
  $save->();
  print "{\"status\":\"ended\"}\n";
} elsif ($op eq "status") {
  print(($state->{sessions}{$arg} || {})->{status} // "absent", "\n");
}
PERL
  cat > "$dir/lavish-axi" <<'SH'
#!/usr/bin/env bash
store="$(dirname "$0")/close-store"
key_of() { perl -MCwd=realpath -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex(realpath($ARGV[0])), 0, 16)' "$1"; }
case "${1-}" in
  --version) printf '0.1.98\n' ;;
  poll)
    key=$(key_of "$2")
    while [ ! -e "$CLOSE_ROUNDS/$key" ]; do
      [ "$SECONDS" -lt 120 ] || exit 75
      sleep 0.05
    done
    cat "$CLOSE_ROUNDS/$key"
    rm -f "$CLOSE_ROUNDS/$key"
    ;;
  end)
    if [ "${CLOSE_END_FAIL:-0}" = 1 ]; then
      printf 'error: Lavish Editor end failed\ncode: SERVER_ERROR\n'
      exit 1
    fi
    "$store" end-file "$2" || exit 1
    printf 'end %s %s:%s\n' "$(key_of "$2")" "${LAVISH_AXI_HOST-}" "${LAVISH_AXI_PORT-}" >> "$CLOSE_LOG"
    ;;
  reply|stop) ;;
  *)
    "$store" open "$1" || exit 1
    printf 'open %s\n' "$(key_of "$1")" >> "$CLOSE_LOG"
    ;;
esac
SH
  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
url=
for arg in "$@"; do case "$arg" in http://*) url=$arg ;; esac; done
key=${url#*/api/}; key=${key%/end}
if [ "${CLOSE_CURL_FAIL:-0}" = 1 ]; then
  printf 'curl: (7) Failed to connect\n' >&2
  exit 7
fi
if [ -n "${CLOSE_CURL_BODY:-}" ]; then
  printf '%s\n' "$CLOSE_CURL_BODY"
  exit 0
fi
printf 'curl-end %s %s\n' "$key" "${url%%/api/*}" >> "$CLOSE_LOG"
"$(dirname "$0")/close-store" end-key "$key"
SH
  cat > "$dir/osascript" <<'SH'
#!/usr/bin/env bash
if [ "${CLOSE_TAB_FAIL:-0}" = 1 ]; then
  printf 'execution error: Not authorized to send Apple events to Google Chrome. (-1743)\n' >&2
  exit 1
fi
eval "needle=\${$#}"
printf 'tab %s\n' "$needle" >> "$CLOSE_LOG"
printf '1\n'
SH
  chmod +x "$dir/close-store" "$dir/lavish-axi" "$dir/curl" "$dir/osascript"
}

# The session key Lavish derives for a page file.
fm_lavish_close_key() {  # <file>
  perl -MCwd=realpath -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex(realpath($ARGV[0])), 0, 16)' "$1"
}

# A page's session status in a store: open, ended, or absent.
fm_lavish_close_status() {  # <store-dir> <key> <fakes-dir>
  LAVISH_AXI_STATE_DIR="$1" "$3/close-store" status "$2"
}

# Captured rounds a stand-in listener can deliver.
# shellcheck disable=SC2034  # Read by the sourcing suites.
FM_LAVISH_CLOSE_WORDS_ROUND='session:
  file: /board.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","please widen the second column",h1,h1,"Plan"'
# shellcheck disable=SC2034  # Read by the sourcing suites.
FM_LAVISH_CLOSE_FAILURE_ROUND='session:
  file: /board.html
  status: feedback
prompts: []
artifact_failures[1]{kind,detail,severity}:
  artifact-unavailable,the artifact document responded with HTTP 500,fatal'
