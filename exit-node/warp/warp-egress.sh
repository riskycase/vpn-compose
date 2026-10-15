#!/bin/sh
# Sends traffic the Tailscale exit node forwards (arriving on tailscale0), and the exit
# node's own DNS lookups, out through Cloudflare WARP, while tailscaled's control and peer
# traffic keeps the container's normal route. Runs in the exit node's network namespace. Every mode is safe to re-run:
# Docker restarts this container across reboots, and duplicate rules would stack.
set -eu

STATE="${WARP_STATE_DIR:-/state}"
RUN="${WARP_RUN_DIR:-/tmp}"
IFACE="${WARP_IFACE:-wg-warp}"
TS_IFACE="${WARP_TS_IFACE:-tailscale0}"
TABLE="${WARP_TABLE:-51820}"
# Tailscale's own rules start at 5210; ours must be evaluated first.
PRIO="${WARP_RULE_PRIORITY:-5000}"
INTERVAL="${WARP_RECONCILE_INTERVAL:-30}"
# With a 25s keepalive WireGuard re-handshakes about every two minutes.
MAX_HANDSHAKE_AGE="${WARP_MAX_HANDSHAKE_AGE:-180}"

# Exit-node clients' DNS is resolved by tailscaled with these nameservers. The file is the
# one mounted as the exit node's resolv.conf, so the two can't disagree.
RESOLV_CONF="${WARP_RESOLV_CONF:-/etc/resolv.conf}"

ACCOUNT="$STATE/wgcf-account.toml"
PROFILE="$STATE/wgcf-profile.conf"
ENDPOINT="$STATE/wgcf-endpoint"

NFT_RULESET="table inet warp_egress
delete table inet warp_egress
table inet warp_egress {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        oifname \"$IFACE\" tcp flags syn tcp option maxseg size set rt mtu
        iifname \"$IFACE\" tcp flags syn tcp option maxseg size set rt mtu
    }
}"

# Registration goes through Cloudflare's API, so it happens once and is kept: later starts,
# reboots included, need nothing from that API. Each file is written under a temporary
# name and renamed, so a container killed mid-registration leaves nothing that looks valid;
# the temporary names keep their extension because wgcf picks the file format from it.
# A revoked account is not replaced automatically; delete both files to register again.
profile() {
    umask 077
    if [ ! -s "$ACCOUNT" ]; then
        rm -f "$STATE/wgcf-account.tmp.toml"
        wgcf --config "$STATE/wgcf-account.tmp.toml" register --accept-tos >/dev/null
        mv "$STATE/wgcf-account.tmp.toml" "$ACCOUNT"
    fi
    if [ ! -s "$PROFILE" ]; then
        rm -f "$STATE/wgcf-profile.tmp.conf"
        wgcf --config "$ACCOUNT" generate --profile "$STATE/wgcf-profile.tmp.conf" >/dev/null
        mv "$STATE/wgcf-profile.tmp.conf" "$PROFILE"
    fi
    # DNS goes through the tunnel, so the tunnel can't need DNS to come up: the endpoint is
    # resolved once and kept. If Cloudflare moves it, delete this file to resolve it again.
    if [ ! -s "$ENDPOINT" ]; then
        endpoint=$(profile_value Endpoint)
        addr=$(getent ahostsv4 "${endpoint%:*}" | awk 'NR == 1 { print $1 }')
        [ -n "$addr" ] || { echo "cannot resolve ${endpoint%:*}" >&2; exit 1; }
        echo "$addr:${endpoint##*:}" > "$STATE/wgcf-endpoint.tmp"
        mv "$STATE/wgcf-endpoint.tmp" "$ENDPOINT"
    fi
}

profile_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROFILE"
}

addresses() {
    profile_value Address | tr ',' '\n' | tr -d ' ' | grep .
}

nameservers() {
    awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF"
}

require_profile() {
    [ -s "$PROFILE" ] || { echo "no WARP profile at $PROFILE; run 'profile' first" >&2; exit 1; }
    [ -s "$ENDPOINT" ] || { echo "no pinned endpoint at $ENDPOINT; run 'profile' first" >&2; exit 1; }
    for key in PrivateKey Address MTU PublicKey AllowedIPs Endpoint; do
        [ -n "$(profile_value "$key")" ] || { echo "$PROFILE has no $key" >&2; exit 1; }
    done
    [ -n "$(nameservers)" ] || { echo "$RESOLV_CONF lists no nameserver" >&2; exit 1; }
}

# wg setconf only understands WireGuard's own keys; Address and MTU are wg-quick extensions
# applied with ip here. The profile's DNS is dropped on purpose: exit-node clients get
# their resolvers from Headscale.
render_wg_conf() {
    umask 077
    cat > "$RUN/$IFACE.conf" <<CONF
[Interface]
PrivateKey = $(profile_value PrivateKey)

[Peer]
PublicKey = $(profile_value PublicKey)
AllowedIPs = $(profile_value AllowedIPs)
Endpoint = $(cat "$ENDPOINT")
PersistentKeepalive = 25
CONF
}

