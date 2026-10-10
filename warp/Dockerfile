FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

# wgcf is a community client for Cloudflare's WARP registration API. The binary is pinned
# by version and checksum so a tampered or re-tagged release fails the build.
ARG WGCF_VERSION=2.3.0
ARG WGCF_SHA256_amd64=01614e38c0eb5f3405232e71cfaf02d64d4809e4988ad8f5a8071af16d193405
ARG WGCF_SHA256_arm64=dcadadc42bcc410a4032a6d1c0490ea510e199f0aaaee397dc1aa0fbd27038e8
ARG TARGETARCH

RUN apk add --no-cache iproute2 nftables wireguard-tools-wg \
 && case "$TARGETARCH" in \
        amd64) sum="$WGCF_SHA256_amd64" ;; \
        arm64) sum="$WGCF_SHA256_arm64" ;; \
        *) echo "no pinned wgcf checksum for $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && wget -qO /usr/local/bin/wgcf \
        "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${TARGETARCH}" \
 && echo "$sum  /usr/local/bin/wgcf" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/wgcf

COPY warp-egress.sh /usr/local/bin/warp-egress
ENTRYPOINT ["warp-egress"]
CMD ["run"]
