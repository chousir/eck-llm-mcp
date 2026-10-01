#!/usr/bin/env bash
# Run on a machine WITH internet access: pull images into tars, pull models into a tar, and write SHA256SUMS.
# Usage: package/pull.sh [images|models|all]  (default: all)
# Output (package/data/, gitignored): images/*.tar, ollama-models.tar, SHA256SUMS
# Env vars: PLATFORM (default linux/amd64), CONTAINER_CLI (docker|podman, default docker)
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
  # Pull with the same Ollama version as production so the models directory layout is known
  local ollama_image data user_args=()
  ollama_image="$(list images.list | grep 'ollama/ollama:' | head -1)"
  data="$PWD/data/ollama-data"
  name="ollama-pull-$$"   # global on purpose: the function has already returned when the EXIT trap runs
  mkdir -p "$data/models"
  [ "$CLI" = docker ] && user_args=(--user "$(id -u):$(id -g)")   # files owned by the current user so they can be tarred / cleaned up
  trap '"$CLI" rm -f "$name" >/dev/null 2>&1 || true' EXIT
  "$CLI" run -d --name "$name" ${user_args[@]+"${user_args[@]}"} -e HOME=/tmp -e OLLAMA_MODELS=/models \
    -v "$data/models:/models" "$ollama_image" >/dev/null
  for _ in $(seq 1 60); do "$CLI" exec "$name" ollama list >/dev/null 2>&1 && break; sleep 1; done
  list models.list | while read -r model; do
    echo "==> ollama pull $model"
    "$CLI" exec "$name" ollama pull "$model"
  done
  "$CLI" exec "$name" ollama list
  tar cf data/ollama-models.tar -C "$data" models     # blobs are already compressed, no gzip needed
}

case "$what" in
  images) pull_images ;;
  models) pull_models ;;
  all)    pull_images; pull_models ;;
  *) echo "用法：$0 [images|models|all]" >&2; exit 1 ;;
esac

# Only list what exists: "pull.sh images" runs before any model tar does (and the reverse)
(cd data && files=() && for f in images/*.tar ollama-models.tar; do
  if [ -e "$f" ]; then files+=("$f"); fi
done && sha256sum "${files[@]}" > SHA256SUMS)
echo "==> data/SHA256SUMS"; cat data/SHA256SUMS
echo "帶走：package/data/{images,ollama-models.tar,SHA256SUMS}（ollama-data/ 是暫存，不必帶）"
