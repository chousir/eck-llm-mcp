# eck-llm-mcp

在既有 ECK（Elastic on Kubernetes）叢集上，額外部署「自然語言深度查詢」：
**Ollama（LLM 推論）+ Elasticsearch MCP Server + Open WebUI（多人前端 / MCP client，HTTPS）**。

- 架構與設計理由：[`ECK深度查詢擴充規劃書_LLM_MCP.md`](./ECK深度查詢擴充規劃書_LLM_MCP.md)
- 部署：[`eck-llm-mcp-playbook/`](./eck-llm-mcp-playbook)（Ansible，一次 `ansible-playbook site.yml` 部署並驗證）
- 離線資料：[`package/`](./package)（拉映像、拉模型的腳本；產出物在 `package/data/`，已 gitignore）

## 環境假設（寫死在 playbook，不是變數）

kubespray 建出的單一 cluster；Ansible 目標主機就是 AI 節點（`inventory/hosts.yaml` 的主機名稱**必須等於 k8s 節點名稱**，即 `kubectl get nodes` 的 NAME；需 python3 與 sudo）。

| 假設 | 內容 |
|---|---|
| kubectl | 以 root（become）直接執行 `kubectl`：root 的 PATH 找得到 kubectl，且有 kubeconfig（kubespray 會放 `/root/.kube/config`） |
| 映像 | 節點可直接以原始名稱 pull（不加 registry 位址，例如 `ollama/ollama:0.32.9`） |
| 對外 | MetalLB 配發 LoadBalancer IP |
| TLS | cert-manager 有 CA 型 ClusterIssuer `ca-issuer`；使用者瀏覽器已信任該 CA |
| ECK | Elasticsearch 資源為 `elastic-stack/prod`（Service `prod-es-http`、Secret `prod-es-elastic-user`），啟用 security |
| 節點 | control-plane taint 為 `node-role.kubernetes.io/control-plane`；CPU 需支援 AVX2 |
| Pod Security | `ai` namespace 不可為 `restricted`（Ollama / Open WebUI 以 root 跑） |
| 本地 PV | `/var/lib/ai/ollama`（60Gi）、`/var/lib/ai/openwebui`（10Gi）；**PV/PVC 容量建立後不可變更，要改須先刪除重建** |

## 1. 離線準備：`package/`

**有網路的機器**（需 docker，或 `CONTAINER_CLI=podman`）：

```bash
package/pull.sh            # 映像 + 模型 + SHA256SUMS（也可 pull.sh images / pull.sh models）
```

映像清單在 `package/images.list`、模型在 `package/models.list`（需與 `defaults/main.yml` 對應）。
映像預設 `linux/amd64`（`PLATFORM=linux/arm64` 可改）；模型用與正式環境同版本的 Ollama 容器 pull。
產出：`package/data/{images/*.tar, ollama-models.tar, SHA256SUMS}`。

**離線環境**：把 `package/data/` 帶進來放回 repo：

```bash
package/push-images.sh                                   # 校驗 SHA256SUMS，load 並以原始名稱 push
sudo install -D -m 0644 package/data/ollama-models.tar /opt/eck-llm-mcp/ollama-models.tar   # AI 節點上
```

模型 tar 不必手動解開，playbook 會在 PV 缺模型時匯入。

## 2. 部署

```bash
cd eck-llm-mcp-playbook
# 改 inventory/hosts.yaml（主機名稱＝k8s 節點名稱、ansible_host；直接在節點上跑可加 ansible_connection: local）
ansible-playbook site.yml                 # 部署 + 驗證
ansible-playbook site.yml --tags models   # 只匯入模型（之後新增模型時）
ansible-playbook site.yml --tags verify   # 只重跑驗證
```

第一次請不要加 `--tags`。重跑安全（`kubectl apply`；模型缺才匯入；Secret 不存在才建，密碼不會更換）。
`--check` 對本 role 沒意義（大量 `command` 會被跳過）。

流程：建 namespace/PV → 匯入模型 → 建 Secret → 在 ES 建唯讀帳號 → 部署 Ollama、es-mcp → 等 MetalLB 配 IP →
`ca-issuer` 簽發該 IP 的憑證 → 部署 Open WebUI（nginx sidecar 終止 TLS）→ 驗證。結束時印出網址與 admin 密碼取回指令。

**自動完成的事**
- **ES 唯讀帳號**：用 ECK 的 `elastic` 密碼建角色 `mcp_readonly`（read / view_index_metadata / monitor，範圍 `mcp_index_patterns`）與 `mcp_user`；密碼隨機產生，只存在 Secret `es-mcp-cred`。
- **Open WebUI**：首次啟動自動建 admin（`admin@example.com`，密碼在 Secret `open-webui-secret`）並關閉開放註冊；自動註冊 es-mcp 並開放給所有使用者；預設 Function Calling 為 Native。
- **驗證（`verify`）**：Ollama 模型清單、tool_calls、es-mcp 工具清單、`mcp_user` 權限（`list_indices`）、Open WebUI 已註冊 es-mcp。

**部署後手動**：用 admin 登入建立其他使用者（Admin → Users）；對話時在輸入框 **Tools** 勾選 `Elasticsearch`；知識庫與 System Prompt 見規劃書 §7。

## 3. 參數

