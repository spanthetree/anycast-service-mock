# Anycast Service Ansible Reconstruction

This is a reconstructed Ansible repository for the Anycast-as-a-Service design discussed in the shared chat.

The important pattern is:

```text
dns/syslog roles declare service subscription metadata
  -> gocast role consumes local anycast_services
  -> GoCast monitors subscribed local services
  -> healthy services advertise /32 VIPs
  -> routeserver role deploys GoBGP route servers in each datacenter
  -> route servers peer with agents and core switches
  -> route servers forward permitted VIP routes into the datacenter network
```

## Deployment Diagram

![Anycast deployment diagram](examples/assets/anycast-deployment.png)

It is not intended to be the original historical source. It is a plausible role layout using conventional Ansible structure and a simple service metadata model: `anycast: true` plus `vip`.

## Requirements Captured

- Improve DNS reliability by giving a pool of DNS servers a shared VIP that production servers and containers can place in `resolv.conf`.
- Improve network-device Syslog reliability with a static VIP instead of a DNS name, since many network devices require literal IP targets.
- Monitor subscribed services locally and perform automated failover/failback from GoCast monitor results.
- Make services easy to subscribe to Anycast by setting service metadata such as `anycast: true` and `vip`.
- Define agent and route-server deployment in unique Ansible roles for assignment by a global provisioning service.

## Layout

```text
.
├── ansible.cfg
├── inventories/example/hosts.yml
├── inventories/example/group_vars/all/anycast.yml
├── playbooks/site.yml
└── roles/
    ├── dns/
    ├── syslog/
    ├── gocast/
    └── routeserver/
```

`group_vars/all/anycast.yml` lives beside the inventory it belongs to (`inventories/example/group_vars/all/`), not at the repo root, so Ansible auto-loads it for every host in that inventory without any explicit `vars_files` in `playbooks/site.yml`. A repo-root `group_vars/` is only auto-loaded when the inventory file itself lives at the repo root. With a nested inventory like this one it is silently ignored, which previously left `route_servers`, ASNs, and prefixes undefined for real playbook runs.

## Role Responsibilities

`dns`
: Installs/configures a DNS service and registers DNS with the host-local `anycast_services` list when `dns.anycast` is enabled.

`syslog`
: Installs/configures rsyslog and registers Syslog with `anycast_services` when `syslog.anycast` is enabled.

