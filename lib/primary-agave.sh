# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Agave node adapter (incl. Jito-Agave). Sourced by lib/common.sh when PRIMARY_CLIENT=agave, and
# shipped to an Agave standby where standby/fds-node runs the same functions for the standby.
# Same functions and contracts as lib/primary-firedancer.sh (see the list at its top).
#
# Verified against agave-validator 4.4.0 (Jito, src:3a8c7fc3) --help and source:
#  - `agave-validator --ledger L set-identity [--require-tower] [--do-not-require-vote-history] [KEYPAIR]`
#    (keypair from stdin when no path is given). There is NO --vote-history-file: the validator
#    loads L/vote_history-<identity>.bin (FileVoteHistoryStorage on the ledger path, not --tower).
#    By default (we never pass --do-not-require-vote-history) the admin RPC refuses a switch to an
#    identity that is the vote account's node when that file is missing or does not parse, BEFORE
#    changing anything. A switch to a junk key never needs a file.
#  - The admin RPC call returns once the network layer runs on the new key, but votor applies the
#    new identity asynchronously (VotorEvent::SetIdentity). Votor can therefore still write votes
#    as the staked identity shortly after contact-info already reports junk: the vote history is
#    only "fresh" once it has stopped changing (p_vh_fresh).
#  - Agave writes vote_history-<pk>.bin in place (via .bin.new + rename); no .bak.
#  - votor votes only if the identity is the vote account's node (else "HotSpare") AND an
#    authorized voter keypair matches the vote account's BLS key. A node started with
#    --identity <junk> therefore never votes, and the staked key is added as authorized voter at
#    runtime (`authorized-voter add`, from stdin) before the switch to the staked key.
#  - `wait-for-restart-window --min-idle-time` is in MINUTES; it also requires delinquent stake
#    <= 5 % and a healthy node.
#  - The admin socket L/admin.rpc is 0600, owned by the validator user, and the agave-validator
#    CLI drops root's privileges at start: run as root, connect() fails with EACCES (seen on
#    v4.4.0-jito). Every client call therefore runs as the socket's owner (setpriv, no PAM
#    session), with timeout INSIDE so a KILL hits the client itself.
# Keypairs are passed to the client on stdin, opened by this (root) process: neither the client
# nor the validator needs to read the root-only staked key file.

