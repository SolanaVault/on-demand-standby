# shellcheck shell=bash
# Vultr bare metal provider (https://www.vultr.com/api/). EXPERIMENTAL / UNTESTED END TO END:
# new Vultr accounts have a monthly-fee limit below one bare-metal server and Vultr raises it
# only for accounts with history. The API calls below were verified up to the point where
# the account limit refused the create. See README "Providers".

VU_API=https://api.vultr.com/v2
vu(){ printf 'Authorization: Bearer %s\n' "$(tr -d '\n\r ' <"$VULTR_KEY_FILE")" | curl -s -m 60 -H @- -H 'Content-Type: application/json' "$@"; }   # token not in argv

vultr_enabled(){ [ -s "${VULTR_KEY_FILE:-/nonexistent}" ]; }

vultr_sshkey_id(){
  local pub id; pub=$(awk '{print $1" "$2}' "$SSH_KEY.pub")
  id=$(vu "$VU_API/ssh-keys" | python3 -I -c 'import json,sys
pub=sys.argv[1]
for k in json.load(sys.stdin).get("ssh_keys",[]):
    if " ".join(k["ssh_key"].split()[:2])==pub: print(k["id"]); break' "$pub")
  [ -n "$id" ] || id=$(vu -X POST "$VU_API/ssh-keys" -d "{\"name\":\"ods\",\"ssh_key\":\"$(cat "$SSH_KEY.pub")\"}" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("ssh_key",{}).get("id",""))')
  echo "$id"
}

vultr_stock(){
  local plans; plans=$(curl -s -m 30 "$VU_API/plans-metal")
  while read -r _ plan region; do
    curl -s -m 15 "$VU_API/regions/$region/availability?type=vbm" | python3 -I -c 'import json,sys
plan,region,usd_eur,plans=sys.argv[1],sys.argv[2],float(sys.argv[3]),json.loads(sys.argv[4])
if plan in json.load(sys.stdin).get("available_plans",[]):
    for p in plans["plans_metal"]:
        if p["id"]==plan: print("vultr %s %s %.3f"%(plan,region,p["hourly_cost"]*usd_eur))' "$plan" "$region" "$USD_TO_EUR" "$plans"
  done
}

vultr_create(){
  local plan=$1 region=$2 host=$3 kid os r id
  kid=$(vultr_sshkey_id); [ -n "$kid" ] || { say "vultr: cannot register SSH key"; return; }
  for os in $VULTR_OS_IDS; do
    r=$(vu -X POST "$VU_API/bare-metals" -d "{\"region\":\"$region\",\"plan\":\"$plan\",\"os_id\":$os,\"sshkey_id\":[\"$kid\"],\"hostname\":\"$host\",\"label\":\"$host\",\"tags\":[\"ods\",\"$ODS_OWNER_TAG\"],\"enable_ipv6\":false}")
    id=$(echo "$r" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("bare_metal",{}).get("id",""))' 2>/dev/null)
    [ -n "$id" ] && { echo "$id"; return; }
    say "vultr create (os $os) failed: $(echo "$r" | head -c 300)"
    echo "$r" | grep -q 'cannot be used with the selected plan' || return
  done
}

vultr_state(){
  vu "$VU_API/bare-metals/$1" | python3 -I -c 'import json,sys
b=json.load(sys.stdin).get("bare_metal")
if not b: print("gone"); sys.exit()
ok=b.get("status")=="active" and b.get("main_ip") not in (None,"","0.0.0.0")
print("ready "+b["main_ip"] if ok else "wait")'
}

vultr_destroy(){ vu -X DELETE -o /dev/null -w '%{http_code}' "$VU_API/bare-metals/$1"; }

vultr_list_tagged(){
  vu "$VU_API/bare-metals?tag=$ODS_OWNER_TAG" | python3 -I -c 'import json,sys,datetime
for b in json.load(sys.stdin).get("bare_metals",[]):
    print("vultr", b["id"], b.get("main_ip","-"), int(datetime.datetime.fromisoformat(b["date_created"]).timestamp()))'
}
