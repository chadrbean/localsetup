# monitoring/firewall — Loki/Prometheus LAN allow-list

Loki (`:3100`) and Prometheus (`:9090`) accept pushes from other LAN hosts
(Alloy, see [`../alloy/`](../alloy/README.md)), so they listen on all
interfaces. This nftables table keeps those two ports closed to everything but
loopback and the hosts in `@pushers`. Nothing else on the machine is filtered.

| File | Installed to |
|---|---|
| `monitoring-lan.nft` | `/etc/nftables.d/monitoring-lan.nft` |
| `monitoring-lan-firewall.service` | `/etc/systemd/system/monitoring-lan-firewall.service` |

The table is `inet monitoring_lan`, its own table. It never runs `flush ruleset`,
so podman's and libvirt's rules stay untouched, and re-applying it is idempotent.

## Install / update (sudo, from the main checkout)

```bash
sudo install -Dm644 monitoring/firewall/monitoring-lan.nft /etc/nftables.d/monitoring-lan.nft
sudo install -m644 monitoring/firewall/monitoring-lan-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now monitoring-lan-firewall   # after an update: restart
```

## Verify

```bash
sudo nft list table inet monitoring_lan     # drop counter climbs only for strangers
curl -s 127.0.0.1:3100/ready                # ready (Grafana/Promtail path)
ssh zuriel curl -s 192.168.1.30:3100/ready  # ready (allowed pusher)
# from any other LAN device: curl -m5 192.168.1.30:3100/ready  -> times out
```

## Add a host

Append its static IP to `set pushers` in `monitoring-lan.nft`, then reinstall
it and run `sudo systemctl restart monitoring-lan-firewall`. Record the host in
[`docs/HOSTS.md`](../../docs/HOSTS.md).

Rollback: `sudo systemctl disable --now monitoring-lan-firewall` (ExecStop
deletes the table).
