# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Primary adapter: Firedancer (full Firedancer, not Frankendancer). Sourced by lib/common.sh when
# PRIMARY_CLIENT=firedancer (the default). lib/primary-agave.sh implements the same functions with
# the same contracts; the swap logic in bin/ only talks to the primary through them:
#
#   p_load_config          validate settings; set P_JUNK_KEY P_VH_DIR P_OWNER STANDBY_FD_BIN STANDBY_FD_TOML
#   p_id                   identity the primary runs now: exactly one base58 pubkey, or nothing (= unknown)
#   keypub_local FILE      pubkey of a keypair file (or nothing)
#   p_prepare_staked       make a later switch to the staked key possible WITHOUT voting (no-op here)
#   p_setid [--vote-history-file F] KEY
#                          switch identity; synchronous, bounded by timeout -s KILL, exit code passed
#                          through (rc != 0 = "may still complete": the caller never auto-restores)
#   p_no_setid             0 only if it can prove no identity switch is in flight (kills stragglers)
#   p_pid                  non-empty PID of the running validator process, else nothing
#   p_slot                 the slot the node has finalized (Firedancer: replay_reset_slot)
#   p_vh_file              vote history written by the switch AWAY from the staked key
#   p_vh_fresh T           p_vh_file is complete and was produced by a switch that started at T
#   p_vh_fp                fingerprint of p_vh_file (must not change while it is copied)
#   p_vh_restore_file      prints a file to pass to p_setid --vote-history-file to restore the primary
#                          with its own history
#   p_vh_incoming          path where the vote history coming back from the standby is staged
#   p_start_ok / p_preflight   the primary can fail over (start identity junk, ...)
#   p_unprepare_staked     undo p_prepare_staked
#   p_wait                 block until a safe window (no own leader slot soon), bounded by a timeout
#   p_status_extra         extra fields for status lines
#   p_doctor               client-specific doctor checks (uses chk from bin/ods)
#   p_setid_hint KEY       manual command that switches the primary to KEY (for alert texts)

p_load_config(){
  : "${PRIMARY_FD_CONFIG:?set PRIMARY_FD_CONFIG in $ODS_CONF}" "${FD_BIN:?set FD_BIN in $ODS_CONF}"
  local out
  out=$(fd_toml_info "$PRIMARY_FD_CONFIG" P) || { echo "cannot parse $PRIMARY_FD_CONFIG" >&2; exit 2; }
  eval "$out"
  [[ "$P_METRICS_PORT" =~ ^[0-9]+$ ]] || { echo "bad prometheus port in $PRIMARY_FD_CONFIG" >&2; exit 2; }
  P_OWNER=${P_USER:-firedancer}; P_GROUP=$P_OWNER
  # the standby runs the primary's own Firedancer build with a config derived from the primary's
  STANDBY_FD_BIN=$FD_BIN
  STANDBY_FD_TOML=$PRIMARY_FD_CONFIG
  P_VH_FILE=vote_history-$STAKED_PUBKEY.bin
}

p_metrics(){ curl -s -m 3 "127.0.0.1:$P_METRICS_PORT/metrics"; }
p_metric(){ p_metrics | metric "$1"; }
p_id(){ (cd /tmp && _last_pubkey timeout 20 "$FD_BIN" get-identity --config "$PRIMARY_FD_CONFIG" 2>/dev/null 9>&- 3<&-); }
keypub_local(){ (cd /tmp && "$FD_BIN" keys pubkey "$1" --config "$PRIMARY_FD_CONFIG" 2>/dev/null 9>&- 3<&- | tail -1); }
p_unprepare_staked(){ return 0; }
p_prepare_staked(){ return 0; }
p_setid(){ (cd /tmp && timeout -s KILL "$SETID_TIMEOUT" "$FD_BIN" set-identity --config "$PRIMARY_FD_CONFIG" "$@" 9>&- 3<&-); }
# The pattern starts with "[s]" so it never matches the shell that runs pkill/pgrep (whose own
# command line contains the pattern text), and it does not depend on the binary's name.
p_no_setid(){ local pat="[s]et-identity --config $PRIMARY_FD_CONFIG"
  pkill -KILL -f -- "$pat" 2>/dev/null; sleep 1; ! pgrep -f -- "$pat" >/dev/null; }
p_pid(){ pgrep -o -f -- "run --config $PRIMARY_FD_CONFIG"; }
p_slot(){ local v; v=$(p_metric replay_reset_slot); echo "${v%.*}"; }

# Firedancer writes the history file and then renames it to .bak when it switches AWAY from an
# identity, so the .bak of THIS switch has mtime >= the switch start. NEVER move or delete
# vote-history files: votor renames its "spare" (the .bak of the identity it last left) BY NAME
# on the next switch and dies (FD_LOG_ERR) if it is missing (fd_votor_tile.c, v26.10.8).
p_vh_file(){ echo "$P_VH_DIR/$P_VH_FILE.bak"; }
p_vh_fresh(){ local f; f=$(p_vh_file); [ -s "$f" ] && [ "$(stat -c %Y "$f")" -ge "$1" ]; }
p_vh_fp(){ stat -c '%i %s %y' "$(p_vh_file)" 2>/dev/null; }
p_vh_restore_file(){ local f; f=$P_VH_DIR/vh-restore-$(date +%s).bin
  cp -p "$(p_vh_file)" "$f" && chown "$P_OWNER:$P_OWNER" "$f" && echo "$f"; }
p_vh_incoming(){ echo "$P_VH_DIR/$P_VH_FILE.from-peer.bin"; }
p_wait(){ (cd /tmp && timeout 900 "$FD_BIN" wait --config "$PRIMARY_FD_CONFIG" 9>&- 3<&-); }
p_start_ok(){ return 0; }
p_preflight(){ return 0; }   # Firedancer starts with [paths] identity_key = P_JUNK_KEY by construction
p_status_extra(){ echo "rank=$(p_metric votor_rank) bam_healthy=$(p_metric bam_healthy)"; }
p_setid_hint(){ echo "$FD_BIN set-identity --config $PRIMARY_FD_CONFIG $1"; }

p_doctor(){
  metrics_ok(){ [ -n "$(p_metric replay_reset_slot)" ]; }
  chk "primary Firedancer config parses ($PRIMARY_FD_CONFIG)" test -n "$P_NAME"
  chk "Firedancer binary runs ($FD_BIN)" "$FD_BIN" --version
  chk "primary junk key exists ($P_JUNK_KEY)" test -s "$P_JUNK_KEY"
  chk "primary junk key is NOT the staked key" not_staked "$P_JUNK_KEY"
  chk "staked key present, root 0600, matches STAKED_PUBKEY" staked_ok "$PRIMARY_STAKED_KEY"
  chk "Firedancer on this primary answers get-identity" test -n "$(p_id)"
  echo "  info running identity: $(p_id)  (staked: $STAKED_PUBKEY)"
  chk "metrics endpoint answers (port $P_METRICS_PORT)" metrics_ok
  chk "vote history dir exists ($P_VH_DIR)" test -d "$P_VH_DIR"
  chk "log file readable ($P_LOG)" test -r "$P_LOG"
}
