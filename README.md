# vpn-compose

Headscale, Headplane and Tailscale exit nodes, deployed as two Komodo stacks.

- `server/` — Headscale and Headplane. One instance, one host.
- `exit-node/` — a Tailscale exit node plus the WARP sidecar that routes its forwarded
  traffic. Fully self-contained: copy the directory to any host, point Komodo at it, and
  it runs there. No dependency on the server stack beyond reaching Headscale over the
  public internet — they don't need to share a host, a Docker network, or even exist in
  the same datacenter.

## Komodo stacks

Two separate stacks, each pointed at its own subdirectory:

- `server`
  - source: this repo + branch, webhook enabled for redeploy on push
  - `run_directory`: `server/`
- `exit-node` (one per host that runs an exit node)
  - source: this repo + branch, webhook enabled for redeploy on push
  - `run_directory`: `exit-node/`
  - `extra_args`: `--build`
  - environment: `EXIT_NODE_HOSTNAME` — the name this host's exit node announces to
    Headscale. Required, and deliberately has no default: every host would otherwise
    register under the same name and need renaming by hand. A deploy without it fails
    immediately, saying so.
  - environment, first deploy on a new host only: `TS_AUTHKEY` — a Headscale pre-auth
    key. A fresh host has no login in `data/tailscale/` yet and can't register itself
    without one. Remove it after that first deploy; the login persists in the volume.

State and secrets never get committed.

- `server/`'s state stays on its host under `/home/ubuntu/docker-meta/vpn/`: Headscale's
  database and keys, Headplane's config (API key, cookie secret).
- `exit-node/`'s state stays relative to the stack's own `run_directory`, under
  `exit-node/data/`: the exit node's Tailscale login (`data/tailscale/`) and the WARP
  account, profile and pinned endpoint (`data/warp/`), mode 600. Relative on purpose —
  each host's exit-node stack is self-contained, with nothing to coordinate against
  another host's absolute paths.

## Depends on the host (exit-node only)

- nginx (host network) proxies the public names to the loopback ports server/ publishes.
- sslh owns 443; [sslh-tproxy](https://github.com/riskycase/sslh-tproxy) keeps its
  transparent mode working for clients in containers, including the exit node.

## `trusted_host_interfaces` is set at network creation

Docker only applies network driver options when it creates the network. After changing
them, destroy and redeploy the `exit-node` stack; a plain redeploy keeps the old network.

## Exit node traffic leaves through Cloudflare WARP

`exit-node/warp/` runs in the exit node's network namespace and sends what the exit node
forwards (traffic arriving on `tailscale0`) through a WireGuard tunnel to Cloudflare WARP.
Sites see a Cloudflare address, and the host sees only the tunnel; Cloudflare sees the
traffic instead. tailscaled's own traffic, to Headscale and to peers, keeps the normal
route, so direct connections to the phone keep working.

- Policy routing: priority 4999 keeps the main table's specific routes (the Docker network,
  the host) for forwarded traffic; priority 5000 sends the rest to table 51820, whose
  default route is `wg-warp`. Both are evaluated before Tailscale's own rules from 5210.
- DNS: with an exit node selected, clients send their lookups to the exit node, and
  tailscaled resolves them itself. Docker's embedded resolver would forward those from the
  host's namespace to the host's own resolvers, so the exit node uses
  `exit-node/resolv.conf` directly, and priority 5001 routes lookups to its nameservers
  through WARP as well.
- Fails closed: table 51820 keeps an `unreachable` default, so if the tunnel goes away
  forwarded traffic and DNS are dropped rather than leaving the host from its own address.
  Neither the tunnel nor the exit node needs DNS to come back: the WARP endpoint is
  resolved once and pinned in `wgcf-endpoint` (delete it if Cloudflare moves the
  endpoint), and `extra_hosts` gives the exit node Headscale's address directly, by IP.
- The rules and `wg-warp` live in the exit node's namespace and outlive the sidecar; a
  stopped sidecar only stops repairing them. To send exit traffic out directly again:

  ```
  docker compose run --rm warp flush
  ```

- Registration: on first start the sidecar registers a consumer WARP device with
  [wgcf](https://github.com/ViRb3/wgcf) (a community client for Cloudflare's undocumented
  API, accepting Cloudflare's terms of service) and keeps the account and profile in
  `exit-node/data/warp/`, mode 600. Later starts don't call that API. A revoked or
  otherwise dead account is not replaced automatically: delete `wgcf-account.toml` and
  `wgcf-profile.conf` (back them up first) and restart the sidecar to register fresh.
  `wg show wg-warp` is the only honest signal of whether it's actually working — rules
  being in place and a container reporting healthy both say nothing about Cloudflare
  actually answering the handshake.
- Hardened: read-only root filesystem, only `NET_ADMIN`, `no-new-privileges`, and `wgcf`
  pinned by checksum.

Tests, without root or netlink, from `exit-node/`:

```
./warp/tests/run.sh
```

### Verification, per host

1. `docker compose ps` — `warp` healthy (it needs a handshake with Cloudflare in the last
   3 minutes).
2. `docker compose exec warp sh -c 'ip rule; ip route show table 51820; wg show'`.
3. With the phone on the exit node and "Use Tailscale DNS" on,
   `https://cloudflare.com/cdn-cgi/trace` shows `warp=on`. An extended DNS leak test may
   show a different Cloudflare location for DNS than for the exit IP (both still
   Cloudflare, just different internal clusters) — that's not a leak, only a real
   non-Cloudflare resolver showing up would be.
4. `docker compose exec tailscale-exit ip link del wg-warp`: the phone loses connectivity
   and DNS through the exit node rather than falling back to the host's own address, and
   gets both back within the reconcile interval (30s) without intervention.

## Migrating an existing combined deployment to the split layout

A host that ran the old single-stack `compose.yaml` has its exit-node state under the
server's absolute paths, not `exit-node/data/`. Deploying the new `exit-node` stack there
without moving that state first starts clean: a fresh Tailscale login prompt and a fresh
WARP registration, throwing away a working device and account for no reason.

Note the old Tailscale mount was the `state` *subdirectory*
(`.../vpn/tailscale/state:/var/lib/tailscale`), so its contents go directly into
`data/tailscale/` — nesting a `state/` directory inside leaves tailscaled with an empty
state directory and it registers again. Back up first, then, with `DATA` the new stack's
`exit-node/data`:

```
sudo tar -czf ~/vpn-exit-node-state-$(date +%Y%m%d-%H%M%S).tar.gz \
    -C /home/ubuntu/docker-meta/vpn tailscale warp
sudo mkdir -p "$DATA/tailscale" "$DATA/warp"
sudo cp -a /home/ubuntu/docker-meta/vpn/tailscale/state/. "$DATA/tailscale/"
sudo cp -a /home/ubuntu/docker-meta/vpn/warp/. "$DATA/warp/"
sudo chown root:root "$DATA/tailscale" "$DATA/warp"
sudo chmod 700 "$DATA/tailscale"
sudo chmod 755 "$DATA/warp"
```

`cp -a` matters: the WARP account and profile are mode 600 and must stay that way. Copy
rather than move, so the old stack still has its state if the first split deploy needs
backing out.