replace_rule() {
    while ip "$1" rule del priority "$2" 2>/dev/null; do :; done
    # shellcheck disable=SC2086
    ip "$1" rule add $3 priority "$2"
}

family() {
    case $1 in *:*) echo -6 ;; *) echo -4 ;; esac
}

apply() {
    require_profile
    ip link show dev "$IFACE" >/dev/null 2>&1 || ip link add dev "$IFACE" type wireguard
    render_wg_conf
    wg setconf "$IFACE" "$RUN/$IFACE.conf"
    for addr in $(addresses); do
        ip "$(family "$addr")" addr replace "$addr" dev "$IFACE"
    done
    ip link set dev "$IFACE" mtu "$(profile_value MTU)" up

    for fam in -4 -6; do
        ip "$fam" route replace default dev "$IFACE" table "$TABLE"
        # Fail closed: the kernel drops wg-warp's routes with the interface, and without
        # this the forwarded traffic would fall through to the main table and leave the
        # VPS unencrypted, from its own address.
        ip "$fam" route replace unreachable default metric 4096 table "$TABLE"
        # Specific routes in main (the Docker network, the host) stay direct; only the
        # default route is suppressed, which sends everything else on to WARP.
        replace_rule "$fam" $((PRIO - 1)) "iif $TS_IFACE lookup main suppress_prefixlength 0"
        replace_rule "$fam" "$PRIO" "iif $TS_IFACE lookup $TABLE"
        while ip "$fam" rule del priority $((PRIO + 1)) 2>/dev/null; do :; done
    done
    # tailscaled resolves exit-node clients' DNS itself, so those lookups are local
    # traffic, not forwarded; without these they'd leave the VPS from its own address.
    for ns in $(nameservers); do
        ip "$(family "$ns")" rule add to "$ns" lookup "$TABLE" priority $((PRIO + 1))
    done

    printf '%s\n' "$NFT_RULESET" | nft -f -
    echo "applied: iface=$IFACE table=$TABLE priority=$PRIO endpoint=$(cat "$ENDPOINT")"
}

check() {
    require_profile
    ip link show dev "$IFACE" 2>/dev/null | grep -q '<[^>]*,UP[,>]' || return 1
    [ "$(wg show "$IFACE" peers 2>/dev/null)" = "$(profile_value PublicKey)" ] || return 1
    for addr in $(addresses); do
        ip "$(family "$addr")" addr show dev "$IFACE" | grep -qF " $addr " || return 1
    done
    for ns in $(nameservers); do
        ip "$(family "$ns")" rule show priority $((PRIO + 1)) | grep -q "to $ns lookup $TABLE" || return 1
    done
    for fam in -4 -6; do
        routes=$(ip "$fam" route show table "$TABLE")
        printf '%s\n' "$routes" | grep -q "^default dev $IFACE" || return 1
        printf '%s\n' "$routes" | grep -q '^unreachable default' || return 1
        ip "$fam" rule show priority $((PRIO - 1)) | grep -q "iif $TS_IFACE.* lookup main suppress_prefixlength 0" \
            || return 1
        ip "$fam" rule show priority "$PRIO" | grep -q "iif $TS_IFACE.* lookup $TABLE" || return 1
    done
    nft list table inet warp_egress >/dev/null 2>&1 || return 1
}

# Rules being in place says nothing about Cloudflare answering; a recent handshake does.
health() {
    check || return 1
    last=$(wg show "$IFACE" latest-handshakes | awk '{ print $2 }')
    [ "${last:-0}" -gt 0 ] && [ $(($(date +%s) - last)) -le "$MAX_HANDSHAKE_AGE" ]
}

# Removes the kill switch along with everything else, so forwarded traffic leaves the VPS
# directly afterwards. Only for deliberate teardown; nothing calls it on container stop.
flush() {
    for fam in -4 -6; do
        while ip "$fam" rule del priority "$PRIO" 2>/dev/null; do :; done
        while ip "$fam" rule del priority $((PRIO - 1)) 2>/dev/null; do :; done
        while ip "$fam" rule del priority $((PRIO + 1)) 2>/dev/null; do :; done
        ip "$fam" route flush table "$TABLE" 2>/dev/null || true
    done
    nft delete table inet warp_egress 2>/dev/null || true
    ip link del dev "$IFACE" 2>/dev/null || true
    echo "flushed"
}

cd "$RUN"
case "${1:-run}" in
    profile) profile ;;
    apply) apply ;;
    check) check ;;
    health) health ;;
    flush) flush ;;
    run)
        profile
        apply
        # Re-apply on drift, e.g. after tailscaled reconfigures the namespace it shares.
        while sleep "$INTERVAL"; do
            check || apply
        done
        ;;
    *) echo "usage: $0 {profile|apply|check|health|flush|run}" >&2; exit 2 ;;
esac
