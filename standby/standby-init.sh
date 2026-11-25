#!/usr/bin/env bash
# Prepare a freshly delivered bare-metal box as a Firedancer or Agave STANDBY (junk identity).
# Runs ON the standby as root, from the unpacked bundle directory. Idempotent.
#
#   ./standby-init.sh --primary-ip IP [--private-net CIDR] [--check-only]
#
# Nothing here depends on device or interface NAMES. Everything is discovered:
#  - CPU/RAM/flags are checked against minimums (abort = unsuitable box)
#  - data disks = whole disks with no partitions, no filesystem signature, not mounted,
#    not part of any RAID/LVM, not holding / or /boot. Never touches the OS disks.
#  - layout is chosen from what is found (2+ free disks, 1 big free disk, or big root fs)
#  - the public interface is the one carrying the default route
# The script ends with a one-line JSON summary (prefix "RESULT ").
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
. config/standby.env      # CLIENT, FD_USER, FD_NAME, ... (written by `ods bundle`)
CLIENT=${CLIENT:-firedancer}
# Regional endpoints (Jito, BAM, Harmonic, ...): the region closest to THIS machine, per provider
# (config/regional-endpoints.conf). Only endpoints the primary uses are changed; nothing is added.
localize(){ local fmt=$1; shift
  python3 -I ./localize-endpoints.py config/regional-endpoints.conf "$fmt" "$@" 2>&1 | while read -r l; do log "endpoints: $l"; done
  return "${PIPESTATUS[0]}"; }

# Stages (run in this order by ods, each in its own SSH call):
#   --check-only   hardware/disk/network checks, changes nothing
#   --firewall     load the firewall (SSH only from the primary) + 3 min automatic rollback,
#                  which the caller cancels by touching /run/ods-fw-ok from a NEW login
#   --setup        everything else; refuses unless the firewall was confirmed
PRIMARY_IP=""; EXTRA_SSH=""; MODE=""
while [ $# -gt 0 ]; do case "$1" in
  --primary-ip) PRIMARY_IP=$2; shift 2;;
  --extra-ssh|--private-net) EXTRA_SSH=$2; shift 2;;
  --check-only) MODE=check; shift;;
  --firewall) MODE=firewall; shift;;
  --setup) MODE=setup; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; done
