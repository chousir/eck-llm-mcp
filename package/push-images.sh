#!/usr/bin/env bash
# 在「離線環境」執行：校驗 SHA256SUMS，load 映像並以原始名稱 push（registry 不需地址與密碼）。
# 環境變數：CONTAINER_CLI（docker|podman，預設 docker）
set -euo pipefail
cd "$(dirname "$0")"
CLI="${CONTAINER_CLI:-docker}"

(cd data && sha256sum -c SHA256SUMS)
grep -Ev '^\s*(#|$)' images.list | awk '{print $1}' | while read -r img; do
  echo "==> $img"
  "$CLI" load -i "data/images/$(echo "$img" | tr '/:' '__').tar"
  "$CLI" push "$img"
done
