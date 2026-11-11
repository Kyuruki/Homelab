#!/bin/sh
# Protect smbd from the OOM killer and auto-restart it if it dies anyway.
#
# Installed as a TrueNAS Post Init script (System -> Advanced -> Init/Shutdown
# Scripts, type Command, timeout 10). The drop-in lives in /run because TrueNAS
# overwrites persistent system config, so Post Init re-applies it every boot.
#
# Verify: systemctl show smbd -p OOMScoreAdjust -p Restart -p RestartUSec
#   -> OOMScoreAdjust=-900, Restart=on-failure, RestartUSec=5s
mkdir -p /run/systemd/system/smbd.service.d && printf '[Service]\nOOMScoreAdjust=-900\nRestart=on-failure\nRestartSec=5\n' > /run/systemd/system/smbd.service.d/override.conf && systemctl daemon-reload