p_load_config(){
  : "${AGAVE_BIN:?set AGAVE_BIN in $FDS_CONF}" "${AGAVE_LEDGER:?set AGAVE_LEDGER in $FDS_CONF}" "${AGAVE_JUNK_KEY:?set AGAVE_JUNK_KEY in $FDS_CONF}"
  AGAVE_KEYGEN=${AGAVE_KEYGEN:-$(dirname "$AGAVE_BIN")/solana-keygen}
  AGAVE_RPC_URL=${AGAVE_RPC_URL:-http://127.0.0.1:8899}
  AGAVE_MIN_IDLE_MIN=${AGAVE_MIN_IDLE_MIN:-2}
  AGAVE_VH_QUIET_S=${AGAVE_VH_QUIET_S:-0}
  AGAVE_VH_SLACK_S=${AGAVE_VH_SLACK_S:-30}
  [[ "$AGAVE_MIN_IDLE_MIN" =~ ^[0-9]+$ && "$AGAVE_VH_QUIET_S" =~ ^[0-9]+$ && "$AGAVE_VH_SLACK_S" =~ ^[0-9]+$ ]] \
    || { echo "AGAVE_MIN_IDLE_MIN / AGAVE_VH_QUIET_S / AGAVE_VH_SLACK_S must be integers" >&2; exit 2; }
  P_JUNK_KEY=$AGAVE_JUNK_KEY
  P_VH_DIR=$AGAVE_LEDGER
  # owner of the admin socket (= the validator user); the ledger dir if the validator is down
  P_OWNER=$(stat -c %U "$AGAVE_LEDGER/admin.rpc" 2>/dev/null || stat -c %U "$AGAVE_LEDGER" 2>/dev/null)
  P_GROUP=$(id -gn "$P_OWNER" 2>/dev/null)
  [[ "$P_OWNER" =~ ^[a-z_][a-z0-9_-]*$ && -n "$P_GROUP" ]] || { echo "cannot determine the owner of $AGAVE_LEDGER" >&2; exit 2; }
  P_VH_FILE=vote_history-$STAKED_PUBKEY.bin
}

# avc SECONDS ARGS...: agave-validator --ledger L ARGS as the validator user, killed after SECONDS
avc(){ local t=$1; shift
  if [ "$(id -u)" = 0 ]; then
    (cd /tmp && setpriv --reuid="$P_OWNER" --regid="$P_GROUP" --init-groups -- timeout -s KILL "$t" "$AGAVE_BIN" --ledger "$AGAVE_LEDGER" "$@" 9>&- 3<&-)
  else (cd /tmp && timeout -s KILL "$t" "$AGAVE_BIN" --ledger "$AGAVE_LEDGER" "$@" 9>&- 3<&-); fi; }

# contact-info goes over the admin socket (no RPC, nothing remote) and reports cluster_info's id,
# which set-identity changes. Must exit 0 and contain exactly one valid "id"; anything else = unknown.
p_id(){ local out
  out=$(avc 20 contact-info --output json </dev/null 2>/dev/null) || return 0
  printf '%s' "$out" | python3 -I -c 'import json, re, sys
i = json.load(sys.stdin).get("id", "")
if isinstance(i, str) and re.fullmatch(r"[1-9A-HJ-NP-Za-km-z]{32,44}", i): print(i)' 2>/dev/null
  return 0; }
keypub_local(){ local k; k=$("$AGAVE_KEYGEN" pubkey "$1" </dev/null 2>/dev/null | tail -1 | tr -d '[:space:]')
  [[ "$k" =~ ^$B58$ ]] && echo "$k"; return 0; }

# staked key as authorized voter (stdin, root-only file). Harmless while the identity is junk
# (votor: HotSpare); idempotent. Lost on restart by design: a restarted node cannot vote.
p_prepare_staked(){ local out rc
  out=$(avc "$SETID_TIMEOUT" authorized-voter add < "$PRIMARY_STAKED_KEY" 2>&1); rc=$?
  ((rc==0)) && return 0
  grep -q 'Authorized voter already present' <<<"$out" && return 0
  printf '%s\n' "$out" >&2; return "$rc"; }

p_unprepare_staked(){ avc "$SETID_TIMEOUT" authorized-voter remove-all </dev/null >/dev/null 2>&1; }

# rc 0 = switched; P_SETID_REFUSED = the validator answered that it cannot load the vote history
# and changed nothing (checked before any state change in set_identity_keypair); any other rc =
# may still complete (killed / timeout / socket error).
P_SETID_REFUSED=3
p_setid(){ local vh="" key pk dst out rc
  if [ "${1:-}" = --vote-history-file ]; then vh=$2; shift 2; fi
  key=${1:?key}
  if [ -n "$vh" ]; then   # Agave has no --vote-history-file: put the file where it loads it from
    # failures before set-identity runs change nothing in the validator: report them as refused
    pk=$(keypub_local "$key"); [[ "$pk" =~ ^$B58$ ]] || { echo "cannot read the pubkey of $key" >&2; return $P_SETID_REFUSED; }
    dst=$AGAVE_LEDGER/vote_history-$pk.bin
    if [ "$(readlink -f "$vh")" != "$(readlink -f "$dst")" ]; then
      [ -s "$vh" ] || { echo "vote history $vh missing/empty" >&2; return $P_SETID_REFUSED; }
      if [ -e "$dst" ]; then cp -p "$dst" "$dst.fds-replaced" || return $P_SETID_REFUSED; fi   # keep what we replace
      { cp "$vh" "$dst.fds-tmp" && chown "$P_OWNER:$P_GROUP" "$dst.fds-tmp" && chmod 644 "$dst.fds-tmp" && mv -f "$dst.fds-tmp" "$dst" && cmp -s "$vh" "$dst"; } \
        || { echo "cannot install $vh as $dst" >&2; return $P_SETID_REFUSED; }
    fi
  fi
  out=$(avc "$SETID_TIMEOUT" set-identity < "$key" 2>&1); rc=$?
  printf '%s\n' "$out"
  if ((rc != 0)) && grep -q 'Unable to load vote history file for identity' <<<"$out"; then return $P_SETID_REFUSED; fi
  return $rc; }

# "[-]-ledger" never matches the shell running pkill/pgrep (see the Firedancer adapter)
p_no_setid(){ local pat; pat="[-]-ledger $(printf '%s' "$AGAVE_LEDGER" | sed 's/[][\\.*^$+?(){}|]/\\&/g') (set-identity|authorized-voter)"
  pkill -KILL -f -- "$pat" 2>/dev/null; sleep 1; ! pgrep -f -- "$pat" >/dev/null; }
# the validator is the one process LISTENING on L/admin.rpc (CLI calls only connect to it)
p_pid(){ local l; l=$(readlink -f "$AGAVE_LEDGER"); ss -Hxlpn 2>/dev/null | awk -v s="$l/admin.rpc" '{for(i=1;i<=NF;i++) if($i==s && match($0,/pid=[0-9]+/)){print substr($0,RSTART+4,RLENGTH-4); exit}}'; }
# local RPC, commitment finalized (comparable to Firedancer's replay_reset_slot)
p_slot(){ curl -s -m 3 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"finalized"}]}' "$AGAVE_RPC_URL" \
  | python3 -I -c 'import json, sys
