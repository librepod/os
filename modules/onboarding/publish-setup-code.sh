#!/usr/bin/env bash
# Hands the device's setup code (the sticker's, minted by librepod-install) to
# marketplace-ui, which adopts it from this Secret. Every boot; idempotent.
set -euo pipefail

CODE_FILE="${LIBREPOD_SETUP_CODE_FILE:-/var/lib/librepod/setup-code}"
# Never minted here: marketplace-ui then mints one and logs it, where the owner
# of a device without a sticker can read it.
[ -f "$CODE_FILE" ] || { echo "no $CODE_FILE: marketplace-ui mints and logs a setup code"; exit 0; }

# Wait for K3S API (up to 5 min).
for i in $(seq 1 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "Timed out waiting for K3S API"; exit 1; }
  sleep 5
done

kubectl create namespace marketplace-ui --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic librepod-setup-code --namespace marketplace-ui \
  --from-file=code="$CODE_FILE" --dry-run=client -o yaml | kubectl apply -f -
