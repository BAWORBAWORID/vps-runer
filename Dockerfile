FROM ubuntu:24.04

LABEL maintainer="VpsFree"
LABEL description="Containerized Ubuntu Server VPS with Bore & SSH"

ENV DEBIAN_FRONTEND=noninteractive

# Pasang paket dasar, OpenSSH server, dan bore tunnel
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    sudo \
    openssh-server \
    jq \
    procps \
    net-tools \
    bash \
    python3 \
    tzdata \
    tar \
    && curl -fsSL https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/bore \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd /etc/ssh/sshd_config.d

# Konfigurasi SSH Server (Port 22, root login, Pubkey + Password authentication)
RUN printf "Port 22\nPermitRootLogin yes\nPasswordAuthentication yes\nPubkeyAuthentication yes\n" > /etc/ssh/sshd_config.d/99-vpsfree.conf

# Salin entrypoint script
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22 8000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
