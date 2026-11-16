#!/bin/bash
# Stand-in UDP service for the GoCast port monitors.
#   stand-in start <port> <vip>: listen on <vip>:<port>, answer every datagram
#                                with this host's name (shows which node served it)
#   stand-in stop <port>
# Binding the VIP before GoCast adds it to lo needs net.ipv4.ip_nonlocal_bind=1.
case $1 in
  start) setsid socat "UDP4-RECVFROM:$2,bind=$3,fork" SYSTEM:hostname >/dev/null 2>&1 < /dev/null & ;;
  stop) pkill -f "UDP4-RECVFROM:$2," ;;
  *) echo "usage: stand-in start <port> <vip> | stop <port>" >&2; exit 2 ;;
esac
