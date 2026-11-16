#!/usr/bin/env bash
# End-to-end GoCast multi-peer test on the Docker environment in this
# directory. Renders configs from the real role templates, builds GoCast from
# a git branch, runs the test plan below and writes a Markdown report plus
# full container logs to results/<timestamp>/.
#
# Usage: ./run-test.sh
#   GOCAST_REPO  git URL to build GoCast from (default: spanthetree/gocast)
#   GOCAST_REF   branch to build             (default: multi_peer_v2)
#   KEEP=1       leave the containers running afterwards
#
# Test plan (each step waits up to a timeout for the expected state):
#   1. Both agents establish BGP with both route servers; route servers
#      establish with both core switches.
#   2. Both VIPs are announced by both agents and reach both route servers
#      and both core switches.
#   3. Stopping the syslog service on dns01 withdraws only dns01's syslog VIP.
#   4. Restarting it re-announces the VIP.
#   5. Stopping route server rs01: agents keep announcing via rs02, and the
#      core switches keep the VIPs via rs02.
#   6. Starting rs01 again: sessions re-establish and routes return via rs01.
#   7. Stopping dns01 (SIGTERM): it shuts down its sessions cleanly and its
#      routes are withdrawn from both route servers; syslog01's stay.
set -euo pipefail
cd "$(dirname "$0")"

