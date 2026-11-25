# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Standby adapter: Firedancer on the rented server (STANDBY_CLIENT=firedancer). Sourced by
# lib/common.sh. lib/standby-agave.sh implements the same functions. They run ON THE PRIMARY and
# reach the standby over SSH (sshs); *_cmd functions print a remote shell command for `sb`.
#
#   s_load_config          set S_USER S_NAME S_BASE S_VH_DIR S_LOG S_JUNK_KEY S_UNIT S_METRICS_PORT
#   s_id H                 identity the standby runs: one base58 pubkey or nothing (= unknown)
#   keypub_remote H FILE   pubkey of a keypair file on the standby
#   s_slot H               finalized slot of the standby
#   s_status_extra H       extra status fields
#   s_caught_up H [SINCE]  0 when the standby has caught up (after epoch SINCE, if given)
#   s_setid_cmd [--vote-history-file F] KEY   remote set-identity (under timeout -s KILL)
#   s_prepare_cmd          make a later switch to the staked key vote-capable without voting
#   s_unprepare_cmd        undo s_prepare_cmd (run only while the standby is positively junk)
#   s_no_setid_cmd         remote: 0 only if no identity switch is in flight
#   s_vh_fresh_cmd T       remote: the history of the switch AWAY from staked is final, written >= T
#   s_vh_file              remote path of that history
#   s_vh_fp_cmd            remote: fingerprint of s_vh_file
#   s_vh_restore_cmd       remote: prints a file to restore the standby with its own history
#   s_vh_incoming          remote path where the primary's history is staged
#   s_wait_cmd             remote: block until a safe window
#   s_keys_new_cmd FILE    remote: create a throwaway keypair FILE owned by S_USER (if missing)
#   s_cold_restart_cmd     remote: restart from scratch (qualify)
#   s_bundle DIR           add the client-specific files to the standby bundle
#   s_doctor               standby-specific doctor checks
#   S_SETID_REFUSED        (optional) rc of s_setid meaning "refused, nothing changed"

