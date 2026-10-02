#!/usr/bin/env bash
# Run in the OFFLINE environment: verify SHA256SUMS, load every image tar and push the images in images.list under their original names
# (no registry address or password needed).
# The tar file names do not matter (pull.sh writes ollama_ollama_0.32.9.tar, other tools write other names): the image names live inside
# the tars, so every data/images/*.tar is loaded and each image in images.list must exist afterwards.
# Env vars: CONTAINER_CLI (docker|podman, default docker)
set -euo pipefail
cd "$(dirname "$0")"
CLI="${CONTAINER_CLI:-docker}"

(cd data && sha256sum -c SHA256SUMS)

shopt -s nullglob
tars=(data/images/*.tar)
[ "${#tars[@]}" -gt 0 ] || { echo "data/images/ 裡沒有 .tar" >&2; exit 1; }
for t in "${tars[@]}"; do
  echo "==> load $t"
  "$CLI" load -i "$t"
done

missing=0
while read -r img; do
  if ! "$CLI" image inspect "$img" >/dev/null 2>&1; then
    echo "缺少映像 $img：data/images/ 的 tar 都沒有它（版本與 images.list 不一致？）" >&2
    missing=1
  fi
done < <(grep -Ev '^\s*(#|$)' images.list | awk '{print $1}')
[ "$missing" -eq 0 ] || exit 1

grep -Ev '^\s*(#|$)' images.list | awk '{print $1}' | while read -r img; do
  echo "==> push $img"
  "$CLI" push "$img"
done