export GOCAST_REPO=${GOCAST_REPO:-https://github.com/spanthetree/gocast.git}
export GOCAST_REF=${GOCAST_REF:-multi_peer_v2}
export GOCAST_TAG=${GOCAST_REF//[^A-Za-z0-9_.-]/_}

OUT=results/$(date +%Y%m%d-%H%M%S)
REPORT=$OUT/report.md
mkdir -p "$OUT/logs"
PASSED=0
FAILED=0

dc() { docker compose "$@"; }
in_svc() { dc exec -T "$1" bash -c "$2" 2>&1 || true; }
say() { echo "$*" | tee -a "$REPORT"; }

# block <service> <command>: append a command and its output to the report
block() {
  { echo; echo '```'; echo "[$1]\$ $2"; in_svc "$1" "$2"; echo '```'; } >>"$REPORT"
}

# expect <description> <timeout s> <service> <command> <bash condition>
# The condition can use `g <regex>` to match the command's output.
# Polls the command until the condition holds, records PASS/FAIL and output.
expect() {
  local desc=$1 timeout=$2 svc=$3 cmd=$4 cond=$5 start=$SECONDS out ok=0
  while :; do
    out=$(in_svc "$svc" "$cmd")
    # g <regex>: true if the command output matches
    if OUT=$out bash -c 'g() { grep -qE "$1" <<<"$OUT"; }; '"$cond"; then ok=1; break; fi
    ((SECONDS - start >= timeout)) && break
    sleep 2
  done
  if ((ok)); then
    PASSED=$((PASSED + 1)); say "- PASS ($((SECONDS - start))s): $desc"
  else
    FAILED=$((FAILED + 1)); say "- **FAIL** (timed out after ${timeout}s): $desc"
  fi
  { echo; echo '```'; echo "[$svc]\$ $cmd"; echo "$out"; echo '```'; } >>"$REPORT"
}

RIB='gobgp global rib -a ipv4'
NBR='gobgp neighbor'
INFO='curl -s localhost:8080/info | jq -r ".[] | \"\(.conf.neighbor_address) state \(.state.session_state) multihop \(.ebgp_multihop.enabled)\""'
# rib line for <vip> with next hop <ip>
has() { echo "g '$1 +$2 '"; }
hasnt() { echo "! g '$1 +$2 '"; }
DNS_VIP=10.20.0.53/32
SYS_VIP=10.20.0.54/32
DNS01=10.1.10.11
SYSLOG01=10.1.10.21

echo "== render configs"
ANSIBLE_LOCAL_TEMP=${TMPDIR:-/tmp}/ansible-local ANSIBLE_REMOTE_TEMP=${TMPDIR:-/tmp}/ansible-remote ANSIBLE_HOME=${TMPDIR:-/tmp}/ansible-home \
  ansible-playbook -i ../../inventories/example/hosts.yml render.yml >"$OUT/logs/render.log"
cp -r generated "$OUT/generated"

echo "== build and start (GoCast $GOCAST_REPO @ $GOCAST_REF)"
dc down -t 5 >/dev/null 2>&1 || true
dc build >"$OUT/logs/build.log" 2>&1
dc up -d >>"$OUT/logs/build.log" 2>&1

{
  echo "# GoCast multi-peer test report"
  echo
  echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- GoCast: $GOCAST_REPO @ $GOCAST_REF ($(dc exec -T dns01 cat /gocast.rev))"
  echo "- GoBGP (route servers and core switches): $(dc exec -T rs01 gobgpd --version 2>&1 | head -1)"
  echo "- Topology: agents dns01 ($DNS01) and syslog01 ($SYSLOG01), AS 65010, each peering with"
  echo "  route servers rs01 (10.1.0.11) and rs02 (10.1.0.12), AS 65000, through a router (eBGP multihop)."
  echo "  Route servers peer with core switches core01 (10.1.0.1) and core02 (10.1.0.2), AS 64512."
  echo "- Both agents announce the dns VIP $DNS_VIP and the syslog VIP $SYS_VIP (UDP port monitors"
  echo "  on 53 and 514, with socat as the stand-in service), with community 65010:100."
  echo
  echo "Agent config (dns01):"
  echo
  echo '```yaml'
  cat generated/gocast-dns01.yaml
  echo '```'
} >"$REPORT"

say ""
say "## 1. BGP sessions establish"
for rs in rs01 rs02; do
  expect "$rs has Established sessions with both agents" 90 $rs "$NBR" \
    "g '^$DNS01 .*Establ' && g '^$SYSLOG01 .*Establ'"
done
for core in core01 core02; do
  expect "$core has Established sessions with both route servers" 60 $core "$NBR" \
    "g '^10\.1\.0\.11 .*Establ' && g '^10\.1\.0\.12 .*Establ'"
done
say "- Agent view of its peers (session_state 6 = Established):"
block dns01 "$INFO"
block syslog01 "$INFO"
{ echo; echo "dns01 log:"; echo '```'; dc logs --no-log-prefix dns01 2>&1 | grep -E 'gocast commit|Registered a new app|Add a peer|Peer Up'; echo '```'; } >>"$REPORT"

say ""
say "## 2. VIPs announced to both route servers and propagated to the core"
for rs in rs01 rs02; do
  expect "$rs has both VIPs from both agents" 60 $rs "$RIB" \
    "$(has $DNS_VIP $DNS01) && $(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $DNS01) && $(has $SYS_VIP $SYSLOG01)"
done
for core in core01 core02; do
  expect "$core has both VIPs via both route servers" 60 $core "$RIB" \
    "$(has $DNS_VIP 10.1.0.11) && $(has $DNS_VIP 10.1.0.12) && $(has $SYS_VIP 10.1.0.11) && $(has $SYS_VIP 10.1.0.12)"
done

say ""
say "## 3. Monitor failure withdraws the VIP"
say "- Stopping the syslog stand-in (udp/514) on dns01."
in_svc dns01 "pkill -f 'UDP-RECV:514'" >/dev/null
for rs in rs01 rs02; do
  expect "$rs drops dns01's syslog VIP, keeps syslog01's and both dns VIPs" 30 $rs "$RIB" \
    "$(hasnt $SYS_VIP $DNS01) && $(has $SYS_VIP $SYSLOG01) && $(has $DNS_VIP $DNS01)"
done
# GoCast withdraws the route at once but keeps the loopback address (and any
# NAT rules) until cleanup_timer expires, so a quick recovery needs no re-add.
expect "dns01 keeps the syslog VIP on its loopback until cleanup_timer (15m)" 10 dns01 "ip -4 -o addr show dev lo" \
  "g '${SYS_VIP%/32}/'"
{ echo; echo "dns01 log:"; echo '```'; dc logs --no-log-prefix dns01 2>&1 | grep -E 'syslog Failed' | tail -2; echo '```'; } >>"$REPORT"

say ""
say "## 4. Monitor recovery re-announces the VIP"
dc exec -d dns01 socat -u UDP-RECV:514 /dev/null
for rs in rs01 rs02; do
  expect "$rs has dns01's syslog VIP again" 30 $rs "$RIB" "$(has $SYS_VIP $DNS01)"
done

say ""
say "## 5. Route server failure: the other route server keeps the VIPs"
say "- Stopping rs01."
dc stop -t 5 rs01 >/dev/null 2>&1
expect "dns01 sees rs01 down and rs02 Established" 30 dns01 "$INFO" \
  "g '^10\.1\.0\.11 state [^6]' && g '^10\.1\.0\.12 state 6'"
for rs in rs02; do
  expect "$rs still has both VIPs from both agents" 10 $rs "$RIB" \
    "$(has $DNS_VIP $DNS01) && $(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $DNS01) && $(has $SYS_VIP $SYSLOG01)"
done
for core in core01 core02; do
  expect "$core keeps both VIPs via rs02 only" 30 $core "$RIB" \
    "$(has $DNS_VIP 10.1.0.12) && $(has $SYS_VIP 10.1.0.12) && $(hasnt $DNS_VIP 10.1.0.11)"
done

say ""
say "## 6. Route server recovery"
say "- Starting rs01."
dc start rs01 >/dev/null 2>&1
expect "rs01 re-establishes with both agents" 90 rs01 "$NBR" \
  "g '^$DNS01 .*Establ' && g '^$SYSLOG01 .*Establ'"
expect "rs01 has both VIPs from both agents again" 60 rs01 "$RIB" \
  "$(has $DNS_VIP $DNS01) && $(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $DNS01) && $(has $SYS_VIP $SYSLOG01)"
expect "core01 has the VIPs via both route servers again" 60 core01 "$RIB" \
  "$(has $DNS_VIP 10.1.0.11) && $(has $DNS_VIP 10.1.0.12)"

say ""
say "## 7. Graceful agent shutdown withdraws its routes"
say "- Stopping dns01 (SIGTERM)."
dc stop -t 10 dns01 >/dev/null 2>&1
EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$(dc ps -aq dns01)")
if [ "$EXIT" = 0 ]; then PASSED=$((PASSED + 1)); say "- PASS: dns01 exited with code 0"; else FAILED=$((FAILED + 1)); say "- **FAIL**: dns01 exited with code $EXIT"; fi
for rs in rs01 rs02; do
  expect "$rs no longer has dns01's session or routes; syslog01's remain" 30 $rs "$RIB; echo; $NBR" \
    "$(hasnt $DNS_VIP $DNS01) && $(hasnt $SYS_VIP $DNS01) && $(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $SYSLOG01)"
done
{ echo; echo "dns01 log, shutdown:"; echo '```'; dc logs --no-log-prefix dns01 2>&1 | sed -n '/Shutting down all open bgp sessions/,$p'; echo '```'; } >>"$REPORT"

for s in $(dc config --services); do dc logs --no-color --timestamps "$s" >"$OUT/logs/$s.log" 2>&1; done
{ echo; echo "## Summary"; echo; echo "$PASSED passed, $FAILED failed. Full container logs: logs/"; } >>"$REPORT"
[ "${KEEP:-0}" = 1 ] || dc down -t 5 >/dev/null 2>&1

echo
echo "$PASSED passed, $FAILED failed. Report: $REPORT"
[ "$FAILED" = 0 ]
