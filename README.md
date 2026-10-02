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

映像清單在 `package/images.list`、模型在 `package/models.list`（需與 `inventory/group_vars/all.yml` 對應）。
映像預設 `linux/amd64`（`PLATFORM=linux/arm64` 可改）；模型用與正式環境同版本的 Ollama 容器 pull。
產出：`package/data/{images/*.tar, ollama-models.tar, SHA256SUMS}`。

**離線環境**：把 `package/data/` 帶進來放回 repo：

```bash
package/push-images.sh                                   # 校驗 SHA256SUMS，load 並以原始名稱 push
```

`push-images.sh` 先校驗 `SHA256SUMS`，再 load `data/images/` 底下**所有** `.tar`（檔名不限，映像名稱在 tar 裡面），最後把 `images.list` 的每個映像以原始名稱 push；`images.list` 有映像不在任何 tar 內就中止，不會推任何東西。

**模型自己解壓到 Ollama 的 PV**（playbook 不會匯入模型，只檢查模型都在，缺任何一個就中止）。把 `ollama-models.tar` 帶到 AI 節點後：

```bash
sudo mkdir -p /var/lib/ai/ollama
sudo tar -xf ollama-models.tar -C /var/lib/ai/ollama     # tar 最上層是 models/
ls /var/lib/ai/ollama/models                              # 要看到 blobs  manifests
```

`/var/lib/ai/ollama` 就是 Ollama 的 PV（容器內掛在 `/root/.ollama`），模型必須放在其下的 `models/{blobs,manifests}`。
`ollama_models` 清單內的模型（含主力 `ollama_primary_model` 與嵌入 `ollama_embed_model`）都要在，否則部署在 `models` 步驟中止並列出缺的模型。

## 2. 部署

```bash
cd eck-llm-mcp-playbook
# 改 inventory/hosts.yaml（主機名稱＝k8s 節點名稱、ansible_host；直接在節點上跑可加 ansible_connection: local）
ansible-playbook site.yml                 # 部署 + 驗證
ansible-playbook site.yml --tags models     # 只檢查模型是否都在 PV 上
ansible-playbook site.yml --tags knowledge  # 只重新同步知識庫與助手模型（改了 templates/knowledge/ 之後）
ansible-playbook site.yml --tags verify     # 只重跑驗證
```

第一次請不要加 `--tags`。重跑安全（`kubectl apply`；Secret 不存在才建，密碼不會更換；知識庫與助手模型每次重建）。
`--check` 對本 role 沒意義（大量 `command` 會被跳過）。

流程：建 namespace/PV → 檢查模型 → 建 Secret → 在 ES 建唯讀帳號 → 部署 Ollama、es-mcp → 等 MetalLB 配 IP →
`ca-issuer` 簽發該 IP 的憑證 → 部署 Open WebUI（nginx sidecar 終止 TLS）→ 同步知識庫與助手模型 → 驗證。結束時印出網址與 admin 密碼取回指令。
整個部署只佔用 **1 個 LoadBalancer IP**（`open-webui` Service）；Ollama 與 es-mcp 都是叢集內的 ClusterIP。

**自動完成的事**
- **ES 唯讀帳號**：用 ECK 的 `elastic` 密碼建角色 `mcp_readonly`（read / view_index_metadata / monitor，範圍 `mcp_index_patterns`）與 `mcp_user`；密碼隨機產生，只存在 Secret `es-mcp-cred`。
- **Open WebUI**：首次啟動自動建 admin（`admin@example.com`，密碼在 Secret `open-webui-secret`）並關閉開放註冊；自動註冊 es-mcp 並開放給所有使用者；預設 Function Calling 為 Native。
- **知識庫與助手模型**：把 `templates/knowledge/*.md` 上傳成知識庫「ES 深度查詢知識庫」（所有使用者可讀），並建立模型「ES 深度查詢助手」（基底為主力模型，內建 System Prompt、該知識庫與 Elasticsearch 工具）。見下方「RAG 知識庫文件」。
- **驗證（`verify`）**：Ollama 模型清單、tool_calls、es-mcp 工具清單、`mcp_user` 權限（`list_indices`）、Open WebUI 已註冊 es-mcp。

**部署後手動**：用 admin 登入建立其他使用者（Admin → Users；建立時角色選 `user`，預設的 `pending` 無法使用）；對話時模型選「ES 深度查詢助手」（若 Elasticsearch 工具沒有自動啟用，在輸入框 **Tools** 勾選）。

**帳號與密碼**
- Open WebUI admin：`admin@example.com`；密碼：
  ```bash
  kubectl -n ai get secret open-webui-secret -o jsonpath='{.data.WEBUI_ADMIN_PASSWORD}' | base64 -d
  ```
