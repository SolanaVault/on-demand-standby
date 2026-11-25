# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Standby adapter: Agave on the rented server (STANDBY_CLIENT=agave, needs PRIMARY_CLIENT=agave).
# Same functions as lib/standby-firedancer.sh (contract list at its top).
#
# The standby runs the primary's OWN agave-validator build with the primary's OWN command line,
# minus everything host-specific (identity, vote account keypair, paths, public addresses, ports),
# plus the standby layout. Every node operation on the standby goes through `fds-node`
# (standby/fds-node), which runs the SAME functions as the primary adapter (lib/primary-agave.sh):
# one implementation of set-identity / vote-history / freshness for both ends.

S_AGAVE_DIR=/opt/agave
S_NODE=/usr/local/sbin/fds-node

s_load_config(){
  [ "$PRIMARY_CLIENT" = agave ] || { echo "STANDBY_CLIENT=agave needs PRIMARY_CLIENT=agave (it ships the primary's agave build)" >&2; exit 2; }
  : "${VOTE_PUBKEY:?set VOTE_PUBKEY in $FDS_CONF (the Agave standby is started with --vote-account <pubkey>)}"
  [[ "$VOTE_PUBKEY" =~ ^$B58$ ]] || { echo "VOTE_PUBKEY is not a base58 pubkey" >&2; exit 2; }
  S_USER=${STANDBY_AGAVE_USER:-sol}
  S_NAME=agave
  S_PORT_RANGE=${STANDBY_AGAVE_PORT_RANGE:-8000-8100}
  S_RPC_PORT=8899
  S_MIN_RAM_GIB=${STANDBY_MIN_RAM_GIB:-360}
  [[ "$S_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "bad STANDBY_AGAVE_USER" >&2; exit 2; }
  [[ "$S_PORT_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] && (( BASH_REMATCH[2] - BASH_REMATCH[1] >= 26 && BASH_REMATCH[2] < 65536 )) \
    || { echo "STANDBY_AGAVE_PORT_RANGE must be MIN-MAX, at least 26 ports wide" >&2; exit 2; }
  [[ "$S_MIN_RAM_GIB" =~ ^[0-9]+$ ]] || { echo "STANDBY_MIN_RAM_GIB must be an integer" >&2; exit 2; }
  S_BASE=$S_LED_MNT/$S_NAME
  S_VH_DIR=$S_BASE
  S_LOG=$S_BASE/agave-validator.log
  S_JUNK_KEY=/home/$S_USER/standby-identity.json
  S_UNIT=agave-validator
  S_METRICS_PORT=""
  S_SETID_REFUSED=3      # fds-node setid: the validator refused (vote history unloadable), nothing changed
}

s_id(){ _last_pubkey sshs "$1" "$S_NODE id"; }
keypub_remote(){ sshs "$1" "$S_NODE pubkey $(printf %q "$2")" | tail -1; }
s_slot(){ sshs "$1" "$S_NODE slot" </dev/null; }
s_status_extra(){ local c
  c=$(sshs "$1" 'for f in /etc/agave/companions/*.args; do [ -f "$f" ] || continue; n=$(basename "$f" .args); printf "%s=%s " "$n" "$(systemctl is-active "agave-companion@$n")"; done' </dev/null 2>/dev/null)
  echo "client=agave${c:+ ${c% }}"; }
# caught up = finalized slot within SWAP_MAX_LAG of the public cluster (SINCE: the restart is
# synchronous, so any answer after it comes from the new process)
s_caught_up(){ local l; l=$(lag_of "$(s_slot "$1")"); [ "$l" -le "$SWAP_MAX_LAG" ]; }
s_setid_cmd(){ local a="" x; for x in "$@"; do a+=" $(printf %q "$x")"; done; echo "$S_NODE setid$a"; }
s_prepare_cmd(){ echo "$S_NODE prepare"; }
s_unprepare_cmd(){ echo "$S_NODE unprepare"; }
s_no_setid_cmd(){ echo "$S_NODE no-setid"; }
s_vh_file(){ echo "$S_BASE/vote_history-$STAKED_PUBKEY.bin"; }
s_vh_fresh_cmd(){ echo "$S_NODE vh-fresh $1"; }
s_vh_fp_cmd(){ echo "$S_NODE vh-fp"; }
s_vh_restore_cmd(){ echo "$S_NODE vh-file"; }      # still in place: setid loads it from there
s_vh_incoming(){ echo "$S_BASE/vote_history-$STAKED_PUBKEY.bin.from-peer"; }
s_wait_cmd(){ echo "$S_NODE wait"; }
s_keys_new_cmd(){ local f; f=$(printf %q "$1")
  echo "test -f $f || (t=\$(mktemp) && $S_AGAVE_DIR/active/solana-keygen new --no-bip39-passphrase --silent --force -o \"\$t\" >/dev/null && install -m 600 -o $S_USER -g $S_USER \"\$t\" $f; shred -u \"\$t\")"; }
# reset-failed: earlier failed starts count against StartLimitBurst and would refuse this one
s_cold_restart_cmd(){ echo "systemctl reset-failed $S_UNIT 2>/dev/null; systemctl restart $S_UNIT"; }

# The primary's running command line, made host-independent. Fails (prints why) on anything it
# cannot place: an unknown flag with a path value, or a value containing this primary's IP.
#   s_agave_args            the validator (argv of p_pid)
#   s_agave_args PID NAME   a companion process (see s_agave_companions)
s_agave_args(){ local pid=${1:-} name=${2:-}
  [ -n "$pid" ] || pid=$(p_pid)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "the primary validator is not running (its command line is the standby's template)" >&2; return 1; }
  python3 -I - "$pid" "$name" "$(primary_ip)" "${STANDBY_DROP_MULTICAST:-1}" "${STANDBY_AGAVE_DROP_ARGS:-}" "${STANDBY_AGAVE_EXTRA_ARGS:-}" \
      "$S_JUNK_KEY" "$VOTE_PUBKEY" "$S_BASE" "$S_ACC_MNT" "$S_LOG" "$S_RPC_PORT" "$S_PORT_RANGE" "$(readlink -f "$AGAVE_LEDGER")" <<'PY'
import os, sys
pid, name, pip, dropmc, extra_drop, extra_args, junk, vote, ledger, accounts, log, rpc_port, prange, pledger = sys.argv[1:]
argv = open(f'/proc/{pid}/cmdline', 'rb').read().decode().split('\0')
if argv and argv[-1] == '': argv.pop()
args = argv[1:]
if not name and args[:1] == ['run']: args = args[1:]
# set by fd-standby (standby layout / junk identity), or meaningless on another host
DROP = {'--identity', '-i', '--vote-account', '--authorized-voter', '--ledger', '-l', '--accounts',
        '--accounts-index-path', '--accounts-hash-cache-path', '--snapshots', '--full-snapshot-archive-path',
        '--incremental-snapshot-archive-path', '--tower', '--log', '-o', '--rpc-bind-address', '--rpc-port',
        '--dynamic-port-range', '--public-rpc-address', '--public-tpu-address', '--public-tpu-forwards-address',
        '--public-tvu-address', '--gossip-host', '--bind-address', '--gossip-port', '--no-snapshot-fetch',
        '--init-complete-file', '--geyser-plugin-config', '--wait-for-supermajority', '--expected-bank-hash',
        '--require-tower'}
if name:                          # companion: only its ledger and log are re-pointed
    DROP = {'--ledger', '-l', '--log'}
DROP |= set(extra_drop.split())
groups = []                       # [flag, [values]]
for a in args:
    if a.startswith('-') and not a.lstrip('-').isdigit():
        if a.startswith('--') and '=' in a:
            k, v = a.split('=', 1); groups.append([k, [v]])
        else: groups.append([a, []])
    elif groups: groups[-1][1].append(a)
    else: sys.exit(f'cannot parse the primary command line{" of " + name if name else ""} near {a!r}')
def multicast(v):
    try: return 224 <= int(v.split(':')[0].split('.')[0]) <= 239
    except ValueError: return False
out, bad, had = [], [], set()
for k, vals in groups:
    had.add(k)
    if name and k in ('--ledger', '-l') and vals and os.path.realpath(vals[0]) != pledger:
        bad.append(f'{k} {vals[0]} (not the validator ledger)')
    if k in DROP: continue
    if k == '--shred-receiver-address' and dropmc == '1' and vals and multicast(vals[0]): continue
    for v in vals:
        if v.startswith('/') or v.startswith('~'): bad.append(f'{k} {v} (path on the primary)')
        if pip and pip in v: bad.append(f'{k} {v} (this primary\'s IP)')
    out += [k] + vals
if bad:
    sys.exit(f'cannot derive the standby command line{" of " + name if name else ""}, unhandled: ' + '; '.join(bad) +
             ' -> add the flag to STANDBY_AGAVE_DROP_ARGS if the standby does not need it')
if name:
    out += ['--ledger', ledger] + (['--log', f'{ledger}/{name}.log'] if '--log' in had else [])
else:
    out += extra_args.split()     # e.g. a flag the standby needs and the primary does not have
    out += ['--identity', junk, '--vote-account', vote, '--ledger', ledger, '--accounts', accounts,
            '--log', log, '--rpc-bind-address', '127.0.0.1', '--rpc-port', rpc_port, '--dynamic-port-range', prange]
for x in out:
    if '\n' in x: sys.exit('newline in an argument')
    print(x)
PY
}

# Companion processes: other programs the primary runs against the same ledger (e.g. Harmonic's
# harmonic-scheduler next to Salsa 4.x). The standby runs them too, same binary, same arguments.
# Prints "PID NAME" lines. STANDBY_AGAVE_COMPANIONS: auto (default) | none | names to keep.
s_agave_companions(){ local vpid; vpid=$(p_pid)
  [ "${STANDBY_AGAVE_COMPANIONS:-auto}" = none ] && return 0
  python3 -I - "$vpid" "$(readlink -f "$AGAVE_LEDGER")" "${STANDBY_AGAVE_COMPANIONS:-auto}" <<'PY'
import os, re, sys
vpid, ledger, want = sys.argv[1], sys.argv[2], sys.argv[3].split()
seen = set()
for p in sorted((d for d in os.listdir('/proc') if d.isdigit()), key=int):
    if p == vpid: continue
    try:
        argv = open(f'/proc/{p}/cmdline', 'rb').read().decode().split('\0')
        exe = os.path.basename(os.readlink(f'/proc/{p}/exe'))
    except OSError: continue
    # not the validator's own CLI (also behind wrappers such as timeout / setpriv / sudo)
    if any(os.path.basename(a) in ('agave-validator', 'solana-validator', 'agave-ledger-tool') for a in argv): continue
    if exe in ('timeout', 'setpriv', 'sudo', 'env', 'nice', 'taskset', 'numactl', 'stdbuf', 'solana') or exe.startswith(('solana-', 'python', 'bash', 'sh', 'dash', 'zsh')): continue
    l = None
    for i, a in enumerate(argv):
        if a in ('--ledger', '-l') and i + 1 < len(argv): l = argv[i + 1]
        elif a.startswith('--ledger='): l = a.split('=', 1)[1]
    if not l or os.path.realpath(l) != ledger: continue
    name = re.sub(r'[^A-Za-z0-9_.-]', '_', exe)
    if name in seen or (want != ['auto'] and name not in want): continue
    seen.add(name); print(p, name)
PY
}

# Snapshot sources. STANDBY_SNAPSHOT_SOURCES: gossip identities of trusted snapshot servers
# (default: snappie.sh). Their current RPC address is looked up in gossip at bundle time, and the
# standby downloads from there before its first start; STANDBY_SNAPSHOT_URLS adds fixed URLs.
SNAPPIE=snappieAMus13pmFwd8aDPKDHTTVYWo6y41zSpasU8L
s_snapshot_sources(){ echo "${STANDBY_SNAPSHOT_SOURCES-$SNAPPIE}"; }
s_snapshot_urls(){ local srcs nodes
  [ -z "${STANDBY_SNAPSHOT_URLS:-}" ] || printf '%s\n' $STANDBY_SNAPSHOT_URLS
  srcs=$(s_snapshot_sources); [ -n "$srcs" ] || return 0
  nodes=$(curl -s -m 10 -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getClusterNodes"}' "$AGAVE_RPC_URL" \
          | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["result"]))' 2>/dev/null) || nodes=""
  [ -n "$nodes" ] || nodes=$(rpc_call getClusterNodes)
  printf '%s' "$nodes" | python3 -I -c 'import json,sys
d = sys.stdin.read()
nodes = {n["pubkey"]: n for n in json.loads(d or "[]")}
for pk in sys.argv[1].split():
    rpc = (nodes.get(pk) or {}).get("rpc")
    if rpc: print("http://" + rpc)
    else: print(f"snapshot source {pk}: no RPC address in gossip (skipped)", file=sys.stderr)' "$srcs"
}
# The primary trusts a fixed set of snapshot publishers (--known-validator): the standby also
# trusts the snapshot sources. Without --known-validator the primary accepts any: nothing added.
s_agave_snapshot_args(){ local pk args; args=$(s_agave_args) || return 1
  grep -qx -- --known-validator <<<"$args" || return 0
  for pk in $(s_snapshot_sources); do
    [[ "$pk" =~ ^$B58$ ]] || { echo "STANDBY_SNAPSHOT_SOURCES: $pk is not a pubkey" >&2; return 1; }
    grep -qxF -- "$pk" <<<"$args" || printf -- '--known-validator\n%s\n' "$pk"
  done
}

# the file capabilities of a binary as `setcap` takes them ("cap_a,cap_b=p"), empty if none
s_filecaps(){ local out
  command -v getcap >/dev/null || { echo "getcap missing (package libcap2-bin): cannot read the file capabilities of $1" >&2; return 1; }
  out=$(getcap "$(readlink -f "$1")" 2>/dev/null) || { echo "getcap $1 failed" >&2; return 1; }
  [ -n "$out" ] && echo "${out##* }"; return 0; }
s_bundle(){ local d=$1 bindir ver rel glibc
  bindir=$(dirname "$(readlink -f "$AGAVE_BIN")")
  ver=$("$AGAVE_BIN" --version 2>/dev/null | head -1)
  [ -n "$ver" ] || { echo "cannot run $AGAVE_BIN --version" >&2; return 1; }
  rel=$(python3 -I -c 'import re,sys
v=sys.argv[1]; m=re.search(r"(\d+\.\d+\.\d+)",v); s=re.search(r"src:([0-9a-f]+)",v)
print("agave-%s-%s" % (m.group(1) if m else "x", s.group(1) if s else "x"))' "$ver")
  local pid; pid=$(p_pid)
  cmp -s "/proc/$pid/exe" "$bindir/agave-validator" || { echo "$bindir/agave-validator is not the binary the validator runs (/proc/$pid/exe): set AGAVE_BIN to the running build" >&2; return 1; }
  install -m 755 "$bindir/agave-validator" "$d/bin/agave-validator"
  # file capabilities (setcap) do not survive a copy: record them, the standby sets the same ones.
  # Agave 4.x refuses to start without e.g. CAP_NET_ADMIN/CAP_NET_RAW when its config needs them.
  s_filecaps "$bindir/agave-validator" > "$d/bin/agave-validator.caps" || return 1
  install -m 755 "$bindir/solana-keygen" "$d/bin/solana-keygen"
  echo "$rel" > "$d/bin/release"; echo "$ver" > "$d/bin/version"
  glibc=$(objdump -T "$d/bin/agave-validator" "$d/bin/solana-keygen" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
  s_agave_args > "$d/config/agave.args" || return 1
  s_agave_snapshot_args >> "$d/config/agave.args" || return 1
  local cp cn
  mkdir -p "$d/bin/companions" "$d/config/companions"
  while read -r cp cn; do
    [ -n "$cn" ] || continue
    install -m 755 "/proc/$cp/exe" "$d/bin/companions/$cn" || { echo "cannot copy the binary of companion $cn (pid $cp)" >&2; return 1; }
    s_filecaps "/proc/$cp/exe" > "$d/bin/companions/$cn.caps" || return 1
    s_agave_args "$cp" "$cn" > "$d/config/companions/$cn.args" || return 1
    echo "companion: $cn ($(wc -l < "$d/config/companions/$cn.args") args)" >&2
  done < <(s_agave_companions)
  s_snapshot_urls > "$d/config/snapshot-urls"
  mkdir -p "$d/node"
  install -m 755 "$FDS_ROOT/standby/fds-node" "$d/node/fds-node"
  install -m 644 "$FDS_ROOT/lib/primary-agave.sh" "$d/node/primary-agave.sh"
  { printf 'STAKED_PUBKEY=%q\nPRIMARY_STAKED_KEY=%q\n' "$STAKED_PUBKEY" "$S_STAKED_KEY"
    printf 'AGAVE_BIN=%q\nAGAVE_KEYGEN=%q\n' "$S_AGAVE_DIR/active/agave-validator" "$S_AGAVE_DIR/active/solana-keygen"
    printf 'AGAVE_LEDGER=%q\nAGAVE_JUNK_KEY=%q\nAGAVE_RPC_URL=%q\n' "$S_BASE" "$S_JUNK_KEY" "http://127.0.0.1:$S_RPC_PORT"
    printf 'AGAVE_MIN_IDLE_MIN=%q\nAGAVE_VH_QUIET_S=%q\nAGAVE_VH_SLACK_S=%q\nSETID_TIMEOUT=%q\n' \
      "$AGAVE_MIN_IDLE_MIN" "$AGAVE_VH_QUIET_S" "$AGAVE_VH_SLACK_S" "$SETID_TIMEOUT"
    # the standby's --log is fixed by the bundle: fds-node need not look it up (~1.6 s per call)
    printf 'AGAVE_LOG_FILE=%q\n' "$S_LOG"; } > "$d/node/node.env"
  sed "s#@PORT_RANGE@#$S_PORT_RANGE#g" "$FDS_ROOT/standby/standby-agave.nft.in" > "$d/standby.nft.in"
  cp "$FDS_ROOT/standby/units/agave-validator.service" "$FDS_ROOT/standby/units/agave-companion@.service" "$d/units/"
  cp "$FDS_ROOT/standby/60-agave.conf" "$d/"
  printf 'MIN_RAM_GIB=%q\nREQ_FLAGS=%q\nMIN_GLIBC=%q\nRPC_PORT=%q\n' "$S_MIN_RAM_GIB" "avx avx2 sse4_2 popcnt" "${glibc#GLIBC_}" "$S_RPC_PORT" >> "$d/config/standby.env"
  echo "$rel $(sha256sum "$d/bin/agave-validator" | cut -c1-12)"
}

s_doctor(){
  local args
  chk "VOTE_PUBKEY set (standby --vote-account)" test -n "$VOTE_PUBKEY"
  chk "solana-keygen next to agave-validator ($(dirname "$(readlink -f "$AGAVE_BIN")")/solana-keygen)" test -x "$(dirname "$(readlink -f "$AGAVE_BIN")")/solana-keygen"
  if args=$(s_agave_args 2>&1); then
    printf '  ok   standby command line derived from the running primary (%s args)\n' "$(wc -l <<<"$args")"
    printf '         %s\n' "$(tr '\n' ' ' <<<"$args" | fold -w 110 -s | sed '2,$s/^/         /')"
  else printf '  FAIL standby command line: %s\n' "$args"; bad=1; fi
  local cp cn ca n=0 t u
  while read -r cp cn; do
    [ -n "$cn" ] || continue; n=$((n+1))
    if ca=$(s_agave_args "$cp" "$cn" 2>&1); then printf '  ok   companion %s (pid %s) runs on the standby too: %s\n' "$cn" "$cp" "$(tr '\n' ' ' <<<"$ca" | cut -c1-90)"
    else printf '  FAIL companion %s: %s\n' "$cn" "$ca"; bad=1; fi
  done < <(s_agave_companions)
  [ $n -gt 0 ] || echo "  info no companion processes next to the validator (e.g. harmonic-scheduler)"
  t=$(mktemp); s_agave_args > "$t" 2>/dev/null
  echo "  info regional endpoints (the standby picks the closest region per provider):"
  { endpoints_plan args "$t" 2>&1 || true; } | sed 's/^/         /'; rm -f "$t"
  local urls e; e=$(mktemp); urls=$(s_snapshot_urls 2>"$e")
  [ -n "$(s_snapshot_sources)" ] && chk "snapshot sources have an RPC address in gossip ($(s_snapshot_sources))" test ! -s "$e"
  sed 's/^/         /' "$e"; rm -f "$e"
  for u in $urls; do
    chk "snapshot source answers ($u)" sh -c 'curl -s -m 10 -o /dev/null -w "%{redirect_url}" "$1/snapshot.tar.bz2" | grep -q snapshot-' _ "$u"
  done
  [ -n "$urls" ] || echo "  info no snapshot source: the standby fetches its snapshot itself (per the primary's --known-validator / --only-known-rpc)"
}
