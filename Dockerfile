# Pearl (PRL) miner for SaladCloud - our own minimal image (20.11.2026, rev 2)
# One miner only: krig-miner by Kryptex (official, CUDA, Kryptex pool, 0% devfee there).
# Base pinned by digest; miner archive pinned by version AND the sha256 GitHub publishes.
FROM nvidia/cuda:12.8.1-base-ubuntu24.04@sha256:133c78a0575303be34164d0b90137a042172bdf60696af01a3c424ab402d86e2

ARG KRIG_VERSION=1.8.2
ARG KRIG_SHA256=7a104c3dba3a41b9787fc43413f0cedaae78dab4284ab856633821161634c01d
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Binary stays owned by root (read/execute only for the miner user)
WORKDIR /opt/krig
RUN set -eux; \
    curl -fsSL -o /tmp/krig.tar.gz \
      "https://github.com/kryptex/krig-miner/releases/download/v${KRIG_VERSION}/krig-miner-${KRIG_VERSION}-linux-x64.tar.gz"; \
    echo "${KRIG_SHA256}  /tmp/krig.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/krig.tar.gz -C /opt/krig; rm /tmp/krig.tar.gz; \
    test -f /opt/krig/krig-miner; \
    chown -R root:root /opt/krig; chmod -R a+rX,go-w /opt/krig; chmod 0755 /opt/krig/krig-miner

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
RUN useradd --system --uid 10001 --create-home --home-dir /home/miner --shell /usr/sbin/nologin miner

USER miner
WORKDIR /home/miner
ENV HOME=/home/miner \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    NVIDIA_DISABLE_REQUIRE=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
