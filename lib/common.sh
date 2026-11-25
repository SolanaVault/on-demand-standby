# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared helpers for ods and ods-swap. Sourced, not executed.

ODS_ROOT=${ODS_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}
ODS_CONF=${ODS_CONF:-/etc/ods/ods.conf}
ODS_STATE_DIR=${ODS_STATE_DIR:-/var/lib/ods}
ODS_LOG=$ODS_STATE_DIR/ods.log
ODS_STATE=$ODS_STATE_DIR/state.json
ODS_KNOWN_HOSTS=$ODS_STATE_DIR/known_hosts

# Fixed layout ON THE STANDBY (independent of the primary's paths; client specifics in lib/standby-*.sh).
S_ACC_MNT=/mnt/ods-accounts
S_LED_MNT=/mnt/ods-ledger
S_STAKED_KEY=/run/ods/staked-identity.json   # tmpfs only: gone on reboot, never on disk

ods_load_config(){
  [ -r "$ODS_CONF" ] || { echo "missing $ODS_CONF (see config/ods.conf.example)" >&2; exit 2; }
  # shellcheck disable=SC1090
  . "$ODS_CONF"
  : "${STAKED_PUBKEY:?set STAKED_PUBKEY in $ODS_CONF}" "${PRIMARY_STAKED_KEY:?}"
  PRIMARY_CLIENT=${PRIMARY_CLIENT:-firedancer}
  case "$PRIMARY_CLIENT" in firedancer|agave) ;; *) echo "PRIMARY_CLIENT must be firedancer or agave" >&2; exit 2;; esac
  STANDBY_CLIENT=${STANDBY_CLIENT:-$PRIMARY_CLIENT}   # an Agave primary gets an Agave standby unless set
  case "$STANDBY_CLIENT" in firedancer|agave) ;; *) echo "STANDBY_CLIENT must be firedancer or agave" >&2; exit 2;; esac
  if [ -z "${CANDIDATES_FILE:-}" ]; then
    if [ "$STANDBY_CLIENT" = agave ]; then CANDIDATES_FILE=/etc/ods/candidates-agave.conf; else CANDIDATES_FILE=/etc/ods/candidates.conf; fi; fi
  SSH_KEY=${SSH_KEY:-/root/.ssh/id_ed25519_ods}
  # regional endpoint table (shipped with the code; set REGIONAL_ENDPOINTS to use your own copy)
  REGIONAL_ENDPOINTS=${REGIONAL_ENDPOINTS:-$ODS_ROOT/config/regional-endpoints.conf}
  [[ "${STANDBY_REGIONS:-}" =~ ^([a-z0-9_-]+=[A-Za-z0-9_-]+( +|$))*$ ]] || { echo "STANDBY_REGIONS must be 'provider=region ...'" >&2; exit 2; }
  MAX_PRICE_PER_HOUR=${MAX_PRICE_PER_HOUR:-3.0}; USD_TO_EUR=${USD_TO_EUR:-0.92}
  DELIVERY_MAX_S=${DELIVERY_MAX_S:-2700}; CATCHUP_MAX_S=${CATCHUP_MAX_S:-3600}; SETUP_MAX_S=${SETUP_MAX_S:-7200}; SWAP_MAX_LAG=${SWAP_MAX_LAG:-30}
  WATCHDOG_ALERT_AFTER_H=${WATCHDOG_ALERT_AFTER_H:-3}; WATCHDOG_DELETE_AFTER_H=${WATCHDOG_DELETE_AFTER_H:-6}
  PUBLIC_RPCS=${PUBLIC_RPCS:-https://api.mainnet-beta.solana.com}
  ALERT_CMD=${ALERT_CMD:-logger -t ods}
  STANDBY_CONFIGURE_STAGES=${STANDBY_CONFIGURE_STAGES:-hugetlbfs sysctl irq-affinity irq-balance kworkers cpuset console snapshots}
  mkdir -p "$ODS_STATE_DIR"; chmod 700 "$ODS_STATE_DIR"
  [[ "$STAKED_PUBKEY" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || { echo "STAKED_PUBKEY is not a base58 pubkey" >&2; exit 2; }
  [[ "$SWAP_MAX_LAG" =~ ^[0-9]+$ && "$DELIVERY_MAX_S" =~ ^[0-9]+$ && "$CATCHUP_MAX_S" =~ ^[0-9]+$ ]] || { echo "numeric settings must be integers" >&2; exit 2; }
  # shellcheck source=primary-firedancer.sh
  . "$ODS_ROOT/lib/primary-$PRIMARY_CLIENT.sh"
  p_load_config        # primary adapter: validates its settings, sets P_* (+ STANDBY_FD_* for a Firedancer primary)
  # shellcheck source=standby-firedancer.sh
  . "$ODS_ROOT/lib/standby-$STANDBY_CLIENT.sh"
  s_load_config        # standby adapter: S_* layout on the standby
  ODS_OWNER_TAG=ods-${STAKED_PUBKEY:0:12}   # provider tag: which validator a standby belongs to
}

valid_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# One mutating ods operation at a time (failover, failback, up, down, qualify, swap, watchdog).
# ods takes the lock and exports ODS_LOCK_HELD for the ods-swap it calls.
ods_lock_or_exit(){
  [ "${ODS_LOCK_HELD:-0}" = 1 ] && return 0
  exec 9>"$ODS_STATE_DIR/lock"
  flock -n 9 || { echo "another ods operation is running (lock $ODS_STATE_DIR/lock)" >&2; exit 75; }
  touch "$ODS_STATE_DIR/lock"; export ODS_LOCK_HELD=1
}

say(){ printf '[%s] %s\n' "$(date -u +%T)" "$*" | tee -a "$ODS_LOG" >&2; }
alert(){ say "ALERT: $*"; $ALERT_CMD "ods: $*" >/dev/null 2>&1 || true; }
die(){ say "ABORT: $*"; alert "aborted: $*"; exit 1; }

# Read a Firedancer TOML (python3 >= 3.11 for tomllib). Prints shell assignments with prefix $2:
# <P>_NAME <P>_USER <P>_BASE <P>_VH_DIR <P>_LOG <P>_JUNK_KEY <P>_METRICS_PORT
fd_toml_info(){
  python3 -I - "$1" "$2" <<'PY'
import sys, tomllib, shlex
c = tomllib.load(open(sys.argv[1], 'rb')); pre = sys.argv[2]
name = c.get('name', 'fd1'); user = c.get('user', '')
p = c.get('paths', {})
base = p.get('base', '/home/{user}/.firedancer/{name}').replace('{name}', name).replace('{user}', user)
vh = p.get('vote_history', base).replace('{name}', name).replace('{user}', user)
log = c.get('log', {}).get('path', '').replace('{name}', name).replace('{user}', user) or base + '/firedancer.log'
port = c.get('tiles', {}).get('metric', {}).get('prometheus_listen_port', 7999)
for k, v in dict(NAME=name, USER=user, BASE=base, VH_DIR=vh, LOG=log,
                 JUNK_KEY=p.get('identity_key', ''), METRICS_PORT=port).items():
    print(f'{pre}_{k}={shlex.quote(str(v))}')
PY
}

primary_ip(){ ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

# --- SSH to the standby
# ServerAlive*: a silently dead link fails within ~15 s instead of blocking for hours.
# Providers reuse IP addresses, so host keys are pinned PER SERVER (provider+id from the state
# file), never per IP: the first login to a newly delivered server records its key, every later
# login to that same server must match it.
known_hosts_for(){ local h=$1
  if [ -s "$ODS_STATE" ] && [ "$(state_get ip)" = "$h" ]; then echo "$ODS_STATE_DIR/known_hosts.$(state_get provider)-$(state_get id)"
  else echo "$ODS_KNOWN_HOSTS"; fi; }
# SSHS_TIMEOUT=N: kill the ssh client after N seconds (timeout cannot run shell functions)
# kill a process and all its descendants (children first found, then killed parent-first so none respawn)
kill_tree(){ local c; kill -STOP "$1" 2>/dev/null; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null; }
# ODS_SSH_MUX=PATH (set by ods-swap): reuse ONE connection per host for every call (ControlMaster):
# a new SSH connection costs ~6 round trips (~1 s at 190 ms), a multiplexed call ~1. If the master
# is gone, ssh silently opens a normal connection (ControlMaster=auto).
sshs(){ local h=$1 mux=(); shift
  [ -n "${ODS_SSH_MUX:-}" ] && mux=(-o ControlMaster=auto -o "ControlPath=$ODS_SSH_MUX-%C" -o ControlPersist=120)
  ${SSHS_TIMEOUT:+timeout -s KILL "$SSHS_TIMEOUT"} ssh "${mux[@]}" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$(known_hosts_for "$h")" "root@$h" "$@"; }

# --- regional endpoints (standby/localize-endpoints.py): "provider: role@region, ..." per line
endpoints_plan(){ python3 -I "$ODS_ROOT/standby/localize-endpoints.py" "$REGIONAL_ENDPOINTS" "$@" --plan; }
endpoints_providers(){ endpoints_plan "$@" 2>/dev/null | cut -d: -f1 | sort | tr '\n' ' '; }

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

# --- clients (primary: lib/primary-$PRIMARY_CLIENT.sh, standby: lib/standby-$STANDBY_CLIENT.sh)
metric(){ awk -v m="$1" '$1 ~ "^"m {print $2; exit}'; }
B58='[1-9A-HJ-NP-Za-km-z]{32,44}'
# get-identity must exit 0 and its LAST line must be exactly one base58 pubkey; anything else = "" (unknown)
_last_pubkey(){ local out rc; out=$("$@"); rc=$?; ((rc==0)) || return 0; out=$(printf '%s\n' "$out" | tail -1 | tr -d '[:space:]'); [[ "$out" =~ ^$B58$ ]] && echo "$out"; return 0; }
# Firedancer's CLI sandbox refuses unknown open fds ("unexpected file descriptor 9"): never let it
# inherit our lock (fd 9). Every local client invocation closes fd 9 and 3.
SETID_TIMEOUT=${SETID_TIMEOUT:-60}   # every set-identity runs under timeout -s KILL (no late, in-flight switches)

# lag = public cluster slot - local slot. 999999 = unknown (fails every check).
lag_of(){ local mine=$1 c
  c=$(cluster_slot) || { echo 999999; return; }     # no public reference = cannot prove "caught up"
  [[ "$mine" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] || { echo 999999; return; }
  local d=$((c-mine)); ((d<-50)) && d=999999; ((d<0)) && d=0; echo $d; }

state_get(){ [ -s "$ODS_STATE" ] && python3 -I -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$ODS_STATE" "$1"; }
state_put(){ python3 -I -c "import json,sys;json.dump(dict(zip(['provider','id','ip','plan','region','created'],sys.argv[2:])),open(sys.argv[1],'w'))" "$ODS_STATE" "$@"; }
