# eck-llm-mcp

在既有 ECK（Elastic on Kubernetes）叢集上，額外部署一層「自然語言深度查詢」能力：
**Ollama（LLM 推論）+ Elasticsearch MCP Server（把 ES 包成工具）+ Open WebUI（多人前端 / MCP client）**。

- 架構與設計理由：[`ECK深度查詢擴充規劃書_LLM_MCP.md`](./ECK深度查詢擴充規劃書_LLM_MCP.md)（本 README 對應其中 §3–§6）
- 實際部署工具：本 repo 的 [`eck-llm-mcp-playbook/`](./eck-llm-mcp-playbook) — 一支 Ansible playbook

目標環境是 **air-gapped（離線）**：本 playbook 只負責「把已經備妥的映像/模型組成叢集資源」，
不處理映像 pull/push、模型下載——這些必須在有網路的環境先做好，帶進來之後才跑本 playbook。

下面所有指令都假設你已經 `cd eck-llm-mcp-playbook`。

---

## 目錄結構

```
eck-llm-mcp-playbook/
├── ansible.cfg
├── inventory/
│   ├── hosts                  # ← 要改的連線資訊
│   └── group_vars/all.yml
├── roles/kubectl/eck-llm-mcp/
│   ├── defaults/main.yml      # ← 所有可調變數都在這
│   ├── tasks/                 # 依序：node_prep → prereqs → model_staging
│   │                          #        → secrets → es_security → 三個 Deployment → webui_info
│   ├── handlers/main.yml
│   └── templates/             # 4 份 k8s manifest（namespace/PV、ollama、es-mcp、open-webui）
└── site.yml
```

---

## Air-gap 前置作業（跑 playbook 之前，在「有網路」的環境先做）

以下項目**不在本 playbook 範圍**，需要你自己完成、帶進離線環境：

1. **三個容器映像**已 `pull` 並 retag 推入內部 registry，且與 `defaults/main.yml` 的
   `ollama_image` / `open_webui_image` / `es_mcp_image` **完全一致**（路徑、tag 都要對上，
   否則 apply 後會 `ImagePullBackOff`）：
   - `ollama/ollama:0.32.9`
   - `open-webui/open-webui:v0.11.0`
   - `mcp/elasticsearch:0.4.6`（官方 image 是 `docker.elastic.co/mcp/elasticsearch`）
2. **模型 blob** 已用 Ollama 在連網環境 `ollama pull` 後打包，並放到目標主機
   `LLM_MCP/models/.ollama_staging/`（目錄底下要直接是 `blobs/` 與 `manifests/` 兩個資料夾，
   這就是 Ollama 的 `~/.ollama/models` 內容本身，不要外面再包一層）：
   - `nomic-embed-text:latest`
   - 主力模型（預設 `qwen3.6:35b`，實際 tag 對到 `defaults/main.yml` 的
     `ollama_primary_model_name` / `ollama_primary_model_tag`）
3. 若內部 registry 是 **HTTP（非 HTTPS）**，目標節點的 containerd/docker 要先設定
   insecure registry 才拉得動 image——這是叢集層級設定，本 playbook 不處理。
4. ECK 叢集本身（namespace、ES、Kibana、ES VIP）已依《ECK 部署規劃書》建好，且已知：
   - elastic 超級使用者的 k8s Secret 名稱與所在 namespace
   - 可以從 `k8s-controller01` 這台主機連到的 ES VIP / 可解析位址

---

## 使用方式

### 1. 改連線資訊

`inventory/hosts`：

```ini
[k8s_controller]
k8s-controller01 ansible_host=<實際 IP 或 hostname> ansible_user=<實際 SSH 使用者>
```

### 2. 改必調變數

打開 `roles/kubectl/eck-llm-mcp/defaults/main.yml`，至少確認/修改下方「環境不同一定要調整的變數」章節列出的項目。

### 3. 先跑 syntax check / check mode

```bash
cd eck-llm-mcp-playbook   # 若已在此目錄可略過
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --skip-tags es_security --check --diff
```

### 4. 正式部署（分兩段跑，避免 ES VIP 還沒填就整段失敗）

```bash
# 第一段：namespace/PV、模型匯入、Secret、Ollama、es-mcp、Open WebUI
ansible-playbook site.yml --skip-tags es_security

# 確認 es_public_url 等 ES 相關變數已填好之後，單獨跑 ES 唯讀帳號建立
ansible-playbook site.yml --tags es_security
```

`es_security` 這段獨立成 tag，是因為它要打真正的 ES REST API（走 `es_public_url`，通常是
MetalLB VIP），跟叢集內部部署（走 kubectl）是兩條不同的網路路徑，其中一個沒打通不該卡住另一個。

### 5. 部署後的手動步驟（規劃書 §5.2，不在本 playbook 自動化範圍內）

Open WebUI 目前是 `ENABLE_SIGNUP=true`：

1. 瀏覽器開 `http://<Open WebUI VIP>`（跑完 playbook 會在最後印出來，或用
   `kubectl -n ai get svc open-webui` 查）→ 註冊 → 第一個帳號即 admin。
2. Admin → Users 建立其他使用者帳號。
3. 把 `defaults/main.yml` 的 `webui_enable_signup` 改成 `"false"`，重跑一次
   `ansible-playbook site.yml --skip-tags es_security`（或手動
   `kubectl -n ai rollout restart deploy/open-webui`）關閉開放註冊。

### 重跑是安全的

