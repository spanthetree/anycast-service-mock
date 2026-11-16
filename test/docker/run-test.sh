#!/usr/bin/env bash
# End-to-end test of the anycast design on the Docker environment in this
# directory (see docker-compose.yml). Renders configs from the real role
# templates, builds GoCast from a git branch, runs the test plan below and
# writes a Markdown report plus full container logs to results/<timestamp>/.
#
# Usage: ./run-test.sh
#   GOCAST_REPO  git URL to build GoCast from (default: spanthetree/gocast)
#   GOCAST_REF   branch to build             (default: multi_peer_v2)
#   KEEP=1       leave the containers running afterwards
#
# Test plan (each check waits up to a timeout for the expected state).
# "Traffic" means the client sends 20 UDP flows to a VIP via core01 and
# counts which nodes answer.
#   1. Sessions: both agents establish BGP with both route servers; each
#      route server with its core switch; the core switches with each other.
#   2. Announce: each route server passes both agents' paths for both VIPs
#      to its core switch unchanged (next hop = agent, AS path = agent only);
#      both core switches install both agents as ECMP next hops; the VIP
#      outside anycast_allowed_prefixes is filtered. Traffic reaches both
#      nodes; the filtered VIP gets no answer.
#   3. Stopping the syslog service on dns01 withdraws only dns01's syslog
#      route; syslog traffic goes only to syslog01.
#   4. Restarting it brings the route and traffic back to both nodes.
#   5. Stopping rs01: core01 keeps both nodes as next hops via core02 (iBGP),
#      and traffic still reaches both.
#   6. Starting rs01 again: its sessions and routes come back.
#   7. Stopping dns01 (SIGTERM): it shuts down its sessions cleanly, its
#      routes disappear everywhere, and all traffic goes to syslog01.
#   8. Only if the GoCast build reloads config on SIGHUP: reloading
#      syslog01 with an unchanged config leaves BGP alone; with peer_ips
#      reduced to rs01 it moves its session and routes off rs02 (core02
#      keeps them via core01); with the original config restored they come back.
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
# in_svc <service|host> <command>: run in a container, or on the host for "host"
in_svc() {
  if [ "$1" = host ]; then bash -c "$2" 2>&1 || true; else dc exec -T "$1" sh -c "$2" 2>&1 || true; fi
}
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

DNS_VIP=10.20.0.53/32
SYS_VIP=10.20.0.54/32
ROGUE_VIP=10.99.0.1/32
DNS01=10.1.10.11
SYSLOG01=10.1.10.21

NBR='gobgp neighbor'
# what a route server sends its core switch
declare -A RS_CORE=([rs01]=10.1.0.1 [rs02]=10.1.0.2)
toCore() { echo "gobgp neighbor ${RS_CORE[$1]} adj-out"; }
# BGP routes the core switch installed in the kernel: "<prefix> <next hop> "
FIB=/opt/test/core-fib
CORE_PEERS=/opt/test/core-peers
INFO='curl -s localhost:8080/info | jq -r ".[] | \"\(.conf.neighbor_address) state \(.state.session_state) multihop \(.ebgp_multihop.enabled)\""'
# traffic <vip:port> [flows]: answers per node from the client, "no-reply" if none
traffic() {
  echo "for i in \$(seq ${2:-20}); do r=\$(echo q | socat -T1 - UDP4:$1,sourceport=\$((30000+i)) 2>/dev/null); echo \"\${r:-no-reply}\"; done | sort | uniq -c"
}
DNS_TRAFFIC=$(traffic 10.20.0.53:53)
SYS_TRAFFIC=$(traffic 10.20.0.54:514)
ROGUE_TRAFFIC=$(traffic 10.99.0.1:5353 3)

# conditions: route to <vip> via <next hop>; for adj-out also AS path = agent only
has() { echo "g '$1 +$2 '"; }
hasnt() { echo "! g '$1 +$2 '"; }
sent() { echo "g '$1 +$2 +65010 '"; }
# all four agent paths (both VIPs from both agents)
all_fib() { echo "$(has $DNS_VIP $DNS01) && $(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $DNS01) && $(has $SYS_VIP $SYSLOG01)"; }
all_sent() { echo "$(sent $DNS_VIP $DNS01) && $(sent $DNS_VIP $SYSLOG01) && $(sent $SYS_VIP $DNS01) && $(sent $SYS_VIP $SYSLOG01)"; }
BOTH_ANSWER="g ' dns01\$' && g ' syslog01\$' && ! g 'no-reply'"
ONLY_SYSLOG01="g ' syslog01\$' && ! g ' dns01\$' && ! g 'no-reply'"

