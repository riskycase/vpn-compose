#!/bin/sh
# Exercises warp-egress.sh against fake ip, wg, nft and wgcf: proves registration happens
# once and survives a crash mid-write, that apply is idempotent and fails closed, and that
# check mode detects drift. Runs anywhere, needs no root and no netlink.
set -eu

cd "$(dirname "$0")"
SCRIPT="../warp-egress.sh"

PATH="$PWD/fake-bin:$PATH"
export PATH
FAKE_STATE=$(mktemp)
WARP_STATE_DIR=$(mktemp -d)
WARP_RUN_DIR=$(mktemp -d)
WARP_RESOLV_CONF=$(mktemp)
export FAKE_STATE WARP_STATE_DIR WARP_RUN_DIR WARP_RESOLV_CONF
printf '# comment\nnameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\noptions edns0\n' > "$WARP_RESOLV_CONF"

trap 'rm -rf "$FAKE_STATE" "$FAKE_STATE".* "$WARP_STATE_DIR" "$WARP_RUN_DIR" "$WARP_RESOLV_CONF"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
snapshot() { sort "$FAKE_STATE"; }
calls() { grep -c "^WGCF $1\$" "$FAKE_STATE.calls" 2>/dev/null || echo 0; }
lookups() { grep -c '^GETENT' "$FAKE_STATE.calls" 2>/dev/null || echo 0; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
: > "$FAKE_STATE"

FAKE_WGCF_FAIL=1 sh "$SCRIPT" profile 2>/dev/null && fail "profile succeeded with registration failing"
[ ! -e "$WARP_STATE_DIR/wgcf-account.toml" ] || fail "a failed registration left an account file behind"
echo "ok   a registration that dies mid-write leaves no account behind"

FAKE_GETENT_FAIL=1 sh "$SCRIPT" profile 2>/dev/null && fail "profile succeeded without resolving the endpoint"
[ ! -e "$WARP_STATE_DIR/wgcf-endpoint" ] || fail "an unresolved endpoint left a file behind"
echo "ok   profile fails loudly when the endpoint can't be resolved"

sh "$SCRIPT" profile
[ -s "$WARP_STATE_DIR/wgcf-account.toml" ] && [ -s "$WARP_STATE_DIR/wgcf-profile.conf" ] \
    || fail "profile did not write the account and the profile"
[ "$(cat "$WARP_STATE_DIR/wgcf-endpoint")" = "162.159.192.1:2408" ] || fail "endpoint not pinned to an address"
[ "$(mode "$WARP_STATE_DIR/wgcf-account.toml")" = "600" ] && [ "$(mode "$WARP_STATE_DIR/wgcf-profile.conf")" = "600" ] \
    || fail "account or profile readable beyond its owner"
ls "$WARP_STATE_DIR" | grep -q '\.tmp\.' && fail "temporary files left in the state dir"
echo "ok   profile registers, generates, and keeps both private to their owner"

sh "$SCRIPT" profile
sh "$SCRIPT" profile
[ "$(calls register)" = "2" ] || fail "registered again with an account already saved ($(calls register) calls)"
[ "$(calls generate)" = "1" ] || fail "generated again with a profile already saved"
[ "$(lookups)" = "2" ] || fail "resolved the endpoint again with it already pinned ($(lookups) lookups)"
echo "ok   later starts make no calls to Cloudflare's API"

sh "$SCRIPT" apply >/dev/null
first=$(snapshot)
grep -qx "LINK wg-warp up" "$FAKE_STATE" || fail "wg-warp not brought up"
grep -q "^ADDR 4 172.16.0.2/32 dev wg-warp$" "$FAKE_STATE" || fail "IPv4 address missing"
grep -q "^ADDR 6 2606:4700:110:8a36::2/128 dev wg-warp$" "$FAKE_STATE" || fail "IPv6 address missing"
echo "ok   apply brings wg-warp up with both addresses"

grep -q '^DNS' "$FAKE_STATE.wgconf" && fail "wg-quick-only keys passed to wg setconf"
grep -q '^Address\|^MTU' "$FAKE_STATE.wgconf" && fail "wg-quick-only keys passed to wg setconf"
grep -qx 'PersistentKeepalive = 25' "$FAKE_STATE.wgconf" || fail "keepalive missing from the peer"
grep -qx 'Endpoint = 162.159.192.1:2408' "$FAKE_STATE.wgconf" || fail "tunnel would need DNS to find its endpoint"
[ "$(mode "$WARP_RUN_DIR/wg-warp.conf")" = "600" ] || fail "rendered WireGuard config readable beyond its owner"
echo "ok   apply hands wg setconf only WireGuard's own keys, kept private"

for fam in 4 6; do
    grep -q "^RULE $fam 4999 iif tailscale0 lookup main suppress_prefixlength 0$" "$FAKE_STATE" \
        || fail "IPv$fam: forwarded traffic doesn't keep the main table's specific routes"
    grep -q "^RULE $fam 5000 iif tailscale0 lookup 51820$" "$FAKE_STATE" || fail "IPv$fam: forwarded traffic not steered into WARP"
    [ "$(ip -$fam rule show priority 4999 | wc -l)" -eq 1 ] && [ "$(ip -$fam rule show priority 5000 | wc -l)" -eq 1 ] \
        || fail "IPv$fam: duplicate rules"
done
echo "ok   apply steers only traffic arriving on tailscale0, for IPv4 and IPv6"

grep -q "^RULE 4 5001 to 1.1.1.1 lookup 51820$" "$FAKE_STATE" || fail "IPv4 resolver lookups not sent through WARP"
grep -q "^RULE 6 5001 to 2606:4700:4700::1111 lookup 51820$" "$FAKE_STATE" || fail "IPv6 resolver lookups not sent through WARP"
[ "$(grep -c "^RULE [46] 5001 " "$FAKE_STATE")" -eq 2 ] || fail "resolver rules for something other than resolv.conf's nameservers"
echo "ok   apply sends the exit node's own DNS lookups through WARP"

for fam in 4 6; do
    ip -$fam route show table 51820 | grep -qx "default dev wg-warp" || fail "IPv$fam: no default through wg-warp"
    ip -$fam route show table 51820 | grep -qx "unreachable default metric 4096" || fail "IPv$fam: no kill switch"
done
echo "ok   apply routes table 51820 through wg-warp with an unreachable fallback"

sh "$SCRIPT" check || fail "check failed immediately after apply"
echo "ok   check passes after apply"

sh "$SCRIPT" apply >/dev/null
sh "$SCRIPT" apply >/dev/null
[ "$first" = "$(snapshot)" ] || fail "state drifted across repeated applies"
echo "ok   apply is idempotent across 3 runs"

ip link del dev wg-warp
for fam in 4 6; do
    ip -$fam route show table 51820 | grep -qx "unreachable default metric 4096" \
        || fail "IPv$fam: losing wg-warp removed the kill switch, forwarded traffic would leave unencrypted"
    ip -$fam rule show priority 5000 | grep -q . || fail "IPv$fam: losing wg-warp removed the steering rule"
done
if sh "$SCRIPT" check; then fail "check passed with wg-warp gone"; fi
echo "ok   losing wg-warp fails closed, and check detects it"

sh "$SCRIPT" apply >/dev/null
ip -6 rule del priority 5000
if sh "$SCRIPT" check; then fail "check passed with the IPv6 steering rule missing"; fi
echo "ok   check detects a removed steering rule"

sh "$SCRIPT" apply >/dev/null
ip -4 rule del priority 5001
if sh "$SCRIPT" check; then fail "check passed with the resolver rule missing"; fi
echo "ok   check detects a removed resolver rule"

sh "$SCRIPT" apply >/dev/null
nft delete table inet warp_egress
if sh "$SCRIPT" check; then fail "check passed with the MSS clamp missing"; fi
echo "ok   check detects a removed MSS clamp"

sh "$SCRIPT" apply >/dev/null
[ "$first" = "$(snapshot)" ] || fail "repaired state differs from the original"
[ "$(lookups)" = "2" ] || fail "apply resolved a name; it must work with DNS down"
echo "ok   apply repairs drift back to the original state"

FAKE_HANDSHAKE=$(( $(date +%s) - 30 )) sh "$SCRIPT" health || fail "health failed with a 30s-old handshake"
if FAKE_HANDSHAKE=$(( $(date +%s) - 600 )) sh "$SCRIPT" health; then fail "health passed with a 10-minute-old handshake"; fi
if FAKE_HANDSHAKE=0 sh "$SCRIPT" health; then fail "health passed with no handshake ever"; fi
echo "ok   health requires a recent handshake with Cloudflare"

sh "$SCRIPT" flush >/dev/null
[ -z "$(grep -v '^WGPEER' "$FAKE_STATE" || :)" ] || fail "flush left state behind: $(snapshot)"
echo "ok   flush removes every link, rule, route and table"

: > "$FAKE_STATE"
rm -f "$WARP_STATE_DIR/wgcf-endpoint"
if sh "$SCRIPT" apply 2>/dev/null; then fail "apply succeeded without a pinned endpoint"; fi
[ ! -s "$FAKE_STATE" ] || fail "apply changed state without a pinned endpoint: $(snapshot)"
echo "ok   apply refuses to run without a pinned endpoint and changes nothing"

rm -f "$WARP_STATE_DIR/wgcf-profile.conf"
if sh "$SCRIPT" apply 2>/dev/null; then fail "apply succeeded without a profile"; fi
[ ! -s "$FAKE_STATE" ] || fail "apply changed state without a profile: $(snapshot)"
echo "ok   apply refuses to run without a profile and changes nothing"

echo
echo "PASS 20/20"
