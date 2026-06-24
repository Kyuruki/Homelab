# Self-Hosted Homelab & Cloud Infrastructure

A production-grade, self-hosted infrastructure platform running 13+ containerized
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
- [Incident Writeups](#incident-writeups)
- [Design Principles](#design-principles)
- [Tech Stack](#tech-stack)

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

ZFS checksumming proved its value during a real incident (see
[Incident Writeups](#incident-writeups)) where silent disk-level corruption was
detected and confirmed non-destructive because a scrub repaired 0 bytes with 0
data errors — the data was intact and verifiable.

---

## Service Inventory

The platform runs **13+ containerized services**, defined declaratively via
Docker Compose. Highlights:

### Media

| Service     | Purpose                                            |
| ----------- | -------------------------------------------------- |
| Jellyfin    | Media server with GPU hardware transcoding         |
| Immich      | Self-hosted family photo & video backup            |
| Tautulli    | Streaming analytics & monitoring                   |

### Networking & Access

| Service              | Purpose                                       |
| -------------------- | --------------------------------------------- |
| Nginx Proxy Manager  | Reverse proxy + Let's Encrypt TLS termination |
| Tailscale            | Mesh VPN (WireGuard) between nodes            |

### Operations

| Service     | Purpose                                            |
| ----------- | -------------------------------------------------- |
| Portainer   | Container management UI                            |
| Netdata     | Real-time host & container metrics                 |
| Homepage    | Unified service dashboard                          |
| Watchtower  | Automated container image updates                  |

The media services share a dedicated Docker bridge network and read media from
the TrueNAS SMB mounts, keeping storage centralized and the compute layer
stateless.

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

---

## Observability & Maintenance

- **Netdata** provides real-time per-container and host-level metrics.
- **Tautulli** tracks media streaming activity and transcode load.
- **Watchtower** automates image updates, with specific containers intentionally
  pinned to named tags so updates are controlled rather than surprise-breaking.
- **Scheduled ZFS scrubs** verify data integrity on the storage pool.
- **Automated cleanup** — a cron job prunes dangling Docker images weekly to keep
  the compute VM's disk usage in check.

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

---

## Tech Stack

**Virtualization:** Proxmox VE
**Storage:** TrueNAS, ZFS, SMB/CIFS
**Containers:** Docker, Docker Compose, Portainer
**Networking:** Cloudflare, Nginx Proxy Manager, Tailscale (WireGuard), Ubiquiti
**Media:** Jellyfin (NVENC hardware transcoding), Immich, Tautulli
**Monitoring:** Netdata, Tautulli
**Automation:** Watchtower, cron
**OS:** Ubuntu, Linux

---

*Maintained as a personal engineering reference. Architecture and practices
continue to evolve.*
