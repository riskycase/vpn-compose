# vpn-compose

Headscale, Headplane and a Tailscale exit node for the OVH VPS, deployed as a Komodo stack.

## Komodo stack

- source: this repo + branch, webhook enabled for redeploy on push
- `run_directory`: the repo root, which holds `compose.yaml`
- `extra_args`: `--build`

State and secrets stay on the host under `/home/ubuntu/docker-meta/vpn/` and are never
committed: Headscale's database and keys, Headplane's config (API key, cookie secret) and
the exit node's Tailscale login.

## Depends on the host

- nginx (host network) proxies the public names to the loopback ports published here.
- sslh owns 443; [sslh-tproxy](https://github.com/riskycase/sslh-tproxy) keeps its
  transparent mode working for clients in containers, including the exit node.

## `trusted_host_interfaces` is set at network creation

Docker only applies network driver options when it creates the network. After changing
them, destroy and redeploy the stack; a plain redeploy keeps the old network.

## Exit node traffic leaves through Cloudflare WARP

`warp/` runs in the exit node's network namespace and sends what the exit node forwards
(traffic arriving on `tailscale0`) through a WireGuard tunnel to Cloudflare WARP. Sites see
a Cloudflare address, and OVH sees only the tunnel; Cloudflare sees the traffic instead.
tailscaled's own traffic, to Headscale and to peers, keeps the normal route, so direct
connections to the phone keep working.

- Policy routing: priority 4999 keeps the main table's specific routes (the Docker network,
  the host) for forwarded traffic; priority 5000 sends the rest to table 51820, whose
  default route is `wg-warp`. Both are evaluated before Tailscale's own rules from 5210.
- Fails closed: table 51820 keeps an `unreachable` default, so if the tunnel goes away
  forwarded traffic is dropped rather than leaving the VPS from its own address. The rules
  outlive the sidecar; to send exit traffic out directly again:

  ```
  docker compose run --rm warp flush
  ```

- Registration: on first start the sidecar registers a consumer WARP device with
  [wgcf](https://github.com/ViRb3/wgcf) (a community client for Cloudflare's undocumented
  API, accepting Cloudflare's terms of service) and keeps the account and profile in
  `/home/ubuntu/docker-meta/vpn/warp/`, mode 600. Later starts don't call that API. A
  revoked account is not replaced automatically; delete both files and restart.
- Hardened: read-only root filesystem, only `NET_ADMIN`, `no-new-privileges`, and `wgcf`
  pinned by checksum.

Tests, without root or netlink:

```
./warp/tests/run.sh
```

### Verification, per host

1. `docker compose ps` — `warp` healthy (it needs a handshake with Cloudflare in the last
   3 minutes).
2. `docker compose exec warp sh -c 'ip rule; ip route show table 51820; wg show'`.
3. With the phone on the exit node, `https://cloudflare.com/cdn-cgi/trace` shows
   `warp=on`, and a DNS leak test shows no OVH resolvers.
4. `docker compose stop warp`: the phone loses connectivity through the exit node rather
   than falling back to the VPS address. `docker compose start warp` restores it.