環境相關的值在 `inventory/group_vars/all.yml`（模型、映像、模型 tar 路徑、VIP），其餘在 `roles/kubectl/eck-llm-mcp/defaults/main.yml`；覆寫一律寫到 `all.yml`。環境相符就不用改。

| 變數 | 預設 | 說明 |
|---|---|---|
| `ollama_models_src` | `/opt/eck-llm-mcp/ollama-models.tar` | 模型 tar 在目標主機的路徑（PV 缺模型時才讀） |
| `ollama_models` | qwen3.6:35b、bge-m3:latest（多語言嵌入，RAG 用） | 第一個是主力模型；備援 `qwen3-coder:30b` 有打包才加進來 |
| `eck_es_name` `eck_namespace` | `prod`、`elastic-stack` | stack 的 Elasticsearch 資源（不是 operator）；`kubectl get elasticsearch -A` |
| `mcp_index_patterns` | `["*"]` | es-mcp 可讀的 index，建議收斂（例如 `["netflow-*"]`）；es-mcp 的 `/mcp` 無認證，這是主要的權限邊界 |
| `ollama_image` `open_webui_image` `es_mcp_image` `nginx_image` | 原始名稱 | 與 `package/images.list` 逐字一致 |
| `ollama_context_length` | `32768` | 太小會截掉工具定義，模型就不呼叫工具 |
| `ollama_num_thread` | `32` | 推論執行緒數，見下 |
| `ollama_cpu_limit` | `ollama_num_thread + 2` | Ollama CPU 上限（自動推導，一般不用改） |
| `ollama_memory_limit` | `128Gi` | Ollama 記憶體上限 |
| `cert_issuer_name` | `ca-issuer` | CA 型 ClusterIssuer |
| `open_webui_vip` | 空 | 空＝MetalLB 自動配發；要固定 IP 時填 |

### 調校（CPU 推論、controller 兼跑 control plane）

- **記憶體**：主力模型約 24GB（MoE，每 token 僅 3B 啟用），1TB RAM 綽綽有餘；模板已設 `KEEP_ALIVE=-1`（不卸載）、`MAX_LOADED_MODELS=3`、`NUM_PARALLEL=4`。瓶頸是 CPU 與記憶體頻寬。
- **保護 etcd / apiserver**：兩層保護。(1) `ollama_num_thread` 控制推論執行緒數（透過 Open WebUI 的模型預設參數 `num_thread` 帶給 Ollama，`verify` 的測試也帶同一個值）；(2) CPU limit 設為 `ollama_num_thread + 2`，正常推論不會被 cgroup 限流，但繞過 `num_thread` 的呼叫（知識庫 embedding、直接打 Ollama API）也無法用滿所有核心。CPU request 只有 1，節點飽和時 etcd / apiserver 的 CPU 權重較高。先確認核心配置：`lscpu | grep -E 'Socket|Core|Thread'`——若 40 是含超執行緒的邏輯核（20 實體核），設成實體核數 − 4 左右（例如 16）。
- 用 `kubectl -n ai exec deploy/ollama -- ollama ps` 觀察實際佔用與載入的模型再調整。

### HTTPS / CA

Open WebUI 由 nginx sidecar 終止 TLS，憑證由 `ca-issuer` 簽發（SAN 為 Service 的 MetalLB IP），每 6 小時自動 reload 以載入續簽的憑證。
與其他服務同一張 CA，瀏覽器信任一次即可。Service 若被刪除重建導致 IP 改變，重跑 playbook 會重簽憑證；想避免就填 `open_webui_vip` 固定 IP。
ES 本身仍是 ECK 自簽憑證，es-mcp 以 `ES_SSL_SKIP_VERIFY=true` 連線（僅叢集內 pod → ES）。

## 4. 限制與疑難排解

- Open WebUI 的 admin 與 MCP 連線是「首次啟動寫入 DB」：之後要改 MCP 連線請到 Admin → Settings → Integrations，或清空 `openwebui` PV 後重跑。知識庫索引存在該 PV，不在 ES。
- 不處理：映像/模型下載（用 `package/`）、規劃書 §9 的功能任務驗證。

| 症狀 | 處理 |
|---|---|
| 部署失敗訊息內有 `ImagePullBackOff` | 映像名稱與 registry 內不一致，或節點 mirror 未涵蓋該 registry（ghcr.io、docker.elastic.co） |
| Pod `Pending` | `kubectl -n ai describe pod`：nodeSelector（inventory 主機名稱要等於節點名稱）、記憶體不足、PVC 未 Bound |
| 找不到模型 tar / 缺模型 | 依第 1 節把 `ollama-models.tar` 放到 `ollama_models_src` |
| ES 連不到 / 401 | `eck_es_name`、`eck_namespace` 與 `kubectl get elasticsearch -A` 不符；目標主機需能連到 ES 的 ClusterIP |
| 模型不呼叫工具 | `ollama_context_length` 太小；`verify` 第 2 項可確認模型本身的 tool_calls |
| `list_indices` 403 | `mcp_index_patterns` 沒涵蓋要查的 index |
| 使用者看不到 Elasticsearch 工具 | 輸入框要勾選 Tools；若 DB 內已有舊連線設定，環境變數不會覆蓋 |
| 瀏覽器憑證警告 | 該使用者尚未信任 `ca-issuer` 的 CA |
