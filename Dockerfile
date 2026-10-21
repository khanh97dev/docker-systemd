FROM debian:13-slim

ARG TARGETARCH
ARG CLOUDFLARED_VERSION=2026.10.2
ARG OPENCODE_VERSION=2.1.1
ARG DEBIAN_FRONTEND=noninteractive

# systemd cần biết nó đang trong container
ENV container=docker \
    TZ=Australia/Sydney

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session \
      openssh-server \
      cron \
      ca-certificates \
      curl \
      tzdata \
      procps \
 && rm -rf /var/lib/apt/lists/*

# ---- cloudflared: .deb chính thức, pin version + verify sha256 ----
RUN set -eux; \
    case "${TARGETARCH:-arm64}" in \
      arm64) SHA=2e5335ea0ef2fa98e5354357e77aaf453f3756d1f9023cf5b063409e1fb3baca ;; \
      amd64) SHA=30a9a127c24ea8365fa8e11b13684128f34dd8a1137599aa00b4bebda1a0a083 ;; \
      *) echo "arch không hỗ trợ: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/cloudflared.deb \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${TARGETARCH:-arm64}.deb"; \
    echo "${SHA}  /tmp/cloudflared.deb" | sha256sum -c -; \
    dpkg -i /tmp/cloudflared.deb; \
    rm -f /tmp/cloudflared.deb; \
    cloudflared --version

# ---- opencode v2 (CLI) ----
# v2 phát hành qua npm registry, KHÔNG qua GitHub releases (github chỉ có 1.x).
# Version lấy từ https://opencode.ai/update/api/latest/cli/npm
RUN set -eux; \
    case "${TARGETARCH:-arm64}" in \
      arm64) OC_T=linux-arm64; SHA=cfa3ae6363fc3082f03072297069d81f53559a761371fdb4b56fe6bfa01ca066 ;; \
      amd64) OC_T=linux-x64;   SHA=64591057ea593e9a11374d4630c2249930d8f33598af0b3e02137493860ab17b ;; \
      *) echo "arch không hỗ trợ: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/opencode.tgz \
      "https://registry.npmjs.org/@opencode/cli-${OC_T}/-/cli-${OC_T}-${OPENCODE_VERSION}.tgz"; \
    echo "${SHA}  /tmp/opencode.tgz" | sha256sum -c -; \
    tar -xzf /tmp/opencode.tgz -C /tmp package/bin/opencode; \
    mv /tmp/package/bin/opencode /usr/local/bin/opencode; \
    chmod 755 /usr/local/bin/opencode; \
    rm -rf /tmp/opencode.tgz /tmp/package; \
    opencode --version

# ---- Mask unit không chạy được / không cần trong container ----
# Không mask -> systemd báo "degraded" vì các unit này fail.
RUN systemctl mask \
      systemd-udevd.service \
      systemd-udevd-kernel.socket \
      systemd-udevd-control.socket \
      systemd-modules-load.service \
      systemd-journald-audit.socket \
      sys-kernel-debug.mount \
      sys-kernel-tracing.mount \
      sys-kernel-config.mount \
      systemd-oomd.service \
 && rm -f /lib/systemd/system/multi-user.target.wants/getty.target

COPY units/ /etc/systemd/system/
COPY bin/ /usr/local/sbin/
RUN chmod +x /usr/local/sbin/*.sh

# sshd host keys (bỏ dòng này nếu không cần ssh)
RUN ssh-keygen -A

# Bật service. cloudflared KHÔNG enable sẵn - cần token trước (xem README).
RUN systemctl enable ssh.service cron.service app.service

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD /usr/local/sbin/healthcheck.sh

# systemd shutdown bằng SIGRTMIN+3, không phải SIGTERM
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