- MCP 連 ES 用的 `mcp_user` 帳密由 playbook 自動建立（Secret `es-mcp-cred`），不需要處理；admin 之後建立的所有使用者都能用 MCP（連線已開放給所有登入使用者）。
- 所有使用者共用同一個唯讀 ES 帳號 `mcp_user`，可讀範圍由 `mcp_index_patterns` 決定，不是各自的 ES 權限。

### RAG 知識庫文件

`roles/kubectl/eck-llm-mcp/templates/knowledge/*.md` 是 §7.1 的 index 語意說明與「自然語言 → DSL」範例，部署時自動上傳到 Open WebUI 知識庫（用 bge-m3 嵌入）：

| 檔案 | 內容 |
|---|---|
| `netflow-schema.md` | `netflow-*` 的欄位說明與 7 組範例（網段 Top N、國家排名、趨勢、大流量、疑似掃描、ES\|QL） |
| `geofence-queries.md` | 地理圍欄範例（距離、矩形、多邊形、排除國家、格網熱點） |
| `cluster-topology.md` | 叢集 / 分片拓撲分析（`list_indices`、`get_shards` 的用法與判讀） |
| `query-correctness-rules.md` | 通用正確性規則：型別與寫法、常見錯誤的修正對照 |

另有 `templates/system-prompt.txt`（規劃書 §7.5 的 System Prompt，會寫進助手模型）。

**這些是範例，部署前請依你的實際 index 與欄位修改**（index 名稱、欄位名、型別、範例值、座標）；新增 index 就新增一份 `.md`（副檔名必須是 `.md`）。檔案原樣上傳，不會被 Jinja 渲染，可以放任何 DSL。
改完文件後重新部署，或只跑 `ansible-playbook site.yml --tags knowledge`（會刪除並重建知識庫與助手模型）。
注意：若 admin 密碼已在 UI 改過，這一步無法登入，會顯示警告並略過，請到 Workspace → Knowledge 手動上傳。
索引存在 `openwebui` PV，不在 ES；PV 被清空後重跑即可重建。

## 3. 參數

環境相關的值在 `inventory/group_vars/all.yml`（模型、映像、`mcp_index_patterns`、VIP），其餘在 `roles/kubectl/eck-llm-mcp/defaults/main.yml`；覆寫一律寫到 `all.yml`。環境相符就不用改。

| 變數 | 預設 | 說明 |
|---|---|---|
| `ollama_models` | qwen3.6:35b、bge-m3:latest | 都要已解壓在 Ollama PV 上，缺任何一個就中止；備援 `qwen3-coder:30b` 有打包才加進來 |
| `ollama_primary_model` `ollama_embed_model` | `qwen3.6:35b`、`bge-m3:latest` | 主力模型（預設對話、tool_calls 驗證、助手模型基底）與 RAG 嵌入模型，都必須在 `ollama_models` 內 |
| `eck_es_name` `eck_namespace` | `prod`、`elastic-stack` | stack 的 Elasticsearch 資源（不是 operator）；`kubectl get elasticsearch -A` |
| `mcp_index_patterns` | `["*"]` | es-mcp 可讀的 index，建議收斂（例如 `["netflow-*"]`）；es-mcp 的 `/mcp` 無認證，這是主要的權限邊界 |
| `ollama_image` `open_webui_image` `es_mcp_image` `nginx_image` | 原始名稱 | 與 `package/images.list` 逐字一致 |
| `ollama_context_length` | `32768` | 太小會截掉工具定義，模型就不呼叫工具 |
| `ollama_num_thread` | `16` | 推論執行緒數，見下 |
| `ollama_cpu_limit` | `ollama_num_thread + 2` | Ollama CPU 上限（自動推導，一般不用改） |
| `ollama_memory_limit` | `128Gi` | Ollama 記憶體上限 |
| `cert_issuer_name` | `ca-issuer` | CA 型 ClusterIssuer（`kubectl get clusterissuer`） |
| `knowledge_base_name` `assistant_model_id` `assistant_model_name` | 見 `defaults/main.yml` | 知識庫與助手模型的名稱 |
| `open_webui_vip` | 空 | 空＝MetalLB 自動配發；要固定 IP 時填 |

### 調校（CPU 推論、controller 兼跑 control plane）

- **記憶體**：主力模型約 24GB（MoE，每 token 僅 3B 啟用），1TB RAM 綽綽有餘；模板已設 `KEEP_ALIVE=-1`（不卸載）、`MAX_LOADED_MODELS=3`、`NUM_PARALLEL=4`。瓶頸是 CPU 與記憶體頻寬。
- **保護 etcd / apiserver**：兩層保護。(1) `ollama_num_thread` 控制推論執行緒數（透過 Open WebUI 的模型預設參數 `num_thread` 帶給 Ollama，`verify` 的測試也帶同一個值）；(2) CPU limit 設為 `ollama_num_thread + 2`，正常推論不會被 cgroup 限流，但繞過 `num_thread` 的呼叫（知識庫 embedding、直接打 Ollama API）也無法用滿所有核心。CPU request 只有 1，節點飽和時 etcd / apiserver 的 CPU 權重較高。先確認核心配置：`lscpu | grep -E 'Socket|Core|Thread'`——若 40 是含超執行緒的邏輯核（20 實體核），設成實體核數 − 4 左右（例如 16）。
- 用 `kubectl -n ai exec deploy/ollama -- ollama ps` 觀察實際佔用與載入的模型再調整。

