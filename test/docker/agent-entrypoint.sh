#!/bin/bash
# GoCast agent container: route to the route-server subnet via core01, start
# stand-in services for the port monitors, then run GoCast as PID 1 so
# `docker stop` delivers SIGTERM to it.
set -euo pipefail
ip route add 10.1.0.0/24 via 10.1.10.1
echo "gocast commit: $(cat /gocast.rev)"
# dns and syslog VIPs (role defaults), plus a VIP outside anycast_allowed_prefixes
# that the route servers must reject. The test stops/starts these to fail/recover
# the monitors.
stand-in start 53 10.20.0.53
stand-in start 514 10.20.0.54
stand-in start 5353 10.99.0.1
exec gocast -logtostderr -v=2 -config /etc/gocast/gocast.yaml
