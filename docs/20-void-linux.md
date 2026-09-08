# Void Linux — notes and links

## One-line summary

Void is an **independent**, **rolling-release** distribution (stability-oriented), **not a fork** of another distro. It uses **runit**, **XBPS**, and **xbps-src**, supports **glibc and musl**, and builds packages continuously from the **void-packages** repository.

## Official entry points

- Site: https://voidlinux.org/
- Documentation hub: use links from the site (“Documentation”, “Handbook”).
- GitHub org: https://github.com/void-linux (xbps, void-packages, etc.)

## What to read for this project

1. **Handbook** — install, maintenance, services (runit), recovery.
2. **xbps** — repos, transactions, holds, staging if relevant.
3. **xbps-src** — if you need to **build** or **fork** packages for your image pipeline.

## Recent operational note (from voidlinux.org news, 2026-03)

`linux-firmware` may ship **zstd-compressed** firmware; older kernels may need a **hold** or a **newer kernel**. Track this if you pin firmware or support long-lived installs.

Do **not** paste the full Handbook into chats; **link it** and ask questions against a **local clone** of `void-packages` only when working on specific templates.