r = json.load(sys.stdin)["result"]
if isinstance(r, int): print(r)' 2>/dev/null; }

# The staked history is written in place. Fresh = written by the staked voter up to the switch
# (mtime >= T - AGAVE_VH_SLACK_S) AND votor has logged "set-identity: from STAKED to ..." at/after T.
# That line is final: votor stores the history only on its event-loop thread
# (voting_utils.rs insert_vote_and_create_bls_message: write .bin.new + rename = atomic), and
# handle_set_identity (event_handler.rs) runs on that same thread, swaps vctx.vote_history to the
# new identity, THEN logs. After the line no write to the staked file can follow (Jito-Agave
# 4.4.0, 3a8c7fc3). AGAVE_VH_QUIET_S (default 0) adds an extra "unchanged for N s" wait.
p_vh_file(){ echo "$AGAVE_LEDGER/$P_VH_FILE"; }
p_vh_fp(){ stat -c '%i %s %y' "$(p_vh_file)" 2>/dev/null; }
p_vh_fresh(){ local f a b; f=$(p_vh_file)
  [ -s "$f" ] && [ "$(stat -c %Y "$f")" -ge $(($1 - AGAVE_VH_SLACK_S)) ] || return 1
  p_votor_left "$1" "$STAKED_PUBKEY" || return 1
  ((AGAVE_VH_QUIET_S > 0)) || return 0
  a=$(p_vh_fp); sleep "$AGAVE_VH_QUIET_S"; b=$(p_vh_fp); [ -n "$a" ] && [ "$a" = "$b" ]; }
