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
