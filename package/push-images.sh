#!/usr/bin/env bash
# Run in the OFFLINE environment: verify SHA256SUMS, load the images and push them under their original names (no registry address or password needed).
# Env vars: CONTAINER_CLI (docker|podman, default docker)
set -euo pipefail
cd "$(dirname "$0")"
CLI="${CONTAINER_CLI:-docker}"

(cd data && sha256sum -c SHA256SUMS)
grep -Ev '^\s*(#|$)' images.list | awk '{print $1}' | while read -r img; do
  echo "==> $img"
  "$CLI" load -i "data/images/$(echo "$img" | tr '/:' '__').tar"
  "$CLI" push "$img"
done
