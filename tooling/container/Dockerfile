FROM docker.io/voidlinux/voidlinux:latest

# Force a stable repo host (avoid mirror/cert mismatches during builds).
RUN mkdir -p /etc/xbps.d && \
    printf '%s\n' \
      "repository=https://repo-default.voidlinux.org/current" \
      "repository=https://repo-default.voidlinux.org/current/nonfree" \
      > /etc/xbps.d/00-voidling-repos.conf

# The base image ships a default repo config pointing at alpha.de.repo.voidlinux.org.
# Remove it so xbps does not attempt to contact that mirror during builds.
RUN rm -f /usr/share/xbps.d/00-repository-main.conf

# Update xbps first (base image xbps can be too old for current repodata),
# then install certificates and build tools.
RUN XBPS_NONINTERACTIVE=1 xbps-install -Suy xbps ca-certificates && \
    XBPS_NONINTERACTIVE=1 xbps-install -Sy bash coreutils findutils gawk grep sed util-linux ostree xbps && \
    xbps-reconfigure -fa && \
    xbps-remove -Ooy && \
    rm -rf /var/cache/xbps

WORKDIR /work