### HTTPS / CA

Open WebUI 由 nginx sidecar 終止 TLS，憑證由 `ca-issuer` 簽發（SAN 為 Service 的 MetalLB IP），每 6 小時自動 reload 以載入續簽的憑證。
與其他服務同一張 CA，瀏覽器信任一次即可。Service 若被刪除重建導致 IP 改變，重跑 playbook 會重簽憑證；想避免就填 `open_webui_vip` 固定 IP。
**匯出要讓瀏覽器信任的 CA**：CA 憑證在 ClusterIssuer 指向的 Secret 內（這個環境：`ca-issuer` → Secret `ca-key-pair`，在 `cert-manager` namespace）：

```bash
kubectl get clusterissuer ca-issuer -o jsonpath='{.spec.ca.secretName}'      # 確認 Secret 名稱：ca-key-pair
kubectl -n cert-manager get secret ca-key-pair -o jsonpath='{.data.tls\.crt}' | base64 -d > eck-ca.crt
openssl x509 -in eck-ca.crt -noout -subject -issuer -dates                   # 確認是 CA（subject 與 issuer 相同＝根 CA）
```

只匯出 `tls.crt`；同一個 Secret 的 `tls.key` 是 CA 私鑰，不要外流。若 Secret 不在 `cert-manager` namespace，用 `kubectl get secret -A | grep ca-key-pair` 找。
把 `eck-ca.crt` 發給使用者，匯入「受信任的根憑證授權單位」：
- **Windows**：雙擊 `.crt` → 安裝憑證 → 本機電腦 → 將所有憑證放入「受信任的根憑證授權單位」（Chrome、Edge 吃系統憑證庫）。
- **Firefox**（自己的憑證庫）：設定 → 隱私權與安全性 → 憑證 → 檢視憑證 → 憑證機構 → 匯入，勾選「信任這個 CA 來識別網站」。
- **macOS**：鑰匙圈存取 → 系統 → 匯入 → 雙擊該憑證 → 信任 → 「永遠信任」。
- **Linux**：`sudo cp eck-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`。

ES 本身仍是 ECK 自簽憑證，es-mcp 以 `ES_SSL_SKIP_VERIFY=true` 連線（僅叢集內 pod → ES）。

## 4. 限制與疑難排解

- Open WebUI 的 admin 與 MCP 連線是「首次啟動寫入 DB」：之後要改 MCP 連線請到 Admin → Settings → Integrations，或清空 `openwebui` PV 後重跑。知識庫索引存在該 PV，不在 ES。
- 不處理：映像/模型下載（用 `package/`）、規劃書 §9 的功能任務驗證。

| 症狀 | 處理 |
|---|---|
| 部署失敗訊息內有 `ImagePullBackOff` | 映像名稱與 registry 內不一致，或節點 mirror 未涵蓋該 registry（ghcr.io、docker.elastic.co） |
| Pod `Pending` | `kubectl -n ai describe pod`：nodeSelector（inventory 主機名稱要等於節點名稱）、記憶體不足、PVC 未 Bound |
| `models` 步驟中止（缺模型） | 依第 1 節把 `ollama-models.tar` 解壓到 `/var/lib/ai/ollama`，確認 `/var/lib/ai/ollama/models/{blobs,manifests}` 存在 |
| 知識庫同步 `[FAIL]` / 檢索沒有結果 | 看輸出的 `[FAIL]` 行；檢索失敗通常是 `bge-m3` 不在 Ollama 或 `RAG_OLLAMA_BASE_URL` 不通 |
| 一般使用者查不到知識庫 | 同步時若出現「沒有所有使用者可讀的授權」警告，到 Admin 開啟公開分享知識庫的權限後重跑 `--tags knowledge` |
| ES 連不到 / 401 | `eck_es_name`、`eck_namespace` 與 `kubectl get elasticsearch -A` 不符；目標主機需能連到 ES 的 ClusterIP |
| 模型不呼叫工具 | `ollama_context_length` 太小；`verify` 第 2 項可確認模型本身的 tool_calls |
| `list_indices` 403 | `mcp_index_patterns` 沒涵蓋要查的 index |
| 使用者看不到 Elasticsearch 工具 | 輸入框要勾選 Tools；若 DB 內已有舊連線設定，環境變數不會覆蓋 |
| 瀏覽器憑證警告 | 該使用者尚未信任 `ca-issuer` 的 CA（匯出與匯入見「HTTPS / CA」） |
