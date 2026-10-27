# Self-Hosted Homelab & Cloud Infrastructure

A production-grade, self-hosted infrastructure platform running 18+ containerized
services across a Proxmox virtualization cluster, with ZFS network storage,
GPU-accelerated media transcoding, and a zero-trust remote access architecture
exposing services to the public internet with **zero open inbound ports** on the
home network.

This repository documents the architecture, design decisions, and operational
practices behind the platform. It is maintained as a personal engineering record
and reference.

> **Note on secrets:** This is a sanitized, public-facing writeup. Real IP
> addresses, domain names, credentials, and exact port mappings have been
> redacted or generalized. Nothing here maps to a live attack surface.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Hardware](#hardware)
- [Virtualization Layer](#virtualization-layer)
- [Storage Layer](#storage-layer)
- [Service Inventory](#service-inventory)
- [Networking & Remote Access](#networking--remote-access)
- [Observability & Maintenance](#observability--maintenance)
- [Alerting](#alerting)
- [Secrets Management](#secrets-management)
- [Incident Writeups](#incident-writeups)
- [Design Principles](#design-principles)
- [Tech Stack](#tech-stack)
- [Changelog](#changelog)

---

## Overview

The platform has run continuously for **3+ years** with **99.9%+ uptime**,
serving **20+ users** across media streaming and family photo services. It began
as a single media server and grew into a multi-node virtualized environment with
dedicated storage, reverse-proxy ingress, mesh networking, and monitoring.

Goals that shaped the build:

- **Reliability** — services that family and friends depend on should not go down.
- **Security** — expose what needs to be public without exposing the home network.
- **Maintainability** — declarative, reproducible configuration over manual setup.
- **Learning** — every layer is an opportunity to understand production systems.

---

## Architecture

```
                          ┌─────────────────────┐
                          │   Public Internet    │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │     Cloudflare        │  DNS, WAF, DDoS
                          │   (proxied ingress)   │  protection, caching
                          └──────────┬───────────┘
                                     │  HTTPS (443)
                          ┌──────────▼───────────┐
                          │   Cloud VPS (Hetzner) │  Hardened reverse proxy
                          │  Nginx Proxy Manager  │  Let's Encrypt TLS
                          └──────────┬───────────┘
                                     │  Tailscale mesh (WireGuard)
                                     │  — encrypted, no open home ports
              ┌──────────────────────▼──────────────────────┐
              │              Home Network                     │
              │                                               │
              │   ┌───────────────────────────────────────┐  │
              │   │         Proxmox VE Host                 │ │
              │   │                                         │ │
              │   │  ┌──────────┐  ┌──────────┐  ┌───────┐ │ │
              │   │  │ TrueNAS  │  │  Media   │  │ Other │ │ │
              │   │  │   VM     │  │ Stack VM │  │  VMs  │ │ │
              │   │  │ (ZFS)    │  │ (Docker) │  │       │ │ │
              │   │  └────┬─────┘  └────┬─────┘  └───────┘ │ │
              │   │       │ SMB/CIFS    │                  │ │
              │   │       └─────────────┘                  │ │
              │   └─────────────────────────────────────────┘ │
              └───────────────────────────────────────────────┘
```

**Traffic flow:** External requests resolve through Cloudflare (which provides
DNS, a web application firewall, DDoS mitigation, and caching), terminate TLS at
a hardened cloud VPS running Nginx Proxy Manager, and are forwarded over an
encrypted Tailscale mesh tunnel to the appropriate service on the home network.
Because the tunnel is outbound from the home side, **no inbound ports are opened
on the home router** — the home network has no public attack surface.

---

## Hardware

| Component        | Role                                                |
| ---------------- | --------------------------------------------------- |
| Proxmox host     | Primary hypervisor running all VMs                  |
| GPU              | NVIDIA GPU passed through for hardware transcoding   |
| Ubiquiti gateway | Routing, firewall, VLAN segmentation                |
| Managed switch   | Aggregation, STP edge configuration                 |
| Cloud VPS        | Off-site reverse-proxy ingress node (Hetzner)        |

The GPU is dedicated to the media VM for `h264_nvenc` / `hevc_nvenc` hardware
encoding, allowing multiple simultaneous transcodes without saturating CPU.

---

## Virtualization Layer

**Proxmox VE** is the foundation. Workloads are isolated into purpose-specific
virtual machines rather than co-located, so that a fault or reboot in one domain
(e.g. the media stack) does not affect another (e.g. storage):

- **TrueNAS VM** — owns the ZFS pool and serves storage over SMB/CIFS.
- **Media stack VM** — runs the Docker media stack with GPU passthrough.
- **Additional VMs** — automation, utility, and experimental workloads.

Isolating storage from compute also means the media stack can be torn down and
rebuilt without any risk to the underlying data.

---

## Storage Layer

**TrueNAS** running as a Proxmox VM manages a **ZFS** pool that provides:

- Data integrity via ZFS checksumming and scheduled scrubs
- SMB/CIFS shares consumed by the media stack and other clients
- Snapshot capability for point-in-time recovery

ZFS checksumming has proved its value more than once (see
[Incident Writeups](#incident-writeups)). In the first case a scrub repaired
**0 bytes with 0 data errors**, confirming a hypervisor I/O hiccup had not
touched the data. In a later case a mirror member accumulated real checksum
errors and a scrub **repaired ~364 KB from the healthy copy with no data loss** —
the pool stayed `ONLINE` throughout. Mirrored vdevs plus scheduled scrubs are
what turn a failing disk into a maintenance ticket instead of an outage.

---

## Service Inventory

The platform runs **18+ containerized services**, defined declaratively via
Docker Compose. Highlights:

### Media

| Service     | Purpose                                            |
| ----------- | -------------------------------------------------- |
| Jellyfin    | Media server with GPU hardware transcoding         |
| Immich      | Self-hosted family photo & video backup            |
| Seerr       | Request management; also brokers client auth to Jellyfin |
| Immich AI analysis | On-demand AI photo descriptions via a local LLM (Compose profile, off by default) |

### Networking & Access

| Service              | Purpose                                       |
| -------------------- | --------------------------------------------- |
| Nginx Proxy Manager  | Reverse proxy + Let's Encrypt TLS termination |
| Tailscale            | Mesh VPN (WireGuard) between nodes            |

### Acquisition & Automation

| Service               | Purpose                                            |
| --------------------- | -------------------------------------------------- |
| Sonarr / Radarr       | Series & film library automation                   |
| Prowlarr / Profilarr  | Indexer management & quality-profile sync          |
| Bazarr                | Subtitle acquisition                               |
| Unpackerr             | Post-download extraction                           |
| qBittorrent + Gluetun | Download client routed entirely through a VPN container |

The download client has **no direct network path of its own** — it shares
Gluetun's network namespace, so if the VPN container is down the client has no
connectivity at all rather than leaking traffic over the home WAN.

### Operations

| Service     | Purpose                                            |
| ----------- | -------------------------------------------------- |
| Portainer   | Container management UI                            |
| Homepage    | Unified service dashboard                          |
| Watchtower  | Automated container image updates, with push notifications |
| Uptime Kuma | External uptime checks (runs on the cloud VPS)     |
| ntfy        | Self-hosted push-notification server (cloud VPS)   |

The media services share a dedicated Docker bridge network and read media from
the TrueNAS SMB mounts, keeping storage centralized and the compute layer
stateless.

Heavy, occasional workloads — the local LLM and the photo-analysis job that uses
it — sit behind a **Docker Compose profile**, so a plain `docker compose up -d`
skips them and they only run when explicitly started with `--profile analyze`.

---

## Networking & Remote Access

The remote-access design is the most security-critical part of the build. The
objective: make selected services reachable from anywhere on the public internet
**without opening a single inbound port at home**.

### How it works

1. **Cloudflare** sits in front as the public entry point — DNS, proxied
   (orange-cloud) records, WAF, DDoS protection, and caching. The home network's
   real public IP is never exposed for proxied services.
2. **Cloud VPS (Hetzner)** runs **Nginx Proxy Manager**, which terminates TLS
   (Let's Encrypt) and reverse-proxies each hostname to the correct backend.
3. **Tailscale** (WireGuard-based mesh) connects the VPS to home-network nodes.
   NPM forwards to each service over its Tailscale IP, so traffic between the VPS
   and home rides an encrypted tunnel that is **initiated outbound from home**.
4. Result: the home router has **zero open inbound ports**. There is nothing for
   an external scanner to find.

### Real client IP preservation

A non-trivial challenge in a multi-hop proxy chain
(`Cloudflare → NPM → Tailscale → service`) is preserving the **real visitor IP**
through every layer instead of logging proxy/relay addresses. This was solved by:

- Configuring NPM to honor Cloudflare's `CF-Connecting-IP` header (overriding
  NPM's global `real_ip_header` default via a host-level custom config).
- Whitelisting Cloudflare's published IP ranges with `set_real_ip_from`.
- Installing Tailscale **directly on each backend** to remove an intermediate
  relay hop that was masking the source IP.
- Setting each service's trusted/known-proxy ranges to cover the Docker bridge,
  LAN, and Tailscale CGNAT (`100.64.0.0/10`) networks.

The result is accurate end-to-end client IP logging, including IPv6.

### Protocol-aware proxying

Web services (HTTP/HTTPS) route through the proxied Cloudflare path for WAF and
DDoS benefits. Non-HTTP services that Cloudflare's proxy can't tunnel — e.g. a
**WireGuard** UDP endpoint — use DNS-only records and a separate, deliberately
chosen path, since proxying raw UDP through an HTTP proxy would silently fail.
Knowing *which layer handles which protocol* is a recurring theme of the design.

### Locking down the VPS edge

The home side had zero inbound ports, but the VPS itself did not. An external
recon pass found that a DNS-only record (required for the game server, which
Cloudflare's proxy can't carry) revealed the VPS's public IP. On that IP:

- **The reverse proxy's admin UI was publicly reachable.**
- **Cloudflare could be bypassed entirely** — sending a request straight to the
  VPS IP with the right `Host` header was served normally, skipping the WAF and
  its rate limits.
- **SSH was open to the internet.**

Docker-published ports bypass the host firewall, so the fix had to live at the
**cloud provider's firewall**, in front of the VM:

- Web ports accept connections **only from Cloudflare's published IP ranges**,
  so every request has to pass through the WAF.
- SSH and the proxy admin UI have **no public rule at all** — they're reachable
  only over the mesh VPN, with the provider's web console as the break-glass path.
- Only the game server port, the mesh VPN's UDP port, and ICMP stay open to all.

Verified from outside afterwards: admin and SSH ports filtered, direct-to-IP
requests time out, and every service still answers normally through Cloudflare.
The lesson: **every DNS-only record discloses an origin**, so whatever sits
behind it has to be safe to expose on its own.

---

## Observability & Maintenance

- **Uptime Kuma** checks every service from outside the home network and pushes
  down/recovery alerts — see [Alerting](#alerting).
- **Watchtower** automates image updates, with specific containers intentionally
  pinned to named tags so updates are controlled rather than surprise-breaking.
- **Scheduled ZFS scrubs** verify data integrity on the storage pool.
- **Automated cleanup** — a cron job prunes dangling Docker images weekly to keep
  the compute VM's disk usage in check.
- **Self-healing crons** — two guardrails added after real outages: a mount
  watchdog on the media VM that remounts dropped CIFS shares, and an SMB service
  watchdog on the storage VM
  (`systemctl is-active --quiet smbd || midclt call service.start cifs`). Both run
  on a 5-minute interval; the interval *is* the worst-case outage window, which is
  why neither was left hourly.
- **Memory guardrails** — per-container memory limits on the memory-hungry
  services (notably the photo stack), a capped ZFS ARC on the storage VM, and
  `restart: "no"` on manually-invoked batch jobs so an OOM kill doesn't become a
  restart loop.
- **Boot ordering** — Proxmox VM start order and delays are set explicitly so
  storage is serving shares before any consumer VM boots.
- **SMART monitoring** on the Proxmox host for the pool member with a climbing
  reallocated-sector count. SMART lives on the host rather than in TrueNAS on
  purpose: the disks are passed to the storage VM by ID, so TrueNAS only sees
  virtual disks and can't read real SMART data (it still sees ZFS-level errors).

---

## Alerting

Every layer now pushes an alert to a phone when something breaks: a service
goes down, a container updates, the pool degrades, the hypervisor reports an
event — or the alerting server itself goes offline.

| Event                                           | Source                    | Channel         |
| ----------------------------------------------- | ------------------------- | --------------- |
| Service down / recovered, host ping failures    | Uptime Kuma (cloud VPS)   | Push (`homelab-down`)    |
| Container updated or update available           | Watchtower (media VM)     | Push (`homelab-updates`) |
| Pool degraded, checksum errors, scrub problems  | TrueNAS                   | Push (`homelab-storage`) |
| Backups, SMART warnings, host events            | Proxmox                   | Push (`homelab-storage`) |
| Cloud VPS offline (takes the alerting stack with it) | Healthchecks.io      | Email           |

### Design

- **Alerts live off-site.** The push server (**ntfy**) and the uptime monitor
  (**Uptime Kuma**) run on the cloud VPS, not at home — an alerting system
  hosted on the thing it monitors goes silent exactly when it's needed.
- **Monitored from the outside in.** Uptime Kuma checks each home service over
  the mesh VPN, the same path real traffic takes. Key services get **two checks
  — direct and public**: if the public one fails and the direct one passes, the
  service is fine and the proxy chain is what broke.
- **One check can cover two containers.** The download client shares the VPN
  container's network namespace, so if the VPN dies the client's Web UI becomes
  unreachable — its uptime check doubles as the VPN check.
- **Deny-by-default push server.** ntfy runs with `auth-default-access: deny-all`;
  nothing can read or publish without a login. Services publish with a scoped
  access token, and the server's port is bound to Docker's bridge gateway
  address only, so the reverse proxy can reach it but the internet can't.
- **A dead man's switch for the watchers.** If the VPS goes down, the push
  server and uptime monitor go down with it and nothing alerts. So the VPS pings
  an external **Healthchecks.io** check every 5 minutes from cron; if the pings
  stop, it emails. It's outbound-only — no open ports — and deliberately uses
  email rather than push, since push would be down too.
- **Adapting tools that don't speak ntfy.** Proxmox uses a generic webhook
  target with the token stored as a webhook secret. TrueNAS has no ntfy
  integration, so it uses a **Slack-type alert service** pointed at ntfy, which
  converts the Slack-style JSON with a message template and takes its
  credentials from a URL parameter.
- **Every path was tested end to end** — e.g. pointing one monitor at an unused
  port to confirm a down alert *and* a recovery alert arrived.

### Lessons from the build

- **A monitor without a notification target is just a dashboard.** Uptime Kuma
  detected the first test failure and sent nothing, because no notification had
  been attached yet. Notifications are now default-enabled on every monitor.
- **A defined secret isn't a used secret.** The Proxmox webhook returned `403`
  because the token was stored as a secret but never referenced in a header.
- **`401` vs `403` tells you which half is wrong:** with ntfy, a `401` means a
  bad token; a `403` means no credentials were sent at all.
- **Token rotation has a blast radius.** The push token lives in four places
  (the media VM's env file, the uptime monitor, the Proxmox webhook, and the
  TrueNAS URL), so rotation is a documented checklist that ends with revoking
  the old token.

---

## Secrets Management

All credentials (VPN account, API keys, the push token) were moved out of the
media stack's `docker-compose.yml` into a separate `.env` file beside it, owned
by the service user with mode `600`. The compose file now holds only `${...}`
references, which Compose fills in automatically.

- **The cleanup found a leak.** Two editor emergency-save files
  (`docker-compose.yml.save`, `.save.1`) were sitting next to the compose file —
  one contained the VPN password in plain text. Both were deleted.
- **`sudo cat > file` doesn't work** for writing a root-owned file: the
  redirect runs as the calling user, not root. `sudo tee file > /dev/null` does.
- **Validated before applying** with `docker compose config`, then confirmed the
  VPN container still came up with a forwarded port and pushed it to the client.
- Changing a credential is now: edit `.env`, run `docker compose up -d`. Compose
  only recreates containers whose resolved values changed — which is also why
  the VPN container showed `Running` rather than recreated after the migration:
  its values were identical, so Compose correctly saw no change.

---

## Incident Writeups

Real incidents resolved on this platform. These are kept because diagnosing
production failures end-to-end is the most valuable part of running real
infrastructure.

### 1. Unkillable container from a storage-induced zombie process

**Symptom:** The Jellyfin container became completely unresponsive and could not
be killed — `docker kill`, `docker rm -f`, `kill -9`, killing the process group,
and even restarting the Docker daemon all failed.

**Root cause:** A hypervisor-level I/O hiccup caused ZFS checksum errors on the
virtual disk backing the storage VM. That destabilized the SMB shares, which
caused a media-scanning `ffprobe` process to enter an **uninterruptible kernel
wait** (`D` state) while blocked on the stalled network mount. Its parent
supervisor process was in turn stuck waiting for it to exit, making the whole
container unkillable. Because the process had already closed its file
descriptors, even a lazy force-unmount of the SMB mount didn't release it.

**Resolution:** A full host reboot was required to clear the zombie. To prevent
recurrence, the SMB mount options were hardened with timeout-aware settings
(`soft`, `echo_interval`, `cache=none`, `serverino`) so a stalled mount fails
fast instead of hanging a process in uninterruptible sleep. ZFS scrub confirmed
**0 bytes repaired, 0 data errors** — the underlying data was intact.

**Lesson:** A storage-layer fault can cascade all the way up into an unkillable
userspace process. Mount-level timeout options are essential when network
storage backs containerized workloads.

### 2. Real client IPs masked behind a multi-hop proxy chain

**Symptom:** The media server logged a single internal relay IP for every
external user instead of their real public addresses, making access logs useless.

**Root cause:** Two compounding issues — (1) the reverse proxy's global
`real_ip_header` setting was overriding the per-host directive needed to read
Cloudflare's `CF-Connecting-IP`, and (2) traffic was being relayed through an
intermediate Tailscale node, so the backend only ever saw the relay's IP.

**Resolution:** Overrode the global header behavior with a host-level custom
nginx config, whitelisted Cloudflare's IP ranges, and installed Tailscale
directly on the backend to eliminate the relay hop. Verified correct end-to-end
IP passthrough for both IPv4 and IPv6 clients.

**Lesson:** In a layered proxy architecture, *every* hop has to be configured to
forward the original client IP, and a single overriding default several layers up
can silently break the whole chain.

### 3. Misleading storage dashboard vs. actual disk consumption

**Symptom:** The media server dashboard reported alarming, near-full storage
across nearly every metric.

**Root cause:** The dashboard was displaying the root partition's total/used
figures for every row rather than true per-directory usage. Actual application
config footprint was modest; the real disk consumer was Docker's accumulated
image layers.

**Resolution:** Reclaimed significant space with an image prune and established a
recurring weekly prune via cron to prevent silent disk creep going forward.

**Lesson:** Trust measured per-path numbers over dashboard summaries, and treat
container image-layer growth as a first-class disk-management concern.

### 4. OOM killer took down SMB, and nothing brought it back

**Symptom:** SMB shares went down repeatedly, sometimes staying down for **19–20
hours** at a stretch. Jellyfin lost its entire media library each time, and
nothing in the storage VM's own logs looked like a storage fault.

**Root cause:** A three-layer cascade. The photo-backup service's memory spikes
pushed the storage VM into out-of-memory territory; the kernel's OOM killer
picked **`smbd`** as a victim; and nothing was configured to restart it, so the
shares simply stayed gone until someone noticed. The reason there was no headroom
to begin with was **ZFS ARC**, which defaults to roughly half of RAM (~11.5 GB on
a 12 GB VM) and left almost nothing for everything else. An earlier attempt to
cap ARC had been written with `tee` but **never actually applied**, so a second
outage happened while the fix was believed to be in place.

**Resolution:** Four changes, deliberately layered from cause to symptom:

1. Raised the storage VM from 12 GB to 16 GB
   (`qm set <storage-vmid> --memory 16384` — which requires a full stop/start,
   not a reboot, to take effect).
2. Set a **persistent 6 GB ARC cap** via a TrueNAS Post-Init script, so it
   survives reboots instead of living in a shell session.
3. Gave the photo service a hard **6 GB container memory limit** so it can't
   consume the headroom that was just created.
4. Added the `smbd` self-heal cron as a last-resort backstop on a 5-minute
   interval.

**Lesson:** Verify that a mitigation actually applied — an unverified fix is
worse than no fix, because it stops you looking. And a cache that sizes itself to
"half of RAM" is a liability on a VM where RAM is shared with real workloads:
cap it explicitly. The self-heal cron is the least important of the four changes
and the only one that would have been visible on a dashboard.

### 5. Boot-order race plus metadata on the wrong storage tier

**Symptom:** After a routine host reboot the media VM came up effectively
unreachable, and Jellyfin either hung on startup or took 20+ seconds with
processes stuck in uninterruptible (`D`) sleep.

**Root cause:** Several independent problems surfaced together:

- **Boot race** — the storage VM wasn't serving SMB yet when the media VM booted,
  so its CIFS mounts failed outright and Jellyfin had no metadata path.
- **Wrong storage tier** — Jellyfin's 3.7 GB metadata directory lived *on the
  CIFS share* with `cache=none`. Thousands of small-file reads over an uncached
  network mount is close to the worst possible access pattern, and it was the
  real source of the hangs.
- **A silently broken container** — the extraction service had been failing for
  **11 days** because its `:latest` image shipped a non-executable binary. Being
  on `:latest` is what introduced it; nothing alerted on it.

**Resolution:** Set explicit Proxmox startup ordering and delay so storage boots
first and consumers wait for it (`--startup order=1,up=90` on storage,
`order=2` on the media VM). Moved Jellyfin's metadata to **local disk** and
repointed the compose mapping — startup dropped from 20+ seconds (or hanging) to
**7.6 seconds**. Pinned the extraction container to an explicit version tag, and
switched the whole automation stack to **monitor-only** Watchtower labels so
auto-updates can report rather than break.

**Lesson:** Distinguish *data* from *working state*. Bulk media belongs on the
network share; small-file, latency-sensitive state belongs on local disk. And
unattended auto-updates on `:latest` trade a known maintenance cost for an
unknown outage at an unpredictable time.

### 6. VPN port forward never reaching the download client

**Symptom:** The download client reported itself as "firewalled" and barely
connected to peers, despite the VPN container holding a healthy connection and a
successfully forwarded port from the provider.

**Root cause:** The forwarded port is assigned dynamically by the VPN provider and
changes on reconnect, but the hook that pushes it into the client
(`VPN_PORT_FORWARDING_UP_COMMAND`) was **empty**. The VPN container had a current
forwarded port; the client was still listening on a stale one from a previous
session. Both halves looked healthy in isolation, which is exactly why it went
unnoticed.

**Resolution:** Populated the up-command so the VPN container pushes the new port
into the client's API on every reconnect, and allowed localhost API calls to
bypass authentication so the hook can actually reach it. Recreated both
containers together and confirmed a `200 OK` in the VPN logs and the live port in
the client's own config. Also excluded the VPN container from automated updates
(`com.centurylinklabs.watchtower.enable=false`) — restarting it alone strands the
client in a dead network namespace, since the client has no network stack of its
own.

**Lesson:** When two components are each individually healthy, suspect the
plumbing between them. Anything dynamic needs an explicit propagation hook, and
containers that share a network namespace must be updated and restarted as a unit.

### 7. Telling a dying disk apart from virtualization noise

**Symptom:** A mirror member in the storage pool reported checksum errors. The
same disk had thrown errors months earlier, at which point they were attributed
to a host-side I/O hiccup — and that diagnosis was correct at the time.

**Root cause:** By the second occurrence the picture had changed: **read errors,
checksum errors, and a climbing reallocated-sector count**. Reallocated sectors
are reported by the drive's own firmware and cannot be produced by a hypervisor
hiccup, which is what moved this from "noise" to "the disk is failing".

**Resolution:** A scrub repaired **~364 KB** from the healthy mirror copy with
**no data loss**; the pool remained `ONLINE` and the mirror partner stayed clean.
Errors were cleared and the disk put on a periodic SMART check from the Proxmox
host, with a replacement planned if the reallocated-sector count keeps climbing.

**Lesson:** The same symptom can have different causes at different times — a
past diagnosis is a hypothesis, not a verdict. Pick the metric that can only come
from the layer you're accusing (here, firmware-reported reallocated sectors) and
let it decide.

---

## Design Principles

- **Isolation over convenience** — separate VMs per concern so faults stay
  contained and any layer can be rebuilt independently.
- **Zero inbound exposure** — outbound mesh tunneling instead of port forwarding;
  the home network presents no public attack surface.
- **Declarative configuration** — Docker Compose so the stack is reproducible and
  version-controllable rather than hand-assembled.
- **Defense in depth** — Cloudflare WAF/DDoS → hardened VPS → encrypted mesh →
  per-service trusted-proxy scoping.
- **Right tool per layer** — reverse proxy for HTTP, mesh VPN for inter-node,
  DNS-only for non-HTTP protocols. Be deliberate about what each layer does.
- **Operational hygiene** — monitoring, automated updates with controlled
  pinning, scheduled integrity scrubs, and automated cleanup.
- **Verify the fix, not the intent** — a mitigation that was applied in a shell
  and never persisted caused a second outage. Confirm the running state.
- **Fix causes, keep a backstop** — self-heal crons exist, but underneath each one
  is an actual root-cause fix. A watchdog is the last line, never the plan.

---

## Tech Stack

**Virtualization:** Proxmox VE
**Storage:** TrueNAS, ZFS, SMB/CIFS
**Containers:** Docker, Docker Compose, Portainer
**Networking:** Cloudflare, Nginx Proxy Manager, Tailscale (WireGuard), Ubiquiti
**Media:** Jellyfin (NVENC hardware transcoding), Immich, Seerr
**Automation:** Sonarr, Radarr, Prowlarr, Bazarr, Profilarr, Unpackerr
**Privacy:** Gluetun (VPN container with namespace-shared download client)
**Monitoring & Alerting:** Uptime Kuma, ntfy, Healthchecks.io
**Automation:** Watchtower, cron
**OS:** Ubuntu, Linux

---

## Changelog

_Last updated: October 2026._ Notable updates since the initial writeup — kept
lightweight here; anything substantial enough gets folded into
[Incident Writeups](#incident-writeups) instead.

- **Storage VM memory re-provisioning and a capped ZFS ARC**, plus per-container
  memory limits on the photo stack — see
  [the SMB/OOM write-up](#4-oom-killer-took-down-smb-and-nothing-brought-it-back).
- **Explicit Proxmox boot ordering** so storage is serving shares before any
  consumer VM starts.
- **Jellyfin metadata relocated to local disk** from the CIFS share; startup time
  down from 20+ seconds to ~7.6 seconds.
- **Update policy tightened** — the automation stack moved to monitor-only
  Watchtower labels, the extraction container pinned to an explicit version, and
  the VPN container excluded from automated restarts entirely.
- **WebSocket support enabled** on the reverse-proxy host for the photo service,
  resolving persistent client WebSocket errors.
- **Failing pool member under watch.** Read/checksum errors plus a climbing
  reallocated-sector count on one mirror member — now on periodic SMART checks
  with a replacement planned. See
  [the dying-disk write-up](#7-telling-a-dying-disk-apart-from-virtualization-noise).
- **Push alerting across every layer** — self-hosted ntfy and Uptime Kuma on the
  cloud VPS, with Watchtower, Proxmox, and TrueNAS all wired in, plus an external
  dead man's switch on the VPS itself. See [Alerting](#alerting).
- **Secrets moved out of the compose file** into a locked-down `.env`; stray
  editor backups containing a plaintext credential found and deleted. See
  [Secrets Management](#secrets-management).
- **On-demand AI containers** — the local LLM and photo-analysis job moved
  behind a Compose profile so they no longer run by default.
- **Cloud-provider firewall on the VPS** — web ports locked to Cloudflare's
  ranges, SSH and the proxy admin UI moved to mesh-VPN-only. Closed a publicly
  reachable admin UI and a WAF bypass found during external recon. See
  [Locking down the VPS edge](#locking-down-the-vps-edge).

### Open items

- **Email as a second alert channel** for the storage and hypervisor alerts,
  alongside push.
- **Mesh VPN access policy.** The VPS is the only internet-facing node, so
  scope it with tagged ACLs to just the backends and ports it proxies or
  monitors, instead of the default allow-all across the mesh.
- **Tune noisy alert topics** after a few days of real alerts — a severity
  filter on the hypervisor's notification matcher, or muting update notices.
- **Re-check the failing pool member** with `smartctl -a` from the host: high
  CRC errors with clean sectors would point to a cable rather than the disk.
- **Photo service intermittently returns 502/504 through its public hostname**
  while other services work through the same proxy chain, and it responds
  correctly on the LAN at the exact backend the proxy targets. That isolates it to
  mesh reachability from the cloud VPS to that specific VM — next step is a direct
  `curl` from the VPS plus a check of mesh status and advertised subnet routes.
  Unconfirmed.
- **Third-party Jellyfin client fails login with a 302.** Two likely causes: it
  authenticates via the request manager's auth endpoint rather than the media
  server directly, so it needs the request manager's hostname; and an `http://`
  URL gets upgraded to HTTPS by the proxy chain, which **drops the POST body** on
  redirect. Unconfirmed.
- **Slow download-client Web UI startup.** The client itself restores 262 torrents
  in ~2 seconds, so the delay is in the image's init steps or the VPN container's
  connect time, not the application. Open.

- **Home-automation network segmentation (in progress).** Moving the
  home-automation controller onto its own isolated VLAN on the gateway.
  Weighing a direct gateway firewall rule against routing it through the
  existing reverse-proxy chain, without breaking the wall-mounted dashboard
  client.
- **Gateway firewall hardening pass** — general tightening of Ubiquiti
  firewall rules beyond the baseline routing/VLAN setup.
- **New storage integrity issue under investigation.** A ZFS pool reported a
  degraded state from checksum errors on a virtual disk — a separate incident
  from the [zombie-process write-up](#1-unkillable-container-from-a-storage-induced-zombie-process)
  above. Another data point for why the platform leans on ZFS checksumming
  rather than trusting a green uptime dashboard.
- **Memory-pressure incident on the photo-backup service.** A bulk upload
  triggered an out-of-memory kill; root cause was no swap configured on that
  VM. Fixed by provisioning swap.
- **Security patching** — media server updated to close out a disclosed CVE.
- **New service: game server**, self-hosted on the Proxmox cluster and
  exposed via a public domain proxied through the cloud VPS, alongside
  private access over the mesh VPN.
- **DDNS automation** for the non-HTTP mesh VPN endpoint (see
  [Protocol-aware proxying](#protocol-aware-proxying)) — a scheduled script
  keeps its DNS record current without manual updates.

---

*Maintained as a personal engineering reference. Architecture and practices
continue to evolve.*
