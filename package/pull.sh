#!/usr/bin/env bash
# 在「有網路」的機器執行：拉映像存成 tar、拉模型打包成 tar，並產生 SHA256SUMS。
# 用法：package/pull.sh [images|models|all]（預設 all）
# 輸出（package/data/，已 gitignore）：images/*.tar、ollama-models.tar、SHA256SUMS
# 環境變數：PLATFORM（預設 linux/amd64）、CONTAINER_CLI（docker|podman，預設 docker）
set -euo pipefail
cd "$(dirname "$0")"
CLI="${CONTAINER_CLI:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
what="${1:-all}"
list() { grep -Ev '^\s*(#|$)' "$1" | awk '{print $1}'; }

pull_images() {
  mkdir -p data/images
  list images.list | while read -r img; do
    echo "==> $img ($PLATFORM)"
    "$CLI" pull --platform "$PLATFORM" "$img"
    "$CLI" save -o "data/images/$(echo "$img" | tr '/:' '__').tar" "$img"
  done
}

pull_models() {
  # 用與正式環境同版本的 Ollama 容器 pull，模型目錄位置才確定
  local ollama_image data user_args=()
  ollama_image="$(list images.list | grep 'ollama/ollama:' | head -1)"
  data="$PWD/data/ollama-data"
  name="ollama-pull-$$"   # 全域變數：EXIT trap 執行時 function 已結束
  mkdir -p "$data/models"
  [ "$CLI" = docker ] && user_args=(--user "$(id -u):$(id -g)")   # 檔案 owner 是目前使用者，才能 tar / 清理
  trap '"$CLI" rm -f "$name" >/dev/null 2>&1 || true' EXIT
  "$CLI" run -d --name "$name" ${user_args[@]+"${user_args[@]}"} -e HOME=/tmp -e OLLAMA_MODELS=/models \
    -v "$data/models:/models" "$ollama_image" >/dev/null
  for _ in $(seq 1 60); do "$CLI" exec "$name" ollama list >/dev/null 2>&1 && break; sleep 1; done
  list models.list | while read -r model; do
    echo "==> ollama pull $model"
    "$CLI" exec "$name" ollama pull "$model"
  done
  "$CLI" exec "$name" ollama list
  tar cf data/ollama-models.tar -C "$data" models     # blob 已壓縮，不必 gzip
}

case "$what" in
  images) pull_images ;;
  models) pull_models ;;
  all)    pull_images; pull_models ;;
  *) echo "用法：$0 [images|models|all]" >&2; exit 1 ;;
esac

(cd data && { ls images/*.tar; ls ollama-models.tar; } 2>/dev/null | xargs sha256sum > SHA256SUMS)
echo "==> data/SHA256SUMS"; cat data/SHA256SUMS
echo "帶走：package/data/{images,ollama-models.tar,SHA256SUMS}（ollama-data/ 是暫存，不必帶）"
