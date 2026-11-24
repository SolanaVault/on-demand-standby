# shellcheck shell=bash
# Cherry Servers provider (https://api.cherryservers.com/doc/). Hourly billing, standard plans only.
# Interface (every provider implements these):
#   <p>_enabled                         0 if configured
#   <p>_stock                           lines "provider plan region price_per_hour" for in-stock candidates
#   <p>_create PLAN REGION HOSTNAME     prints the new server id ("" on failure)
#   <p>_state ID                        prints "ready IP" | "wait" | "gone"
#   <p>_destroy ID                      prints the HTTP status
#   <p>_list_tagged                     lines "provider id ip created_epoch" for our standbys

CH_API=https://api.cherryservers.com/v1
ch(){ curl -s -m 60 -H "Authorization: Bearer $(tr -d '\n\r ' <"$CHERRY_TOKEN_FILE")" -H 'Content-Type: application/json' "$@"; }

cherry_enabled(){ [ -s "${CHERRY_TOKEN_FILE:-/nonexistent}" ] && [ -n "${CHERRY_PROJECT_ID:-}" ]; }

# Register $SSH_KEY.pub with Cherry if it is not there yet; prints the key id.
cherry_sshkey_id(){
  local pub; pub=$(awk '{print $1" "$2}' "$SSH_KEY.pub")
  local id; id=$(ch "$CH_API/ssh-keys" | python3 -I -c 'import json,sys
pub=sys.argv[1]
for k in json.load(sys.stdin):
    if " ".join(k.get("key","").split()[:2])==pub: print(k["id"]); break' "$pub")
  if [ -z "$id" ]; then
    id=$(ch -X POST "$CH_API/ssh-keys" -d "{\"label\":\"fd-standby\",\"key\":\"$(cat "$SSH_KEY.pub")\"}" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
  fi
  echo "$id"
}

cherry_stock(){  # reads candidate rows "cherry plan region qualified" from stdin
  local plans; plans=$(curl -s -m 30 "$CH_API/plans")
  while read -r _ plan region; do
    echo "$plans" | python3 -I -c 'import json,sys
plan,region=sys.argv[1],sys.argv[2]
for p in json.load(sys.stdin):
    if p["slug"]!=plan: continue
    pr=[x["price"] for x in p["pricing"] if x["unit"]=="Hourly"]
    for r in p["available_regions"]:
        if r["slug"]==region and r["stock_qty"]>0 and pr: print("cherry %s %s %.3f"%(plan,region,pr[0]))' "$plan" "$region"
  done
}

cherry_create(){
  local plan=$1 region=$2 host=$3 kid img r id part=""
  kid=$(cherry_sshkey_id); [ -n "$kid" ] || { say "cherry: cannot register SSH key"; return; }
  # Plans with exactly two disks < 2 TB: by default Cherry puts the OS RAID1 over both whole disks,
  # leaving no room for data. Ask for a small OS partition instead; standby-init.sh then adds a
  # data partition in the unallocated space behind it (documented create field os_partition_size).
  if curl -s -m 30 "$CH_API/plans" | python3 -I -c 'import json,sys
plan=sys.argv[1]
for p in json.load(sys.stdin):
    if p["slug"]==plan:
        st=p["specs"]["storage"]; n=sum(s["count"] for s in st)
        sys.exit(0 if n==2 and all(s.get("size",0)<2000 for s in st) else 1)
sys.exit(1)' "$plan"; then part=",\"os_partition_size\":${CHERRY_OS_PARTITION_GB:-50}"; say "cherry: 2-disk plan -> OS partition ${CHERRY_OS_PARTITION_GB:-50} GB"; fi
  for img in $CHERRY_IMAGES; do
    r=$(ch -X POST "$CH_API/projects/$CHERRY_PROJECT_ID/servers" -d "{\"plan\":\"$plan\",\"region\":\"$region\",\"image\":\"$img\",\"hostname\":\"$host\",\"ssh_keys\":[\"$kid\"],\"spot_market\":false,\"cycle\":\"hourly\"$part,\"tags\":{\"role\":\"fd-standby\",\"owner\":\"$FDS_OWNER_TAG\"}}")
    id=$(echo "$r" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
    [ -n "$id" ] && { echo "$id"; return; }
    say "cherry create ($img) failed: $(echo "$r" | head -c 300)"
  done
}

cherry_state(){
  ch "$CH_API/servers/$1" | python3 -I -c 'import json,sys
try: d=json.load(sys.stdin)
except ValueError: print("wait"); sys.exit()   # empty/invalid API answer: just poll again
if not isinstance(d,dict): print("wait"); sys.exit()
if d.get("code")==404: print("gone"); sys.exit()
ip=[i["address"] for i in d.get("ip_addresses",[]) if i["type"]=="primary-ip"]
print("ready "+ip[0] if d.get("status")=="deployed" and ip else "wait")'
}

cherry_destroy(){ ch -X DELETE -o /dev/null -w '%{http_code}' "$CH_API/servers/$1"; }

cherry_list_tagged(){
  ch "$CH_API/projects/$CHERRY_PROJECT_ID/servers" | python3 -I -c 'import json,sys,datetime
owner=sys.argv[1]
for s in json.load(sys.stdin):
    t=s.get("tags") or {}
    if t.get("role")=="fd-standby" and t.get("owner")==owner:   # only OUR standbys
        ip=[i["address"] for i in s.get("ip_addresses",[]) if i["type"]=="primary-ip"]
        c=s.get("created_at")   # missing while a server is still deploying: treat as brand new
        t=int(datetime.datetime.fromisoformat(c).timestamp()) if c else int(datetime.datetime.now().timestamp())
        print("cherry", s["id"], ip[0] if ip else "-", t)' "$FDS_OWNER_TAG"
}
