#!/bin/bash
# GoCast agent container: route to the route-server subnet via the test
# router, start stand-in services for the port monitors, then run GoCast as
# PID 1 so `docker stop` delivers SIGTERM to it.
set -euo pipefail
ip route add 10.1.0.0/24 via 10.1.10.254
echo "gocast commit: $(cat /gocast.rev)"
# stand-in services: UDP listeners on dns (53) and syslog (514). The test
# kills/restarts these to fail/recover the monitors.
socat -u UDP-RECV:53 /dev/null &
socat -u UDP-RECV:514 /dev/null &
exec gocast -logtostderr -v=2 -config /etc/gocast/gocast.yaml