`gocast`
: Installs/renders the GoCast BGP agent on application hosts. Public upstream GoCast (`mayuresh82/gocast`) only accepts a single `peer_ip`/`peer_as` pair in its BGP config, one peer per process. This reconstruction targets a patched fork that accepts a `peer_ips` list instead, so this role runs a single `gocast.service` per host that peers with every route server at once. See [GoCast Fork Changes Required](#gocast-fork-changes-required) below for exactly what that patch needs to touch.

```yaml
bgp:
  local_as: 65010
  peer_as: 65000
  local_ip: 10.1.10.11
  peer_ips:
    - 10.1.0.11
    - 10.1.0.12
```

```yaml
gocast_asn: 65010
rs_asn: 65000
core_asn: 64512

route_servers:
  - name: rs01
    address: 10.1.0.11
    listen_addr: ":8081"
  - name: rs02
    address: 10.1.0.12
    listen_addr: ":8082"
```

```text
gocast.service -> /etc/gocast/gocast.yaml -> peer_ips [10.1.0.11, 10.1.0.12]
```

One instance, one `anycast_services` subscription list, one BGP session to every route server. GoCast's embedded GoBGP speaker advertises each announced VIP to all of its established peers, so no per-peer duplication is needed on the agent side. The systemd unit is ordered after the subscribed service units declared by the service roles.

`routeserver`
: Installs/renders the GoBGP route-server configuration in each datacenter. Route servers peer with Anycast agents on one side and core switches on the other, then export only approved Anycast VIP prefixes into the datacenter network with ECMP (`[global.use-multiple-paths.config] enabled = true`, toggled by `routeserver_multipath_enabled`, default `true`), so the core switch load-balances across every healthy anycast node instead of taking a single best path.

The example inventory intentionally uses ordinary pre-existing groups:

```yaml
dns_servers:
syslog_servers:
bgp_route_servers:
```

Anycast subscription is not represented as an inventory group. It is introduced by service role variables (`anycast: true`, `vip`) and by assigning the `gocast` role after the local service role has registered its metadata.

## GoCast Fork Changes Required

Public upstream GoCast (`mayuresh82/gocast`) only supports a single BGP peer per process (`bgp.peer_ip`/`bgp.peer_as`, singular). The `peer_ips` list this reconstruction relies on comes from a fork patch, applied at `~/Software/git/gocast`, that adds multi-peer support:

`config/config.go`
: `BgpConfig` gained `PeerIPs []string` (`yaml:"peer_ips"`). The old `PeerIP string` field still works for existing single-peer configs; if both are set, `PeerIP` is folded into the peer list. `PeerAS` stays a single int, every peer is expected to share one AS.

`controller/bgp.go`
: `Controller.peerIP net.IP` became `peerIPs []net.IP`. `NewController` resolves the full peer list (falling back to the default gateway only if none is configured) and derives `localIP` from the first configured peer when `local_ip` isn't set explicitly. `Announce()` loops over `peerIPs` through a new `ensurePeers()` helper that adds any configured peer not yet an established GoBGP neighbor. `PeerInfo()` now returns `[]*api.Peer` (all configured peers) instead of a single `*api.Peer`, which also changes `MonitorMgr.GetInfo()` and the `/info` HTTP endpoint's response shape from one object to a list.
: `AddPath` itself was left untouched; it already announces from GoBGP's RIB to every established peer rather than to one targeted neighbor, so a single unified `Announce()` call reaches all configured peers once they're added as neighbors. There's no way to target a route at one specific peer, `AddPathRequest` has no such field, and none is needed here.
: `Shutdown()` also had to change beyond just looping. The original single-peer version called `ShutdownPeer` unconditionally and returned on error, so it never reached `StopBgp()` if that one peer hadn't been added yet (eg. no route was ever announced before shutdown). Looping that unchanged over multiple peers made the failure more likely, not less, since any one not-yet-established peer would still abort the whole shutdown. The fixed version lists established peers first, only asks GoBGP to shut down the ones actually present, and always calls `StopBgp()` regardless of individual peer errors.

Validated end-to-end against the real patched binary, not just checked for valid YAML: the rendered `gocast.yaml` was parsed with the actual `config.GetConfig()`, run through `NewController`/`PeerInfo`/`Shutdown`, and the compiled `gocast` binary was started against it directly. It registered both `dns` and `syslog` apps correctly and shut down cleanly on `SIGTERM` with no panic.

## Example Run

`examples/render.yml` renders the same templates the real roles use, but without needing root or the target OS/packages. It does not hand-copy `dns`/`syslog`/`gocast`/`routeserver` variable values. It loads the actual role `defaults/main.yml` files and the actual `inventories/example/group_vars/all/anycast.yml` via `vars_files`, then derives `anycast_services` from `dns`/`syslog` the same way `roles/dns/tasks/main.yml` and `roles/syslog/tasks/main.yml` do. Changing a role default or `group_vars` value changes the example output on the next run, with nothing to keep in sync by hand.

Render example GoCast and route-server configs:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
ANSIBLE_HOME=/tmp/ansible-home \
ansible-playbook examples/render.yml
```

Generated examples:

```text
examples/generated/gocast/gocast.yaml
examples/generated/routeserver/gobgpd-rs01.conf
examples/generated/routeserver/gobgpd-rs02.conf
```

Syntax check:

```bash
ansible-playbook -i inventories/example/hosts.yml playbooks/site.yml --syntax-check
```

Dry run:

```bash
ansible-playbook -i inventories/example/hosts.yml playbooks/site.yml --check --diff
```

The example inventory uses local connection and placeholder package names. Adjust package names, binary deployment, ASNs, and peer addresses for the target OS/network.