# --log file of the running validator ("" if none / stdout)
# AGAVE_LOG_FILE (set on standbys by the bundle) skips the lookup: p_pid walks every fd of every
# process (ss -p), ~1.6 s on a busy validator - far too slow inside a swap. p_log_cache keeps the
# result for the rest of THIS process (call it directly, not in $( ), so the cache survives).
p_log_cache(){ [ -n "${P_LOG_CACHE:-}" ] || P_LOG_CACHE=${AGAVE_LOG_FILE:-$(p_log_file)}; }
p_log_file(){ local pid; [ -n "${AGAVE_LOG_FILE:-}" ] && { echo "$AGAVE_LOG_FILE"; return 0; }
  pid=$(p_pid); [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  python3 -I - "$pid" <<'PY' 2>/dev/null
import os, sys
pid = sys.argv[1]
a = open(f'/proc/{pid}/cmdline', 'rb').read().decode().split('\0')
v = ''
for i, x in enumerate(a):
    if x in ('--log', '-o') and i + 1 < len(a): v = a[i + 1]
    elif x.startswith('--log='): v = x.split('=', 1)[1]
if v and v != '-':
    print(v if v.startswith('/') else os.path.join(os.readlink(f'/proc/{pid}/cwd'), v))
PY
}
# Votor applies set-identity asynchronously AFTER the admin call returns and logs it
# (votor/src/event_handler.rs handle_set_identity: warn "set-identity: from OLD to NEW"). Only
# after that line can no vote of OLD follow: positive proof, not a timer. $1 = T, $2 = OLD.
p_votor_left(){ local log; p_log_cache; log=$P_LOG_CACHE
  [ -n "$log" ] && [ -r "$log" ] || { echo "no readable --log file: cannot confirm votor switched" >&2; return 1; }
  tail -c 16000000 "$log" | grep -a -F "set-identity: from $2 to " | tail -1 | python3 -I -c '
import datetime, re, sys
# a validator started on a terminal writes colour codes into its log: strip them first
m = re.match(r"\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read()))
t = m and datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
sys.exit(0 if t and t >= int(sys.argv[1]) - 1 else 1)' "$1"; }
# epoch (float) of votor's last "set-identity: from FROM to TO" line (TO may be empty = any): the
# exact moment votor stopped/started voting as an identity (used to report the real voting gap)
p_votor_ts(){ local log; p_log_cache; log=$P_LOG_CACHE; [ -r "$log" ] || return 1
  # empty FROM/TO = any pubkey (base58: no regex metacharacters)
  tail -c 16000000 "$log" | grep -a -E "set-identity: from ${1:-[^ ]+} to ${2:-}" | tail -1 | python3 -I -c '
import datetime, re, sys
m = re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?)Z", re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read()))
if not m: sys.exit(1)
ts, frac = m.group(1).split(".") if "." in m.group(1) else (m.group(1), "0")
t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
print("%.3f" % (t + float("0." + frac)))'; }
p_vh_restore_file(){ p_vh_file; }   # still in place: p_setid loads it from there
p_vh_incoming(){ echo "$AGAVE_LEDGER/$P_VH_FILE.from-peer"; }
p_wait(){ avc 900 wait-for-restart-window --min-idle-time "$AGAVE_MIN_IDLE_MIN" --skip-new-snapshot-check </dev/null | tail -3; }
p_status_extra(){ echo "client=agave"; }
p_setid_hint(){ echo "setpriv --reuid=$P_OWNER --regid=$P_GROUP --init-groups -- $AGAVE_BIN --ledger $AGAVE_LEDGER set-identity < $1"; }

# 0 only if the running validator was started with the junk identity (a restart cannot vote)
p_start_ok(){ local f; f=$(p_start_identity "$(p_pid)"); [ -n "$f" ] && [ "$(keypub_local "$f")" = "$(keypub_local "$AGAVE_JUNK_KEY")" ]; }
# before renting: everything a swap of THIS primary will need (prints why not)
p_preflight(){ local lf; lf=$(p_log_file)
  p_start_ok || { echo "the validator was not started with the junk identity ($AGAVE_JUNK_KEY)"; return 1; }
  [ -n "$lf" ] && [ -r "$lf" ] || { echo "the validator has no readable --log file (${lf:-none}): swaps need it to confirm votor switched"; return 1; }; }
# identity keypair path the running validator was started with (--identity X / --identity=X / -i X)
p_start_identity(){ local pid=${1:-}; [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  python3 -I - "$pid" <<'PY' 2>/dev/null
import os, sys
pid = sys.argv[1]
a = open(f'/proc/{pid}/cmdline', 'rb').read().decode().split('\0')
v = ''
for i, x in enumerate(a):
    if x in ('--identity', '-i') and i + 1 < len(a): v = a[i + 1]
    elif x.startswith('--identity='): v = x.split('=', 1)[1]
if v: print(os.path.join(os.readlink(f'/proc/{pid}/cwd'), v))
PY
}

p_doctor(){
  local lf; lf=$(p_log_file)
  chk "validator --log file readable (${lf:-none}; swaps confirm votor's switch in it)" test -n "$lf" -a -r "${lf:-/nonexistent}"
  local pid sid
  slot_ok(){ [[ "$(p_slot)" =~ ^[0-9]+$ ]]; }
  start_junk(){ [ -n "$sid" ] && [ "$(keypub_local "$sid")" = "$(keypub_local "$P_JUNK_KEY")" ]; }
  chk "Agave binary runs ($AGAVE_BIN)" "$AGAVE_BIN" --version
  chk "solana-keygen runs ($AGAVE_KEYGEN)" "$AGAVE_KEYGEN" --version
  chk "ledger dir with admin socket ($AGAVE_LEDGER/admin.rpc)" test -S "$AGAVE_LEDGER/admin.rpc"
  chk "primary junk key exists ($P_JUNK_KEY)" test -s "$P_JUNK_KEY"
  chk "primary junk key is NOT the staked key" not_staked "$P_JUNK_KEY"
  chk "staked key present, root 0600, matches STAKED_PUBKEY" staked_ok "$PRIMARY_STAKED_KEY"
  chk "Agave on this primary answers contact-info" test -n "$(p_id)"
  echo "  info running identity: $(p_id)  (staked: $STAKED_PUBKEY)"
  pid=$(p_pid); sid=$(p_start_identity "$pid")
  chk "validator process found (listens on admin.rpc, pid ${pid:-?})" test -n "$pid"
  # invariant 1: a restart must come back unstaked
  chk "validator was started with the JUNK identity (--identity ${sid:-?})" start_junk
  chk "local RPC answers getSlot ($AGAVE_RPC_URL)" slot_ok
  chk "vote history dir exists ($P_VH_DIR)" test -d "$P_VH_DIR"
  echo "  info the start command is checked on the RUNNING process: make sure your start script/unit uses the same junk --identity"
}
