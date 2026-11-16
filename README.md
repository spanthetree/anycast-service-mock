# Anycast Service Ansible Reconstruction

This is a general reconstruction of the ansible roles and configs for 'Anycast-as-a-Service'.

The important pattern is:

```text
dns/syslog roles declare service subscription metadata
  -> gocast role consumes local anycast_services
  -> GoCast monitors subscribed local services
  -> healthy services advertise /32 VIPs
  -> routeserver role deploys 2x GoBGP route servers in each datacenter
  -> route servers peer with agents _and_ core switches
  -> route servers readvertise permitted VIP routes into the datacenter network
```

## Deployment Diagram

![Anycast deployment diagram](examples/assets/anycast-deployment.png)


## Project Requirements

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

## Role Responsibilities

`dns`
: Installs/configures a DNS service and registers DNS with the host-local `anycast_services` list when `dns.anycast` is enabled. Its monitor defaults to `exec`, not a plain port check: `dns_check.sh.j2` renders to `dns_check_script` (`/usr/local/lib/gocast-checks/dns_check.sh` by default) and checks that `dns.service_name` is active, then resolves each domain in `dns_check_domains` against `127.0.0.1` with `dig`, failing (and so withdrawing the VIP) if the service is down or any resolution fails. `named.conf.options.j2` sets `recursion yes` (`dns.recursion`, default `true`). A pool meant to sit in clients' `resolv.conf` has to actually resolve arbitrary names, and the healthcheck domains would never succeed against a non-recursive server. `dns_check_package` (default `dnsutils`) installs `dig` only when the exec monitor is in use.

`syslog`
: Installs/configures rsyslog and registers Syslog with `anycast_services` when `syslog.anycast` is enabled. Its monitor is a plain UDP port check on 514. Syslog just needs to be listening; there's no equivalent "resolve a few real records" check to run.