echo "== render configs"
ANSIBLE_LOCAL_TEMP=${TMPDIR:-/tmp}/ansible-local ANSIBLE_REMOTE_TEMP=${TMPDIR:-/tmp}/ansible-remote ANSIBLE_HOME=${TMPDIR:-/tmp}/ansible-home \
  ansible-playbook -i ../../inventories/example/hosts.yml render.yml >"$OUT/logs/render.log"
cp -r generated "$OUT/generated"

echo "== build and start (GoCast $GOCAST_REPO @ $GOCAST_REF)"
dc down -t 5 --remove-orphans >/dev/null 2>&1 || true
dc build >"$OUT/logs/build.log" 2>&1
dc up -d >>"$OUT/logs/build.log" 2>&1

{
  echo "# Anycast test report"
  echo
  echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- GoCast: $GOCAST_REPO @ $GOCAST_REF ($(dc exec -T dns01 cat /gocast.rev))"
  echo "- Route servers: $(dc exec -T rs01 gobgpd --version 2>&1 | head -1). Core switches: FRR $(dc exec -T core01 sh -c 'vtysh -c "show version"' 2>/dev/null | grep -oE 'FRRouting [0-9.]+' | head -1)"
  echo "- Topology (examples/assets/anycast-deployment.png): agents dns01 ($DNS01) and syslog01 ($SYSLOG01),"
  echo "  AS 65010, each peer with route servers rs01 (10.1.0.11) and rs02 (10.1.0.12), AS 65000, over"
  echo "  eBGP multihop. rs01 feeds core01 (10.1.0.1), rs02 feeds core02 (10.1.0.2), AS 64512; the core"
  echo "  switches iBGP with each other, install the VIP routes and forward the client's (10.1.10.100)"
  echo "  traffic straight to the agents."
  echo "- Both agents announce the dns VIP $DNS_VIP and the syslog VIP $SYS_VIP (UDP port monitors on"
  echo "  53 and 514; socat stand-ins that answer with the node's name), with community 65010:100."
  echo "  dns01 also announces $ROGUE_VIP, outside anycast_allowed_prefixes, which must be filtered."
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
  expect "$rs has Established sessions with both agents and ${RS_CORE[$rs]}" 90 $rs "$NBR" \
    "g '^$DNS01 .*Establ' && g '^$SYSLOG01 .*Establ' && g '^${RS_CORE[$rs]//./\\.} .*Establ'"
done
expect "core01 has Established sessions with rs01 and core02" 60 core01 "$CORE_PEERS" \
  "g '^10\.1\.0\.11 65000 Established' && g '^10\.1\.0\.2 64512 Established'"
expect "core02 has Established sessions with rs02 and core01" 60 core02 "$CORE_PEERS" \
  "g '^10\.1\.0\.12 65000 Established' && g '^10\.1\.0\.1 64512 Established'"
say "- Agent view of its peers (session_state 6 = Established):"
block dns01 "$INFO"
block syslog01 "$INFO"
{ echo; echo "dns01 log:"; echo '```'; dc logs --no-log-prefix dns01 2>&1 | grep -E 'gocast commit|Registered a new app|Add a peer|Peer Up'; echo '```'; } >>"$REPORT"

say ""
say "## 2. VIPs announced; core switches route straight to the agents"
for rs in rs01 rs02; do
  expect "$rs sends ${RS_CORE[$rs]} both agents' paths, next hop and AS path unchanged; not $ROGUE_VIP" 60 $rs "$(toCore $rs)" \
    "$(all_sent) && ! g '${ROGUE_VIP%/32}'"
done
for core in core01 core02; do
  expect "$core installs both VIPs with both agents as ECMP next hops; not $ROGUE_VIP" 60 $core "$FIB" \
    "$(all_fib) && ! g '${ROGUE_VIP%/32}'"
done
block core01 'vtysh -c "show bgp ipv4 unicast"'
expect "dns VIP traffic reaches both nodes" 30 client "$DNS_TRAFFIC" "$BOTH_ANSWER"
expect "syslog VIP traffic reaches both nodes" 30 client "$SYS_TRAFFIC" "$BOTH_ANSWER"
expect "filtered VIP $ROGUE_VIP gets no answer" 10 client "$ROGUE_TRAFFIC" "g 'no-reply' && ! g 'dns01'"

say ""
say "## 3. Monitor failure withdraws the VIP"
say "- Stopping the syslog stand-in (udp/514) on dns01."
in_svc dns01 "stand-in stop 514" >/dev/null
for rs in rs01 rs02; do
  expect "$rs withdraws dns01's syslog path from ${RS_CORE[$rs]}, keeps the rest" 30 $rs "$(toCore $rs)" \
    "! g '${SYS_VIP} +$DNS01 ' && $(sent $SYS_VIP $SYSLOG01) && $(sent $DNS_VIP $DNS01)"
done
for core in core01 core02; do
  expect "$core routes the syslog VIP only to syslog01" 30 $core "$FIB" \
    "$(hasnt $SYS_VIP $DNS01) && $(has $SYS_VIP $SYSLOG01) && $(has $DNS_VIP $DNS01)"
done
expect "syslog VIP traffic reaches only syslog01, none lost" 30 client "$SYS_TRAFFIC" "$ONLY_SYSLOG01"
# GoCast withdraws the route at once but keeps the loopback address (and any
# NAT rules) until cleanup_timer expires, so a quick recovery needs no re-add.
expect "dns01 keeps the syslog VIP on its loopback until cleanup_timer (15m)" 10 dns01 "ip -4 -o addr show dev lo" \
  "g '${SYS_VIP%/32}/'"
{ echo; echo "dns01 log:"; echo '```'; dc logs --no-log-prefix dns01 2>&1 | grep -E 'syslog Failed' | tail -2; echo '```'; } >>"$REPORT"

say ""
say "## 4. Monitor recovery re-announces the VIP"
in_svc dns01 "stand-in start 514 ${SYS_VIP%/32}" >/dev/null
for core in core01 core02; do
  expect "$core routes the syslog VIP to both nodes again" 30 $core "$FIB" "$(all_fib)"
done
expect "syslog VIP traffic reaches both nodes again" 30 client "$SYS_TRAFFIC" "$BOTH_ANSWER"

say ""
say "## 5. Route server failure"
say "- Stopping rs01 (core01's route server)."
dc stop -t 5 rs01 >/dev/null 2>&1
expect "dns01 sees rs01 down and rs02 Established" 30 dns01 "$INFO" \
  "g '^10\.1\.0\.11 state [^6]' && g '^10\.1\.0\.12 state 6'"
expect "core01 lost rs01 but keeps both agents as next hops via core02" 30 core01 "$CORE_PEERS; $FIB" \
  "! g '^10\.1\.0\.11 65000 Established' && $(all_fib)"
expect "core02 is unaffected" 10 core02 "$FIB" "$(all_fib)"
expect "dns VIP traffic via core01 still reaches both nodes" 30 client "$DNS_TRAFFIC" "$BOTH_ANSWER"

say ""
say "## 6. Route server recovery"
say "- Starting rs01."
dc start rs01 >/dev/null 2>&1
expect "rs01 re-establishes with both agents and core01" 90 rs01 "$NBR" \
  "g '^$DNS01 .*Establ' && g '^$SYSLOG01 .*Establ' && g '^10\.1\.0\.1 .*Establ'"
expect "rs01 sends core01 both agents' paths again" 60 rs01 "$(toCore rs01)" "$(all_sent)"
expect "core01 has rs01's paths again" 60 core01 'vtysh -c "show bgp ipv4 unicast"' \
  "g '^ \*[>=] +(10\.20\.0\.5[34]/32 +)?10\.1\.10\.(11|21) +0 65010 i'"

say ""
say "## 7. Graceful agent shutdown withdraws its routes"
say "- Stopping dns01 (SIGTERM)."
dc stop -t 10 dns01 >/dev/null 2>&1
EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$(dc ps -aq dns01)")
if [ "$EXIT" = 0 ]; then PASSED=$((PASSED + 1)); say "- PASS: dns01 exited with code 0"; else FAILED=$((FAILED + 1)); say "- **FAIL**: dns01 exited with code $EXIT"; fi
for rs in rs01 rs02; do
  expect "$rs no longer has dns01's session or paths; syslog01's remain" 30 $rs "$(toCore $rs); echo; $NBR" \
    "! g ' $DNS01 ' && ! g '^$DNS01 ' && $(sent $DNS_VIP $SYSLOG01) && $(sent $SYS_VIP $SYSLOG01)"
done
for core in core01 core02; do
  expect "$core routes both VIPs only to syslog01" 30 $core "$FIB" \
    "$(hasnt $DNS_VIP $DNS01) && $(hasnt $SYS_VIP $DNS01) && $(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $SYSLOG01)"
done
expect "dns VIP traffic reaches only syslog01, none lost" 30 client "$DNS_TRAFFIC" "$ONLY_SYSLOG01"
{ echo; echo "dns01 log, shutdown:"; echo '```'; dc logs --no-log-prefix dns01 2>&1 | sed -n '/Shutting down all open bgp sessions/,$p'; echo '```'; } >>"$REPORT"

# Step 8 runs only if this GoCast build reloads its config on SIGHUP.
if [ "$(in_svc syslog01 "grep -ac 'reloading configuration' /usr/local/bin/gocast")" != 0 ]; then
  CFG=generated/gocast-syslog01.yaml
  ORIG=$(cat "$CFG")
  # rewrite in place (the file is bind-mounted, so its inode must not change), then SIGHUP
  # sleep 1: `logs --since` has 1s resolution; keep each reload's log window separate
  reload() { sleep 1; cat >"$CFG"; export MARK=$(date -u +%Y-%m-%dT%H:%M:%SZ); dc kill -s HUP syslog01 >/dev/null 2>&1; }
  LOGS='docker compose logs --no-log-prefix --since $MARK syslog01'
  SYSLOG01_UP="$(sent $DNS_VIP $SYSLOG01) && $(sent $SYS_VIP $SYSLOG01)"

  say ""
  say "## 8. Config reload (SIGHUP) on syslog01"
  say "- SIGHUP with the config unchanged."
  reload <<<"$ORIG"
  expect "syslog01 reloads without restarting BGP" 15 host "$LOGS" \
    "g 'Configuration reloaded successfully' && ! g 'BGP configuration changed'"
  for rs in rs01 rs02; do
    expect "$rs keeps syslog01's session and paths" 5 $rs "$(toCore $rs); echo; $NBR" \
      "$SYSLOG01_UP && g '^$SYSLOG01 .*Establ'"
  done

  say "- SIGHUP with peer_ips reduced to rs01."
  reload <<<"$(grep -v '"10.1.0.12"' <<<"$ORIG")"
  expect "syslog01 restarts BGP with the new peer list" 15 host "$LOGS" \
    "g 'BGP configuration changed' && g 'Configuration reloaded successfully'"
  expect "rs02 no longer has syslog01's session or paths" 30 rs02 "$(toCore rs02); echo; $NBR" \
    "! g ' $SYSLOG01 ' && ! g '^$SYSLOG01 '"
  expect "rs01 has syslog01's session and paths" 60 rs01 "$(toCore rs01); echo; $NBR" \
    "$SYSLOG01_UP && g '^$SYSLOG01 .*Establ'"
  expect "core02 still routes both VIPs to syslog01 (via core01)" 30 core02 "$FIB" \
    "$(has $DNS_VIP $SYSLOG01) && $(has $SYS_VIP $SYSLOG01)"
  { echo; echo "syslog01 log:"; echo '```'; in_svc host "$LOGS" | grep -vE 'All Monitors'; echo '```'; } >>"$REPORT"

  say "- SIGHUP with the original config restored."
  reload <<<"$ORIG"
  for rs in rs01 rs02; do
    expect "$rs has syslog01's session and paths again" 60 $rs "$(toCore $rs); echo; $NBR" \
      "$SYSLOG01_UP && g '^$SYSLOG01 .*Establ'"
  done
else
  say ""
  say "## 8. Config reload (SIGHUP): skipped, this GoCast build has no config reload"
fi

for s in $(dc config --services); do dc logs --no-color --timestamps "$s" >"$OUT/logs/$s.log" 2>&1; done
{ echo; echo "## Summary"; echo; echo "$PASSED passed, $FAILED failed. Full container logs: logs/"; } >>"$REPORT"
[ "${KEEP:-0}" = 1 ] || dc down -t 5 >/dev/null 2>&1

echo
echo "$PASSED passed, $FAILED failed. Report: $REPORT"
[ "$FAILED" = 0 ]