s_load_config(){
  local out
  # Firedancer primary: derive from its TOML. Agave primary: the operator's template.
  : "${STANDBY_FD_TOML:=${STANDBY_FD_TEMPLATE:-}}"
  [ -n "$STANDBY_FD_TOML" ] || { echo "set STANDBY_FD_TEMPLATE in $FDS_CONF (Firedancer standby of an $PRIMARY_CLIENT primary)" >&2; exit 2; }
  [ -n "${STANDBY_FD_BIN:-}" ] || { echo "set STANDBY_FD_BIN in $FDS_CONF" >&2; exit 2; }
  out=$(fd_toml_info "$STANDBY_FD_TOML" T) || { echo "cannot parse $STANDBY_FD_TOML" >&2; exit 2; }
  eval "$out"
  S_NAME=$T_NAME; S_USER=${T_USER:-firedancer}; S_METRICS_PORT=$T_METRICS_PORT
  [[ "$S_METRICS_PORT" =~ ^[0-9]+$ ]] || { echo "bad prometheus port in $STANDBY_FD_TOML" >&2; exit 2; }
  [[ "$S_NAME" =~ ^[A-Za-z0-9_.-]+$ && "$S_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "unsupported Firedancer name/user in $STANDBY_FD_TOML" >&2; exit 2; }
  S_BASE=$S_LED_MNT/$S_NAME
  S_VH_DIR=$S_BASE
  S_LOG=$S_BASE/firedancer.log
  S_JUNK_KEY=/home/$S_USER/standby-identity.json
  S_UNIT=firedancer
  S_FD_BIN=/opt/firedancer/bin/firedancer
  S_FD_CFG=/etc/firedancer/standby.toml
  S_VH_BAK=vote_history-$STAKED_PUBKEY.bin.bak   # written by Firedancer when it switches AWAY from the staked key
}

s_metrics(){ sshs "$1" "curl -s -m 3 127.0.0.1:$S_METRICS_PORT/metrics"; }
s_id(){ _last_pubkey sshs "$1" "cd /tmp && timeout 20 $S_FD_BIN get-identity --config $S_FD_CFG 2>/dev/null"; }
keypub_remote(){ sshs "$1" "cd /tmp && $S_FD_BIN keys pubkey $2 --config $S_FD_CFG 2>/dev/null" | tail -1; }
s_slot(){ local v; v=$(s_metrics "$1" </dev/null | metric replay_reset_slot); echo "${v%.*}"; }
s_status_extra(){ local m; m=$(s_metrics "$1" </dev/null); echo "rank=$(metric votor_rank <<<"$m") bam_healthy=$(metric bam_healthy <<<"$m")"; }
s_caught_up(){ local since=${2:-}
  if [ -n "$since" ]; then
    sshs "$1" "awk -v s=\"$(date -u -d "@$since" '+%F %T')\" '\$2\" \"substr(\$3,1,8)>=s' $S_LOG | grep 'caught up to cluster' >/dev/null" </dev/null
  else sshs "$1" "grep 'caught up to cluster' $S_LOG >/dev/null" </dev/null; fi; }
s_setid_cmd(){ local a="" x; for x in "$@"; do a+=" $(printf %q "$x")"; done
  echo "cd /tmp && timeout -s KILL $SETID_TIMEOUT $S_FD_BIN set-identity --config $S_FD_CFG$a"; }
s_prepare_cmd(){ echo true; }
s_unprepare_cmd(){ echo true; }
# "[s]" never matches the shell running pkill/pgrep (whose command line contains the pattern)
s_no_setid_cmd(){ echo "pkill -KILL -f -- '[s]et-identity --config $S_FD_CFG' 2>/dev/null; sleep 1; ! pgrep -f -- '[s]et-identity --config $S_FD_CFG' >/dev/null"; }
s_vh_file(){ echo "$S_VH_DIR/$S_VH_BAK"; }
s_vh_fresh_cmd(){ echo "f=$(printf %q "$(s_vh_file)"); [ -s \"\$f\" ] && [ \$(stat -c %Y \"\$f\") -ge $1 ]"; }
s_vh_fp_cmd(){ echo "stat -c '%i %s %y' $(printf %q "$(s_vh_file)")"; }
s_vh_restore_cmd(){ echo "f=$(printf %q "$S_VH_DIR")/vh-restore-\$(date +%s).bin; cp -p $(printf %q "$(s_vh_file)") \"\$f\" && chown $S_USER:$S_USER \"\$f\" && echo \"\$f\""; }
s_vh_incoming(){ echo "$S_VH_DIR/vote_history-$STAKED_PUBKEY.from-peer.bin"; }
s_wait_cmd(){ echo "cd /tmp && timeout 900 $S_FD_BIN wait --config $S_FD_CFG | tail -1"; }
s_keys_new_cmd(){ local f; f=$(printf %q "$1")
  echo "test -f $f || (cd /tmp && rm -f identity && $S_FD_BIN keys new identity --config $S_FD_CFG >/dev/null 2>&1 && install -m 600 -o $S_USER -g $S_USER /tmp/identity $f && shred -u /tmp/identity)"; }
s_cold_restart_cmd(){ echo "rm -f $(printf %q "$S_BASE")/snapshots/*; systemctl reset-failed firedancer 2>/dev/null; systemctl restart firedancer"; }

s_bundle(){ local d=$1 real rel
  real=$(readlink -f "$STANDBY_FD_BIN")
  rel=$(basename "$(dirname "$real")"); [ "$rel" = bin ] && rel="fd-$("$real" --version 9>&- 3<&- | awk 'NR==1{print $1}')"
  install -m 755 "$real" "$d/bin/firedancer"; echo "$rel" > "$d/bin/release"
  cp "$FDS_ROOT/standby/standby.nft.in" "$d/standby.nft.in"
  cp "$FDS_ROOT"/standby/units/firedancer*.service "$d/units/"
  printf 'CONFIGURE_STAGES=%q\n' "$STANDBY_CONFIGURE_STAGES" >> "$d/config/standby.env"
  python3 -I - "$STANDBY_FD_TOML" "$d/config/standby.toml.in" "$S_LED_MNT" "$S_ACC_MNT" "$S_JUNK_KEY" "${STANDBY_DROP_MULTICAST:-1}" <<'PY' || return 1
import re, sys
src, dst, led, acc, junk, dropmc = sys.argv[1:]
s = open(src).read()
def setkey(section, key, value, comment):
    """replace key in [section] (top-level table only) or append it to the section"""
    global s
    m = re.search(r'(?m)^\[' + re.escape(section) + r'\]\s*$', s)
    line = f'    {key} = "{value}"   # {comment}'
    if not m:
        s += f'\n[{section}]\n{line}\n'; return
    nxt = re.search(r'(?m)^\[[^\]]+\]\s*$', s[m.end():])
    end = m.end() + (nxt.start() if nxt else len(s) - m.end())
    body = s[m.end():end]
    pat = r'(?m)^[ \t]*' + re.escape(key) + r'[ \t]*=.*$'
    body = re.sub(pat, line, body, count=1) if re.search(pat, body) else '\n' + line + body
    s = s[:m.end()] + body + s[end:]
setkey('paths', 'identity_key', junk, 'fd-standby: junk; staked only via fd-standby-swap')
setkey('paths', 'base', led + '/{name}', 'fd-standby: standby layout')
setkey('paths', 'snapshots', led + '/{name}/snapshots', 'fd-standby: standby layout')
setkey('paths', 'accounts', acc + '/accounts.db', 'fd-standby: standby layout')
for k in ('vote_history',):
    s = re.sub(r'(?m)^[ \t]*' + k + r'[ \t]*=.*\n', '', s)
setkey('log', 'path', led + '/{name}/firedancer.log', 'fd-standby: standby layout')
setkey('net', 'interface', '@IFACE@', 'fd-standby: discovered on the standby')
setkey('net', 'provider', 'socket', 'fd-standby: socket works on any NIC')
if dropmc == '1':
    def drop(m):
        items = [x for x in re.findall(r'"([^"]+)"', m.group(2)) if not 224 <= int(x.split('.')[0]) <= 239]
        return m.group(1) + '[ ' + ', '.join('"%s"' % x for x in items) + ' ]'
    s = re.sub(r'(?m)^(\s*additional_shred_destinations_leader\s*=\s*)\[(.*?)\]', drop, s)
import tomllib
t = tomllib.loads(s.replace('@IFACE@', 'eth0'))          # must stay valid TOML
assert t['paths']['identity_key'] == junk and t['net']['provider'] == 'socket'
assert t['paths']['accounts'].startswith(acc) and t['log']['path'].startswith(led)
open(dst, 'w').write(s)
PY
  echo "$rel $(sha256sum "$real" | cut -c1-12)"
}

s_doctor(){
  chk "standby Firedancer binary runs ($STANDBY_FD_BIN)" "$STANDBY_FD_BIN" --version
  chk "standby Firedancer config parses ($STANDBY_FD_TOML)" test -n "$S_NAME"
  echo "  info regional endpoints (the standby picks the closest region per provider):"
  { endpoints_plan toml "$STANDBY_FD_TOML" 2>&1 || true; } | sed 's/^/         /'
  if [ "$PRIMARY_CLIENT" = agave ]; then     # template: it has to mirror the primary's setup itself
    local t pid pa sa; t=$(mktemp); pid=$(p_pid)
    [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/cmdline" > "$t"
    pa=$(endpoints_providers args "$t"); sa=$(endpoints_providers toml "$STANDBY_FD_TOML"); rm -f "$t"
    chk "standby template uses the same providers as the primary (primary: ${pa:-none}; template: ${sa:-none})" test "$pa" = "$sa"
  fi
}
