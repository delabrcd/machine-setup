#!/usr/bin/env bash
ensure_wsl_interop || warn "WSL interop fix failed — Windows .exe calls (e.g. GCM bridge) won't work"
