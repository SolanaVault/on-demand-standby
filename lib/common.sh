# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared helpers for fd-standby and fd-standby-swap. Sourced, not executed.

FDS_ROOT=${FDS_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}
FDS_CONF=${FDS_CONF:-/etc/fd-standby/fd-standby.conf}
FDS_STATE_DIR=${FDS_STATE_DIR:-/var/lib/fd-standby}
FDS_LOG=$FDS_STATE_DIR/fd-standby.log
FDS_STATE=$FDS_STATE_DIR/state.json
FDS_KNOWN_HOSTS=$FDS_STATE_DIR/known_hosts

# Fixed layout ON THE STANDBY (independent of the primary's paths).
S_FD_BIN=/opt/firedancer/bin/firedancer
S_FD_CFG=/etc/firedancer/standby.toml
S_ACC_MNT=/mnt/fd-accounts
S_LED_MNT=/mnt/fd-ledger
S_STAKED_KEY=/run/fd-standby/staked-identity.json   # tmpfs only: gone on reboot, never on disk

fds_load_config(){
  [ -r "$FDS_CONF" ] || { echo "missing $FDS_CONF (see config/fd-standby.conf.example)" >&2; exit 2; }
  # shellcheck disable=SC1090
  . "$FDS_CONF"
  : "${STAKED_PUBKEY:?set STAKED_PUBKEY in $FDS_CONF}" "${PRIMARY_FD_CONFIG:?}" "${PRIMARY_STAKED_KEY:?}" "${FD_BIN:?}"
  FD_UNIT=${FD_UNIT:-firedancer.service}
  SSH_KEY=${SSH_KEY:-/root/.ssh/id_ed25519_fd_standby}
  CANDIDATES_FILE=${CANDIDATES_FILE:-/etc/fd-standby/candidates.conf}
  MAX_PRICE_PER_HOUR=${MAX_PRICE_PER_HOUR:-3.0}; USD_TO_EUR=${USD_TO_EUR:-0.92}
  DELIVERY_MAX_S=${DELIVERY_MAX_S:-2700}; CATCHUP_MAX_S=${CATCHUP_MAX_S:-3600}; SWAP_MAX_LAG=${SWAP_MAX_LAG:-30}
  WATCHDOG_ALERT_AFTER_H=${WATCHDOG_ALERT_AFTER_H:-3}; WATCHDOG_DELETE_AFTER_H=${WATCHDOG_DELETE_AFTER_H:-6}
  PUBLIC_RPCS=${PUBLIC_RPCS:-https://api.mainnet-beta.solana.com}
  ALERT_CMD=${ALERT_CMD:-logger -t fd-standby}
  STANDBY_CONFIGURE_STAGES=${STANDBY_CONFIGURE_STAGES:-hugetlbfs sysctl irq-affinity irq-balance kworkers cpuset console snapshots}
  mkdir -p "$FDS_STATE_DIR"; chmod 700 "$FDS_STATE_DIR"
  [[ "$STAKED_PUBKEY" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || { echo "STAKED_PUBKEY is not a base58 pubkey" >&2; exit 2; }
  [[ "$SWAP_MAX_LAG" =~ ^[0-9]+$ && "$DELIVERY_MAX_S" =~ ^[0-9]+$ && "$CATCHUP_MAX_S" =~ ^[0-9]+$ ]] || { echo "numeric settings must be integers" >&2; exit 2; }
  fds_primary_info
  FDS_OWNER_TAG=fds-${STAKED_PUBKEY:0:12}   # provider tag: which validator a standby belongs to
  [[ "$P_METRICS_PORT" =~ ^[0-9]+$ ]] || { echo "bad prometheus port in $PRIMARY_FD_CONFIG" >&2; exit 2; }
  [[ "$P_NAME" =~ ^[A-Za-z0-9_.-]+$ && "${P_USER:-firedancer}" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "unsupported Firedancer name/user in $PRIMARY_FD_CONFIG" >&2; exit 2; }
}

valid_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# One mutating fd-standby operation at a time (maintain, up, down, qualify, swap, watchdog).
# fd-standby takes the lock and exports FDS_LOCK_HELD for the fd-standby-swap it calls.
fds_lock_or_exit(){
  [ "${FDS_LOCK_HELD:-0}" = 1 ] && return 0
  exec 9>"$FDS_STATE_DIR/lock"
  flock -n 9 || { echo "another fd-standby operation is running (lock $FDS_STATE_DIR/lock)" >&2; exit 75; }
  touch "$FDS_STATE_DIR/lock"; export FDS_LOCK_HELD=1
}

say(){ printf '[%s] %s\n' "$(date -u +%T)" "$*" | tee -a "$FDS_LOG" >&2; }
alert(){ say "ALERT: $*"; $ALERT_CMD "fd-standby: $*" >/dev/null 2>&1 || true; }
die(){ say "ABORT: $*"; alert "aborted: $*"; exit 1; }

# Read what we need from the primary's Firedancer TOML (python3 >= 3.11 for tomllib).
# Exports P_NAME P_USER P_BASE P_VH_DIR P_LOG P_JUNK_KEY P_METRICS_PORT
fds_primary_info(){
  local out
  out=$(python3 -I - "$PRIMARY_FD_CONFIG" <<'PY'
import sys, tomllib, shlex
c = tomllib.load(open(sys.argv[1], 'rb'))
name = c.get('name', 'fd1'); user = c.get('user', '')
p = c.get('paths', {})
base = p.get('base', '/home/{user}/.firedancer/{name}').replace('{name}', name).replace('{user}', user)
vh = p.get('vote_history', base).replace('{name}', name).replace('{user}', user)
log = c.get('log', {}).get('path', '').replace('{name}', name).replace('{user}', user) or base + '/firedancer.log'
port = c.get('tiles', {}).get('metric', {}).get('prometheus_listen_port', 7999)
for k, v in dict(P_NAME=name, P_USER=user, P_BASE=base, P_VH_DIR=vh, P_LOG=log,
                 P_JUNK_KEY=p.get('identity_key', ''), P_METRICS_PORT=port).items():
    print(f'{k}={shlex.quote(str(v))}')
PY
) || { echo "cannot parse $PRIMARY_FD_CONFIG" >&2; exit 2; }
  eval "$out"
  S_BASE=$S_LED_MNT/$P_NAME
  S_VH_DIR=$S_BASE
  S_LOG=$S_BASE/firedancer.log
  S_JUNK_KEY=/home/${P_USER:-firedancer}/standby-identity.json
}

primary_ip(){ ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

# --- SSH to the standby
# ServerAlive*: a silently dead link fails within ~15 s instead of blocking for hours.
# Providers reuse IP addresses, so host keys are pinned PER SERVER (provider+id from the state
# file), never per IP: the first login to a newly delivered server records its key, every later
# login to that same server must match it.
known_hosts_for(){ local h=$1
  if [ -s "$FDS_STATE" ] && [ "$(state_get ip)" = "$h" ]; then echo "$FDS_STATE_DIR/known_hosts.$(state_get provider)-$(state_get id)"
  else echo "$FDS_KNOWN_HOSTS"; fi; }
sshs(){ local h=$1; shift; ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$(known_hosts_for "$h")" "root@$h" "$@"; }

# --- public RPC
rpc_call(){  # method [params-json] -> result JSON on stdout, empty on failure
  local m=$1 p=${2:-[]} u r i
  for i in 1 2 3; do for u in $PUBLIC_RPCS; do
    r=$(curl -s -m 8 -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":$p}" "$u" \
        | python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin); print(json.dumps(d["result"]))
except Exception: pass' 2>/dev/null)
    [ -n "$r" ] && { echo "$r"; return 0; }; done; sleep 1; done; return 1; }
cluster_slot(){ rpc_call getSlot '[{"commitment":"processed"}]'; }
vote_state(){
  [ -n "${VOTE_PUBKEY:-}" ] || { echo "(VOTE_PUBKEY not set)"; return; }
  rpc_call getVoteAccounts "[{\"votePubkey\":\"$VOTE_PUBKEY\"}]" | python3 -I -c 'import json,sys
r=json.load(sys.stdin)
for k in ("current","delinquent"):
    for v in r[k]: print(k, v["nodePubkey"], v["lastVote"])' 2>/dev/null || echo "(rpc unavailable)"; }

# --- local / remote Firedancer
metric(){ awk -v m="$1" '$1 ~ "^"m {print $2; exit}'; }
p_metrics(){ curl -s -m 3 "127.0.0.1:$P_METRICS_PORT/metrics"; }
s_metrics(){ sshs "$1" "curl -s -m 3 127.0.0.1:$P_METRICS_PORT/metrics"; }
B58='[1-9A-HJ-NP-Za-km-z]{32,44}'
# get-identity must exit 0 and its LAST line must be exactly one base58 pubkey; anything else = "" (unknown)
_last_pubkey(){ local out rc; out=$("$@"); rc=$?; ((rc==0)) || return 0; out=$(printf '%s\n' "$out" | tail -1 | tr -d '[:space:]'); [[ "$out" =~ ^$B58$ ]] && echo "$out"; return 0; }
p_id(){ (cd /tmp && _last_pubkey timeout 20 "$FD_BIN" get-identity --config "$PRIMARY_FD_CONFIG" 2>/dev/null); }
s_id(){ _last_pubkey sshs "$1" "cd /tmp && timeout 20 $S_FD_BIN get-identity --config $S_FD_CFG 2>/dev/null"; }
keypub_local(){ (cd /tmp && "$FD_BIN" keys pubkey "$1" --config "$PRIMARY_FD_CONFIG" 2>/dev/null | tail -1); }
keypub_remote(){ sshs "$1" "cd /tmp && $S_FD_BIN keys pubkey $2 --config $S_FD_CFG 2>/dev/null" | tail -1; }
slot_of(){ local v; v=$(metric replay_reset_slot); echo "${v%.*}"; }

# lag = public cluster slot - local slot. 999999 = unknown (fails every check).
lag_of(){ local mine=$1 c
  c=$(cluster_slot) || { echo 999999; return; }     # no public reference = cannot prove "caught up"
  [[ "$mine" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] || { echo 999999; return; }
  local d=$((c-mine)); ((d<-50)) && d=999999; ((d<0)) && d=0; echo $d; }

state_get(){ [ -s "$FDS_STATE" ] && python3 -I -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$FDS_STATE" "$1"; }
state_put(){ python3 -I -c "import json,sys;json.dump(dict(zip(['provider','id','ip','plan','region','created'],sys.argv[2:])),open(sys.argv[1],'w'))" "$FDS_STATE" "$@"; }
