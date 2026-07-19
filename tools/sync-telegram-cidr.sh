#!/bin/sh
# Compat wrapper — full multi-service sync lives in sync-vpn-cidr.sh
exec "$(CDPATH= cd -- "$(dirname "$0")" && pwd)/sync-vpn-cidr.sh" "$@"