`gocast`
: Installs/renders the GoCast agent on application hosts. Public upstream GoCast only peers with one BGP speaker, so this reconstruction needs the multi-peer GoCast build from the [`multi_peer_v2`](https://github.com/spanthetree/gocast/tree/multi_peer_v2) branch. It lets a single agent per server peer with both route servers, using the `peer_ips` list. See [GoCast Fork Changes Required](#gocast-fork-changes-required) below for what that branch changes.

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
  - name: rs02
    address: 10.1.0.12
```

```text
gocast.service -> /etc/gocast/gocast.yaml -> peer_ips [10.1.0.11, 10.1.0.12]
```

One instance, one `anycast_services` subscription list, one BGP session to every route server. GoCast's embedded GoBGP speaker advertises each announced VIP to all of its established peers, so no per-peer duplication is needed on the agent side. The systemd unit is ordered after the subscribed service units declared by the service roles.

`routeserver`
: Installs/renders the GoBGP route-server configuration in each datacenter. Route servers peer with Anycast agents on one side and core switches on the other, then export only approved Anycast VIP prefixes into the datacenter network with ECMP (`[global.use-multiple-paths.config] enabled = true`, toggled by `routeserver_multipath_enabled`, default `true`), so the core switch load-balances across every healthy anycast node instead of taking a single best path. The `ANYCAST_AGENTS` peer group enables `ebgp-multihop` whenever `gocast_asn` differs from `rs_asn`: agents sit on other subnets than the route servers, and GoCast enables multihop on its side for eBGP peers by default.

The example inventory intentionally uses ordinary pre-existing groups:

```yaml
dns_servers:
syslog_servers:
bgp_route_servers:
```

Anycast subscription is not represented as an inventory group. It is introduced by service role variables (`anycast: true`, `vip`) and by assigning the `gocast` role after the local service role has registered its metadata.

## GoCast Fork Changes Required

Public upstream GoCast (`mayuresh82/gocast`) only supports a single BGP peer per process (`bgp.peer_ip`/`bgp.peer_as`, singular). The `peer_ips` list this reconstruction relies on comes from the [`multi_peer_v2`](https://github.com/spanthetree/gocast/tree/multi_peer_v2) branch. It builds on upstream PR [#33](https://github.com/mayuresh82/gocast/pull/33) (multi-peer and BGP MD5 auth), plus fixes:

Peer config (`config/config.go`, `controller/bgp.go`)
: `peer_ip` (legacy, single), `peer_ips` (list of IPs) and `peers` (list of objects with optional per-peer `peer_as`, `multi_hop`, `md5_password`/`md5_env_var`) are merged into one peer list in that order, de-duplicated by IP. Peers without their own `peer_as` use the top-level `peer_as`. Invalid peer IPs fail at startup. The default gateway is used only if no peer is configured at all. This role only needs `peer_ips`, since both route servers share `rs_asn`.

Multihop
: Enabled by default for eBGP peers (`peer_as` differs from `local_as`), as in single-peer upstream GoCast. `multi_hop` on a `peers` entry overrides it. The agents here are eBGP and on other subnets than the route servers, so they need it; the route-server side matches it in the `ANYCAST_AGENTS` peer group.

Announce/withdraw
: Missing peers are added to GoBGP on the first announce. The VIP path is then added to (or removed from) GoBGP's RIB once, and GoBGP sends it to every established peer. A peer that fails to add does not block the announcement to the rest. Communities are global plus per-VIP only; per-peer communities are not supported, because GoBGP keeps one local path per prefix.

`/info` and shutdown
: `/info` returns a JSON list with one entry per configured peer, instead of one object. `Shutdown()` shuts down only the peers GoBGP knows about, and always stops the local BGP server.

Validated end-to-end in Linux network namespaces, using only the files this repo renders: the `multi_peer_v2` `gocast` binary ran with `examples/generated/gocast/gocast.yaml` in an agent namespace (`10.1.10.11`), and real `gobgpd` (the GoBGP version GoCast vendors) ran with `examples/generated/routeserver/gobgpd-rs01.conf` and `gobgpd-rs02.conf` in two more namespaces (`10.1.0.11`, `10.1.0.12`), each joined to the agent by a veth link. Both route servers accepted the agent through the `ANYCAST_AGENTS` dynamic-neighbor group and reached Established. Both had `10.20.0.54/32` (syslog) in their RIB with next hop `10.1.10.11` while its port check passed, and dropped it once the check failed. GoCast exited cleanly on `SIGTERM`. Not covered by that test: the `dns` app (its check script was not installed), export to the core switches (none were running), and the multihop TTL path (the veth links are directly connected).

## Example Run

`examples/render.yml` renders the same templates the real roles use, but without needing root or the target OS/packages. It does not hand-copy `dns`/`syslog`/`gocast`/`routeserver` variable values. It loads the actual role `defaults/main.yml` files and the actual `inventories/example/group_vars/all/anycast.yml` via `vars_files`, then derives `anycast_services` from `dns`/`syslog` the same way `roles/dns/tasks/main.yml` and `roles/syslog/tasks/main.yml` do. Changing a role default or `group_vars` value changes the example output on the next run, with nothing to keep in sync by hand.

Render example GoCast and route-server configs:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
ANSIBLE_HOME=/tmp/ansible-home \
ansible-playbook examples/render.yml
```

Every template in `roles/gocast/templates/` and `roles/routeserver/templates/` gets a rendered example, not just the config files:

```text
examples/generated/gocast/gocast.yaml
examples/generated/gocast/gocast.service
examples/generated/routeserver/gobgpd-rs01.conf
examples/generated/routeserver/gobgpd-rs02.conf
examples/generated/routeserver/gobgpd.service
```

`gobgpd.service.j2` renders once, not once per route server. Unlike `gobgpd.conf.j2` (which differs per route server by `router-id`), the systemd unit has no per-instance content, so a `gobgpd-rs01.service`/`gobgpd-rs02.service` split would just be two identical files.

Syntax check:

```bash
ansible-playbook -i inventories/example/hosts.yml playbooks/site.yml --syntax-check
```

Dry run:

```bash
ansible-playbook -i inventories/example/hosts.yml playbooks/site.yml --check --diff
```

The example inventory uses local connection and placeholder package names. Adjust package names, binary deployment, ASNs, and peer addresses for the target OS/network.