整支 playbook 設計成 idempotent：namespace/PV/Deployment 用 `kubectl apply`（不變時顯示
`ok`）；模型只在 PV 上偵測不到對應 manifest 時才 rsync；Secret 只在不存在時才產生，已存在則讀回
原值再拿去建 ES 帳號，密碼不會每次重跑就換掉。可以放心重跑排除設定錯誤。

---

## 環境不同時，很可能要調整的變數

都在 `roles/kubectl/eck-llm-mcp/defaults/main.yml`，可依需要覆寫到
`inventory/group_vars/all.yml`（優先權更高）而不改 role 本身。

| 變數 | 預設值 | 什麼情況要改 |
|---|---|---|
| `kubectl_kubeconfig` | `/etc/kubernetes/admin.conf` | 目標主機的 kubeconfig 不在 kubeadm 預設路徑（例如 k3s 是 `/etc/rancher/k3s/k3s.yaml`、非 root 使用者的 `~/.kube/config`）。**所有 kubectl 呼叫都用 `become: true` 以 root 執行**，路徑錯會直接連不上叢集。 |
| `ai_node_name` | `k8s-controller01` | 要排到的節點名稱與實際 `kubectl get nodes` 顯示的不同。 |
| `ollama_pv_path` / `openwebui_pv_path` | `/var/lib/ai/ollama`、`/var/lib/ai/openwebui` | 目標主機該路徑已被佔用，或想放到別顆硬碟/掛載點（例如另外掛的大容量 RAID）。 |
| `ollama_pv_capacity` / `openwebui_pv_capacity` | `60Gi` / `10Gi` | 模型組合變多（例如再加 `qwen3-coder:30b` 備援）需要更大容量。**注意：PV/PVC 容量在建立後是不可變欄位，容量要改必須先刪掉重建，不能單靠重跑 playbook 生效。** |
| `llm_mcp_base_dir` | `/home/user/eck-llm-mcp/LLM_MCP` | 目標主機上 `LLM_MCP/` 實際擺放的路徑不同。 |
| `ollama_primary_model_name` / `ollama_primary_model_tag` | `qwen3.6` / `35b` | 换主力模型或量化版本（例如規劃書提到工具呼叫不穩時切 `qwen3-coder:30b`）——這是唯一為此目的特別拉出來的變數，改這裡就好，不用動 task 邏輯。 |
| `ollama_embed_model_name` / `ollama_embed_model_tag` | `nomic-embed-text` / `latest` | 換嵌入模型。 |
| `ollama_image` / `open_webui_image` / `es_mcp_image` | `registry.internal:5000/...` | 內部 registry 位址、命名空間或實際 retag 路徑跟預設不同——**這是最容易被忽略、也最容易直接導致 ImagePullBackOff 的一組變數**，務必對照你實際 push 上去的結果逐一核對。 |
| `ollama_resources_*` / `open_webui_resources_*` / `es_mcp_resources_*` | 依規劃書 §4.1/§5.1/§6.2 估算值 | controller 記憶體/CPU 規格跟規劃書預設的 256GB 不同，或量測後發現實際佔用跟估算差很多（`ollama ps` 校正）。 |
| `ollama_keep_alive` / `ollama_num_parallel` | `24h` / `2` | 想讓模型用完就卸載（改小 `OLLAMA_KEEP_ALIVE`），或要調整同時併發的請求數（會連動 KV cache 記憶體用量）。 |
| `webui_enable_signup` | `"true"` | 完成 §5.2 兩階段 bootstrap、建完所有使用者帳號後，改成 `"false"` 關閉開放註冊。 |
| `open_webui_service_type` | `LoadBalancer` | 叢集沒有 MetalLB / 沒有可用的 LB IP pool，需改成 `NodePort` 或 `ClusterIP` + 自行處理對外存取。 |
| `es_mcp_es_url` | `https://prod-es-http.elastic-stack.svc:9200` | 這是 **叢集內部**（pod 網路）DNS，ECK 的 Elasticsearch 資源名稱、Service 名稱或 namespace 跟規劃書預設不同時要改。 |
| `es_admin_secret_name` / `es_admin_secret_namespace` / `es_admin_secret_key` | `prod-es-elastic-user` / `elastic-stack` / `elastic` | **目前是推測值**，需對照實際 ECK 部署核對（ECK 預設命名規則是 `<Elasticsearch 資源名>-es-elastic-user`）。 |
| `es_public_url` | `https://CHANGEME-es-vip:9200`（佔位值，必改） | 這是 `k8s-controller01` **主機本身**（非 pod 網路）用來打 ES REST API 建立唯讀帳號的位址，通常是 ES 的 MetalLB LoadBalancer VIP。沒改就跑 `--tags es_security` 一定會在 preflight 失敗（訊息會提示你）。 |
| `mcp_role_name` / `mcp_user_name` | `mcp_readonly` / `mcp_user` | ES 上已有同名角色/帳號、想沿用別的命名慣例時才需要改。 |

---

## 已知限制 / 不在本 playbook 範圍

- Open WebUI 首位 admin 帳號建立、其餘使用者帳號建立、知識庫（index `.md`）上傳與嵌入——維持規劃書 §5.2 / §7.2 的手動步驟。
- 規劃書 §9 各項任務的功能驗證（深度查詢、Geofence、topology 等）不會被本 playbook 自動測試，需依規劃書手動驗證。
- PV/PVC 容量調整、image insecure-registry 設定屬叢集/節點層級設定，不在本 playbook 處理範圍。