[[ "$PRIMARY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "need --primary-ip IPv4"; exit 2; }
[[ -z "$EXTRA_SSH" || "$EXTRA_SSH" =~ ^[0-9./,\ ]+$ ]] || { echo "bad --extra-ssh (IPv4/CIDR list)"; exit 2; }
for c in ${EXTRA_SSH//,/ }; do [[ "$c" != */* || "${c#*/}" -ge 8 ]] || { echo "--extra-ssh $c is too broad (/8 minimum)"; exit 2; }; done
[ -n "$MODE" ] || { echo "need --check-only, --firewall or --setup"; exit 2; }

# Minimums. Firedancer: from the FireBAM v26.10.8 mainnet config (164 GiB locked, 55 tiles on 48
# threads). Agave: MIN_RAM_GIB / REQ_FLAGS / MIN_GLIBC come from the bundle (standby.env).
MIN_THREADS=48
MIN_RAM_GIB=${MIN_RAM_GIB:-240}   # Firedancer: 164 GiB hugepages + OS + page cache headroom
MIN_ACCOUNTS_GB=900        # accounts.db file is ~584 GB and grows
MIN_LEDGER_GB=500          # 2 full + 2 incremental snapshots (~280 GB) + shreds (50 GiB) + log
REQ_FLAGS=${REQ_FLAGS:-"avx2 bmi2 adx sha_ni aes vaes vpclmulqdq fma movbe"}   # Firedancer: used by the znver3 build
MIN_GLIBC=${MIN_GLIBC:-2.38}

FD_BIN_SRC=bin/firedancer
log(){ printf '[%s] %s\n' "$(date -u +%T)" "$*"; }
fail(){ log "FAIL: $*"; echo "RESULT {\"ok\":false,\"reason\":\"$*\"}"; exit 1; }

# ------------------------------------------------------------------ 1. hardware checks
threads=$(nproc --all)
ram_gib=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
cpu=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)
missing=""; for f in $REQ_FLAGS; do grep -qw "$f" /proc/cpuinfo || missing="$missing $f"; done
log "cpu: $cpu | threads=$threads ram=${ram_gib}GiB | kernel $(uname -r) | $(. /etc/os-release; echo $PRETTY_NAME)"
[ "$threads" -ge $MIN_THREADS ] || fail "only $threads threads (need $MIN_THREADS)"
[ "$ram_gib" -ge $MIN_RAM_GIB ] || fail "only ${ram_gib} GiB RAM (need $MIN_RAM_GIB)"
[ -z "$missing" ] || fail "CPU lacks:$missing (needed by the $CLIENT build)"
glibc=$(ldd --version | awk 'NR==1{print $NF}')
python3 -c "import sys; v=lambda x: tuple(map(int,x.split('.'))); sys.exit(0 if v('$glibc')>=v('$MIN_GLIBC') else 1)" || fail "glibc $glibc < $MIN_GLIBC"

# ------------------------------------------------------------------ 2. network discovery
IFACE=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
PUBIP=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$IFACE" ] || fail "no default route"
log "net: default route via $IFACE ($PUBIP)"

# ------------------------------------------------------------------ 3. disk discovery
# Already mounted from a previous run? Then reuse.
ACC_MNT=/mnt/ods-accounts; LED_MNT=/mnt/ods-ledger
if findmnt -n "$ACC_MNT" >/dev/null && findmnt -n "$LED_MNT" >/dev/null; then
  LAYOUT=existing
else
  # candidates (largest first):
  #  - whole disks: no partitions, no filesystem/RAID/LVM signature, not mounted
  #  - "free:" regions: unallocated space AFTER the last partition of a GPT disk (e.g. the OS disks
  #    of 2-disk plans ordered with a small OS partition). Existing partitions are never touched.
  CANDS=$(lsblk -J -b -o NAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,ROTA | python3 -I -c '
import json,sys,subprocess,re
d=json.load(sys.stdin)["blockdevices"]
out=[]
def free_region(disk):
    dump=subprocess.run(["sfdisk","-d",disk],capture_output=True,text=True)
    if dump.returncode!=0 or not re.search(r"^label: gpt$",dump.stdout,re.M): return None
    ss=int((re.search(r"^sector-size: (\d+)$",dump.stdout,re.M) or [0,512])[1])
    ends=[int(a)+int(b) for a,b in re.findall(r"start=\s*(\d+), size=\s*(\d+)",dump.stdout)]
    if not ends: return None
    fr=subprocess.run(["sfdisk","-F",disk],capture_output=True,text=True)
    if fr.returncode!=0: return None
    best=None
    for st,en,n in re.findall(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+\S+\s*$",fr.stdout,re.M):
        st,n=int(st),int(n)
        if st>=max(ends) and (best is None or n>best[1]): best=(st,n)
    if best and best[1]*ss>=200*10**9:
        return {"path":"free:%s:%d:%d"%(disk,best[0],best[1]),"size_gb":best[1]*ss//10**9,"kind":"free"}
    return None
for b in d:
    if b["type"]!="disk": continue
    if b.get("children"):
        # only plain partitioned disks: a whole-disk RAID member (md metadata at the end) shows
        # the table of the array on the raw disk - never append there
        if b.get("fstype") or any(c.get("type")!="part" for c in b["children"]): continue
        r=free_region(b["path"])
        if r: out.append(r)
        continue
    if b.get("fstype") or any(m for m in (b.get("mountpoints") or []) if m): continue
    if b["size"] < 200*10**9: continue
    w=subprocess.run(["wipefs","-n",b["path"]],capture_output=True,text=True)
    if w.returncode!=0 or w.stdout.strip(): continue                # error or any signature = not empty
    out.append({"path":b["path"],"size_gb":b["size"]//10**9,"kind":"disk","model":(b.get("model") or "").strip(),"serial":b.get("serial")})
out.sort(key=lambda x:-x["size_gb"])
print(json.dumps(out))')
  log "free disks: $CANDS"
  ROOT_FREE_GB=$(df -B1G --output=avail / | tail -1 | tr -d ' ')
  n=$(echo "$CANDS" | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')
  big(){ echo "$CANDS" | python3 -I -c "import json,sys;l=json.load(sys.stdin);print(l[$1]['$2'])"; }
  if [ "$n" -ge 2 ] && [ "$(big 0 size_gb)" -ge $MIN_ACCOUNTS_GB ] && [ "$(big 1 size_gb)" -ge $MIN_LEDGER_GB ]; then
    LAYOUT="two-disks"; ACC_DEV=$(big 0 path); LED_DEV=$(big 1 path)
  elif [ "$n" -ge 1 ] && [ "$(big 0 size_gb)" -ge $((MIN_ACCOUNTS_GB+MIN_LEDGER_GB)) ]; then
    LAYOUT="one-disk"; ACC_DEV=$(big 0 path); LED_DEV=""
  elif [ "$n" -ge 1 ] && [ "$(big 0 size_gb)" -ge $MIN_ACCOUNTS_GB ] && [ "$ROOT_FREE_GB" -ge $MIN_LEDGER_GB ]; then
    LAYOUT="disk-plus-root"; ACC_DEV=$(big 0 path); LED_DEV=""
  elif [ "$ROOT_FREE_GB" -ge $((MIN_ACCOUNTS_GB+MIN_LEDGER_GB)) ]; then
    LAYOUT="root-only"; ACC_DEV=""; LED_DEV=""
  else
    fail "not enough disk: free disks=$CANDS root_free=${ROOT_FREE_GB}GB (need ${MIN_ACCOUNTS_GB}+${MIN_LEDGER_GB} GB)"
  fi
  if [ -n "$LED_DEV" ]; then led_desc=$LED_DEV
  elif [ -n "$ACC_DEV" ]; then led_desc="same disk as accounts"
  else led_desc=rootfs; fi
  log "layout: $LAYOUT accounts=${ACC_DEV:-rootfs} ledger=$led_desc"
fi
if [ "$MODE" = check ]; then
  echo "RESULT {\"ok\":true,\"check_only\":true,\"layout\":\"$LAYOUT\",\"iface\":\"$IFACE\",\"threads\":$threads,\"ram_gib\":$ram_gib}"; exit 0
fi

export DEBIAN_FRONTEND=noninteractive
command -v nft >/dev/null && command -v mkfs.xfs >/dev/null || { apt-get -qq update; apt-get -qq install -y nftables xfsprogs >/dev/null; }

# ------------------------------------------------------------------ 4. firewall (own stage)
fw_active(){ nft list ruleset 2>/dev/null | grep -c 'ods: SSH from primary only' >/dev/null; }
if [ "$MODE" = firewall ]; then
  rm -f /run/ods-fw-ok
  sed -e "s#@SSH_SOURCES@#$PRIMARY_IP${EXTRA_SSH:+, $EXTRA_SSH}#" standby.nft.in > /etc/nftables.conf
  nft -c -f /etc/nftables.conf
  nft list ruleset > /run/ods-nft-prev 2>/dev/null || true
  # safety net: restore the previous ruleset unless a NEW login confirms within 3 minutes
  nohup sh -c 'sleep 180; [ -e /run/ods-fw-ok ] || { nft flush ruleset; nft -f /run/ods-nft-prev; }' >/dev/null 2>&1 &
  nft -f /etc/nftables.conf; systemctl enable -q nftables
  log "firewall loaded (SSH only from $PRIMARY_IP${EXTRA_SSH:+, $EXTRA_SSH}); waiting for confirmation"
  echo "RESULT {\"ok\":true,\"stage\":\"firewall\"}"; exit 0
fi
[ -e /run/ods-fw-ok ] && fw_active || fail "firewall not confirmed/active - run --firewall and confirm first"
id "$FD_USER" >/dev/null 2>&1 || useradd -r -m -d "/home/$FD_USER" -s /usr/sbin/nologin "$FD_USER"
# the staked key will live in /run (tmpfs): no swap, so it can never be paged to disk
swapoff -a; sed -i -E 's@^([^#].*\sswap\s.*)$@# ods: \1@' /etc/fstab

# ------------------------------------------------------------------ 6. disks
# "free:DISK:START:SECTORS" -> append ONE partition exactly there, print its device path
make_part(){ local disk start sectors line part
  IFS=: read -r _ disk start sectors <<< "$1"
  sfdisk -F "$disk" | grep -Eq "^\s*$start\s+[0-9]+\s+$sectors\s" || fail "free region on $disk changed - not partitioning"
  sfdisk -d "$disk" > "/root/ods-sfdisk-$(basename "$disk").before"          # backup of the table
  echo "start=$start, size=$sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4" | sfdisk --append --no-reread -q "$disk" >/dev/null \
    || fail "sfdisk --append failed on $disk"
  partx -a "$disk" 2>/dev/null || true; udevadm settle
  line=$(sfdisk -d "$disk" | grep -E "start=\s*$start,") || fail "new partition on $disk not found"
  part=${line%% *}; [ -b "$part" ] || fail "new partition $part has no device node"
  log "created $part in free space of $disk (table backup in /root)" >&2; echo "$part"; }   # stdout = path only
mkfs_label(){ local dev=$1 label=$2
  [[ "$dev" == free:* ]] && dev=$(make_part "$dev")
  blkid "$dev" >/dev/null 2>&1 && { echo "refusing: $dev has a signature"; exit 1; }; mkfs.xfs -q -L "$label" "$dev"; }
fstab(){ grep -q "LABEL=$1 " /etc/fstab || echo "LABEL=$1 $2 xfs noatime,nofail 0 0" >> /etc/fstab; }
case "$LAYOUT" in
  existing) ;;
  two-disks) mkfs_label "$ACC_DEV" ods-accounts; mkfs_label "$LED_DEV" ods-ledger; fstab ods-accounts $ACC_MNT; fstab ods-ledger $LED_MNT ;;
  one-disk|disk-plus-root)
    mkfs_label "$ACC_DEV" ods-data; fstab ods-data /mnt/ods-data
    mkdir -p /mnt/ods-data; systemctl daemon-reload; mount /mnt/ods-data
    mkdir -p /mnt/ods-data/accounts /mnt/ods-data/ledger
    if [ $LAYOUT = one-disk ]; then
      grep -q " $ACC_MNT " /etc/fstab || echo "/mnt/ods-data/accounts $ACC_MNT none bind,nofail 0 0" >> /etc/fstab
      grep -q " $LED_MNT " /etc/fstab || echo "/mnt/ods-data/ledger $LED_MNT none bind,nofail 0 0" >> /etc/fstab
    else
      grep -q " $ACC_MNT " /etc/fstab || echo "/mnt/ods-data/accounts $ACC_MNT none bind,nofail 0 0" >> /etc/fstab
    fi ;;
  root-only) ;;
esac
mkdir -p $ACC_MNT $LED_MNT; systemctl daemon-reload; mount -a
install -d -o "$FD_USER" -g "$FD_USER" -m 750 "$LED_MNT/$FD_NAME"
[ "$CLIENT" = firedancer ] && install -d -o "$FD_USER" -g "$FD_USER" -m 700 "$LED_MNT/$FD_NAME/snapshots"     # configure stage wants 0700
chown "$FD_USER:$FD_USER" $ACC_MNT
ACC_FREE=$(df -B1G --output=avail $ACC_MNT | tail -1 | tr -d ' '); LED_FREE=$(df -B1G --output=avail $LED_MNT | tail -1 | tr -d ' ')
log "accounts: $(findmnt -no SOURCE $ACC_MNT) ${ACC_FREE}G free | ledger: $(findmnt -no SOURCE $LED_MNT) ${LED_FREE}G free"

if [ "$CLIENT" = agave ]; then
# ------------------------------------------------------------------ 7a. Agave: binaries, identity, node helper
AG=/opt/agave; REL=$AG/releases/$(cat bin/release)
install -d -m 755 "$REL" /etc/agave /opt/ods-node
install -m 755 bin/agave-validator bin/solana-keygen "$REL/"; ln -sfn "$REL" $AG/active
# the same file capabilities as on the primary (setcap; a copy loses them)
setcaps(){ local caps; caps=$(cat "$2" 2>/dev/null) || fail "no capabilities record $2 in the bundle"
  [ -n "$caps" ] || return 0
  command -v setcap >/dev/null || apt-get -qq install -y libcap2-bin >/dev/null
  setcap "$caps" "$1" || fail "setcap $caps $1 failed"
  [ "$(getcap "$1" | awk '{print $NF}')" = "$caps" ] || fail "file capabilities of $1 are not $caps after setcap"
  log "file capabilities as on the primary: $(basename "$1") $caps"; }
setcaps "$REL/agave-validator" bin/agave-validator.caps
install -d -m 755 "$REL/companions" /etc/agave/companions; rm -f /etc/agave/companions/*.args
for c in bin/companions/*; do [ -f "$c" ] || continue; [[ "$c" == *.caps ]] && continue
  n=$(basename "$c"); install -m 755 "$c" "$REL/companions/$n"; install -m 644 "config/companions/$n.args" /etc/agave/companions/
  setcaps "$REL/companions/$n" "$c.caps"
  log "companion $n (runs next to the validator, as on the primary)"; done
ver=$($AG/active/agave-validator --version 2>&1 | head -1 || true)
[ "$ver" = "$(cat bin/version)" ] || fail "binary version mismatch ($ver vs $(cat bin/version))"
install -m 755 node/ods-node /opt/ods-node/ods-node
install -m 644 node/primary-agave.sh node/node.env /opt/ods-node/
ln -sfn /opt/ods-node/ods-node /usr/local/sbin/ods-node
install -m 644 60-ods-tcp-rmem.conf 60-agave.conf /etc/sysctl.d/; sysctl -q -p /etc/sysctl.d/60-ods-tcp-rmem.conf -p /etc/sysctl.d/60-agave.conf
J=/home/$FD_USER/standby-identity.json
if [ ! -e "$J" ]; then
  $AG/active/solana-keygen new --no-bip39-passphrase --silent --force -o /root/ods-junk.json >/dev/null
  install -m 600 -o "$FD_USER" -g "$FD_USER" /root/ods-junk.json "$J"; shred -u /root/ods-junk.json; fi
JUNK=$($AG/active/solana-keygen pubkey "$J")
L=$LED_MNT/$FD_NAME
# the primary's command line (one argument per line), made host-independent by `ods bundle`
cp config/agave.args /etc/agave/standby.args
grep -qx -- "--identity" /etc/agave/standby.args && grep -qxF -- "$J" /etc/agave/standby.args || fail "standby.args does not use the junk identity $J"
shopt -s nullglob; LOC=(/etc/agave/standby.args /etc/agave/companions/*.args); shopt -u nullglob
localize args "${LOC[@]}" || fail "cannot localize the regional endpoints"

# ------------------------------------------------------------------ 7b. Agave: snapshot
# From STANDBY_SNAPSHOT_URLS (RPC-style /snapshot.tar.bz2 + /incremental-snapshot.tar.bz2, 303 to
# the real file), else the validator fetches its own (the primary's --known-validator rules).
fetch_snap(){ local base=$1 kind=$2 url name
  url=$(curl -s -m 20 -o /dev/null -w '%{redirect_url}' "$base/$kind.tar.bz2") || return 1
  name=$(basename "${url%%\?*}")
  [[ "$name" =~ ^(incremental-)?snapshot-[0-9][0-9A-Za-z-]*\.tar\.(zst|bz2|gz|lz4)$ ]] || return 1
  # an incremental only applies to ITS full snapshot (incremental-snapshot-<full slot>-<slot>-...):
  # a server that made a newer full one meanwhile serves an incremental we cannot use
  if [ "$kind" = incremental-snapshot ]; then local full; full=$(ls "$L"/snapshot-*.tar.* 2>/dev/null | sed -E 's@.*/snapshot-([0-9]+)-.*@\1@' | sort -n | tail -1)
    [[ "$name" == incremental-snapshot-"$full"-* ]] || { log "incremental $name is not for the full snapshot at slot $full: skipped (the validator catches up from the full one)"; return 1; }; fi
  [ -e "$L/$name" ] && return 0
  log "downloading $name from $base"
  curl -fsS --retry 3 --speed-limit 10000000 --speed-time 60 -o "$L/$name.part" "$url" && mv "$L/$name.part" "$L/$name" && chown "$FD_USER:$FD_USER" "$L/$name"; }
snap=0
if ls "$L"/snapshot-*.tar.* >/dev/null 2>&1; then snap=1
else
  while read -r u; do
    [ -n "$u" ] || continue
    if fetch_snap "$u" snapshot; then snap=1; fetch_snap "$u" incremental-snapshot || log "no incremental from $u (the full one is enough)"; break; fi
    rm -f "$L"/*.part; log "snapshot download from $u failed"
  done < config/snapshot-urls
fi
if [ $snap = 1 ]; then grep -qx -- --no-snapshot-fetch /etc/agave/standby.args || echo --no-snapshot-fetch >> /etc/agave/standby.args
else sed -i '/^--no-snapshot-fetch$/d' /etc/agave/standby.args; log "no local snapshot: the validator fetches one itself"; fi
cat > $AG/standby-validator.sh <<'SH'
#!/bin/bash
mapfile -t A < /etc/agave/standby.args
exec /opt/agave/active/agave-validator "${A[@]}"
SH
cat > $AG/companion.sh <<'SH'
#!/bin/bash
[[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 2
mapfile -t A < "/etc/agave/companions/$1.args"
exec "/opt/agave/active/companions/$1" "${A[@]}"
SH
chmod 755 $AG/standby-validator.sh $AG/companion.sh
log "identity (junk): $JUNK | $ver"

# ------------------------------------------------------------------ 8a. Agave: host tuning + units
for s in tuned irqbalance; do systemctl disable --now $s >/dev/null 2>&1 || true; done
install -m 644 units/*.service /etc/systemd/system/
sed -i -e "s#@ACC_MNT@#$ACC_MNT#g" -e "s#@LED_MNT@#$LED_MNT#g" -e "s#@USER@#$FD_USER#g" /etc/systemd/system/agave-validator.service /etc/systemd/system/agave-companion@.service
systemctl daemon-reload
for c in /etc/agave/companions/*.args; do if [ -f "$c" ]; then systemctl enable -q "agave-companion@$(basename "$c" .args).service"; fi; done
systemctl enable -q --now ods-cpu-governor.service
systemctl enable -q agave-validator.service
systemctl reset-failed agave-validator.service 2>/dev/null; systemctl restart agave-validator.service   # a rerun: old failed starts must not hit StartLimitBurst
sleep 15; systemctl is-active --quiet agave-validator || {
  # why: the unit's journal and the validator's own log (startup errors land in either)
  journalctl -u agave-validator -n 25 --no-pager -o cat 2>&1 | sed 's/^/[journal] /'
  vlog=$(awk 'p{print; exit} $0=="--log"||$0=="-o"{p=1}' /etc/agave/standby.args)
  [ -n "$vlog" ] && [ -f "$vlog" ] && grep -E ' (ERROR|WARN) |panicked|Error' "$vlog" | tail -n 25 | sed 's/^/[vlog] /'
  fail "agave-validator did not start"; }
for c in /etc/agave/companions/*.args; do [ -f "$c" ] || continue
  systemctl is-active --quiet "agave-companion@$(basename "$c" .args)" || fail "companion $(basename "$c" .args) did not start"; done
log "agave-validator started"
echo "RESULT {\"ok\":true,\"client\":\"agave\",\"layout\":\"$LAYOUT\",\"iface\":\"$IFACE\",\"pubip\":\"$PUBIP\",\"junk\":\"$JUNK\",\"threads\":$threads,\"ram_gib\":$ram_gib,\"accounts_free_gb\":$ACC_FREE,\"ledger_free_gb\":$LED_FREE,\"cpu\":\"$cpu\"}"
exit 0
fi

# ------------------------------------------------------------------ 7. binary + config + identity
REL=/opt/firedancer/releases/$(cat bin/release)
install -d -m 755 "$REL" /opt/firedancer/bin /etc/firedancer
install -m 755 $FD_BIN_SRC "$REL/firedancer"; ln -sfn "$REL/firedancer" /opt/firedancer/bin/firedancer
ver=$(/opt/firedancer/bin/firedancer --version 2>&1 || true)
case "$ver" in *"$(cut -d- -f2 bin/release | tr -d v)"*) ;; *) fail "binary version mismatch ($ver vs $(cat bin/release))";; esac
sed -e "s#@IFACE@#$IFACE#" config/standby.toml.in > /etc/firedancer/standby.toml
localize toml /etc/firedancer/standby.toml || fail "cannot localize the regional endpoints"
printf "FD_CONFIG=/etc/firedancer/standby.toml\nFD_CONFIGURE_STAGES=%s\n" "$CONFIGURE_STAGES" > /etc/default/firedancer
install -m 644 60-ods-tcp-rmem.conf /etc/sysctl.d/; sysctl -q -p /etc/sysctl.d/60-ods-tcp-rmem.conf
J=/home/$FD_USER/standby-identity.json
if [ ! -e "$J" ]; then (cd /tmp && rm -f identity && /opt/firedancer/bin/firedancer keys new identity --config /etc/firedancer/standby.toml >/dev/null 2>&1); install -m 600 -o "$FD_USER" -g "$FD_USER" /tmp/identity "$J"; shred -u /tmp/identity; fi
JUNK=$(cd /tmp && /opt/firedancer/bin/firedancer keys pubkey "$J" --config /etc/firedancer/standby.toml 2>/dev/null | tail -1)
(cd /tmp && /opt/firedancer/bin/firedancer mem --config /etc/firedancer/standby.toml >/tmp/ods-mem.txt 2>&1) || fail "firedancer mem rejects the config"
log "identity (junk): $JUNK | $(grep -E 'Total Memory Locked' /tmp/ods-mem.txt | xargs)"

# ------------------------------------------------------------------ 8. host tuning + units
for s in tuned irqbalance; do systemctl disable --now $s >/dev/null 2>&1 || true; done
install -m 644 units/*.service /etc/systemd/system/
sed -i -e "s#@ACC_MNT@#$ACC_MNT#g" -e "s#@LED_MNT@#$LED_MNT#g" /etc/systemd/system/firedancer*.service
sed -i "s#@ALL_CPUS@#0-$((threads-1))#" /etc/systemd/system/firedancer.service
systemctl daemon-reload
systemctl enable -q --now ods-cpu-governor.service
systemctl enable -q firedancer-configure.service firedancer.service
systemctl restart firedancer-configure.service || { journalctl -u firedancer-configure -n 20 --no-pager; fail "configure failed"; }
systemctl reset-failed firedancer.service 2>/dev/null; systemctl restart firedancer.service
sleep 15; systemctl is-active --quiet firedancer || fail "firedancer did not start"
log "firedancer started"
echo "RESULT {\"ok\":true,\"layout\":\"$LAYOUT\",\"iface\":\"$IFACE\",\"pubip\":\"$PUBIP\",\"junk\":\"$JUNK\",\"threads\":$threads,\"ram_gib\":$ram_gib,\"accounts_free_gb\":$ACC_FREE,\"ledger_free_gb\":$LED_FREE,\"cpu\":\"$cpu\"}"
