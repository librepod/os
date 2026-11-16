#!/usr/bin/env bash
# Logs the device's setup code (the sticker's, minted by librepod-install) for
# the console. The OS agent publishes its bcrypt hash in the Device
# (status.setupCodeHash), and k3s is not needed here. Every boot; idempotent.
set -euo pipefail

CODE_FILE="${LIBREPOD_SETUP_CODE_FILE:-/var/lib/librepod/setup-code}"
# Never minted here: marketplace-ui then mints one and logs it, where the owner
# of a device without a sticker can read it.
[ -f "$CODE_FILE" ] || { echo "no $CODE_FILE: marketplace-ui mints and logs a setup code"; exit 0; }

# For a device without its sticker: journalctl -u librepod-setup-code -o cat.
# Only root and wheel read the journal; the file is root-only already.
CODE="$(< "$CODE_FILE")"
CODE="${CODE:0:4}-${CODE:4:4}-${CODE:8:4}"
URL="http://$(< /proc/sys/kernel/hostname).local/#code=$CODE"
echo "Setup code: $CODE"
echo "Open $URL or scan:"
qrencode -t UTF8 -m 2 "$URL"
