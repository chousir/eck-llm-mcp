# eck-llm-mcp

在既有 ECK（Elastic on Kubernetes）叢集上，額外部署一層「自然語言深度查詢」能力：
**Ollama（LLM 推論）+ Elasticsearch MCP Server（把 ES 包成工具）+ Open WebUI（多人前端 / MCP client）**。

- 架構與設計理由：[`ECK深度查詢擴充規劃書_LLM_MCP.md`](./ECK深度查詢擴充規劃書_LLM_MCP.md)
- 部署工具：[`eck-llm-mcp-playbook/`](./eck-llm-mcp-playbook)，一支 Ansible playbook

**目標：在 air-gapped 環境裝好 ECK 後，只跑一次 `ansible-playbook site.yml`，就得到已接通的
「Open WebUI ↔ Ollama ↔ es-mcp ↔ Elasticsearch」，並自動驗證。** 下面指令都假設已 `cd eck-llm-mcp-playbook`。

playbook 只負責「把備妥的映像 / 模型組成叢集資源」，不做映像 pull/push 與模型下載——
那些要先在有網路的機器做好（見〈離線準備〉）。

---

## 1. 環境需求

| 項目 | 需求 |
|---|---|
| Ansible 控制端 | ansible-core ≥ 2.14，不需額外 collection。也可直接在 AI 節點上跑：`inventory/hosts` 設 `ansible_connection=local`。 |
| 目標主機 | **必須就是 AI 節點**（`ai_node_name` 那台，預設 `k8s-controller01`）：模型與本地 PV 目錄都寫在這台，preflight 會檢查。需要 python3、sudo（root）、kubectl 與可讀的 kubeconfig；磁碟至少 ollama PV 容量（預設 60Gi）+ 模型 tar。 |
| CPU | Ollama CPU 推論需要 AVX2；記憶體依規劃書（預設 Ollama limit 48Gi）。 |
| Kubernetes | 目標主機連得到 ClusterIP（kube-proxy）；對外用 MetalLB，沒有的話設 `open_webui_service_type: NodePort`；`ai` namespace 的 Pod Security 不可為 `restricted`（Ollama / Open WebUI 以 root 跑，預設設為 `baseline`）。 |
| ECK | Elasticsearch 已 Ready 且啟用 security（Basic 授權即可）。 |
| Registry | 內部 registry 若是 HTTP，需先在各節點 containerd 設 insecure registry（叢集層級設定，不在本 playbook）；需要帳密時建立 docker-registry Secret 並填 `image_pull_secrets`。 |

---

## 2. 離線準備（在有網路的機器）

### 2.1 映像

三個映像 retag 後推入內部 registry，路徑與 tag 要和 `ollama_image` / `open_webui_image` / `es_mcp_image` **逐字一致**：

```bash
# 用 --override-arch amd64：在 Apple Silicon / ARM 機器上 pull 會拿到 arm64，目標機會出現 exec format error
skopeo copy --override-arch amd64 --override-os linux --dest-tls-verify=false \
  docker://docker.io/ollama/ollama:0.32.9            docker://registry.internal:5000/ollama/ollama:0.32.9
skopeo copy --override-arch amd64 --override-os linux --dest-tls-verify=false \
  docker://ghcr.io/open-webui/open-webui:v0.11.0     docker://registry.internal:5000/open-webui/open-webui:v0.11.0
skopeo copy --override-arch amd64 --override-os linux --dest-tls-verify=false \
  docker://docker.elastic.co/mcp/elasticsearch:0.4.6 docker://registry.internal:5000/mcp/elasticsearch:0.4.6
```

（完全離線、無法直連內部 registry 時，用 `skopeo copy ... docker-archive:xxx.tar` 帶進去再 push。）

### 2.2 模型

用**與正式環境同版本的 Ollama 容器**pull，目錄位置才確定：

```bash
mkdir -p ollama-data
docker run -d --name ollama-pull -v $PWD/ollama-data:/root/.ollama ollama/ollama:0.32.9
docker exec ollama-pull ollama pull qwen3.6:35b
docker exec ollama-pull ollama pull nomic-embed-text
docker rm -f ollama-pull
tar cf ollama-models.tar -C ollama-data models        # blob 已壓縮，不必 gzip
sha256sum ollama-models.tar > ollama-models.tar.sha256
```

帶入離線環境、比對 sha256 後，放到目標主機 `ollama_models_src`（預設 `/opt/eck-llm-mcp/ollama-models.tar`）。
`ollama_models_src` 也可以是已解開的目錄（底下是 `blobs/` 與 `manifests/`，或多一層 `models/`），playbook 自動判斷。

---

## 3. 使用方式

```bash
# 1) 改連線資訊：inventory/hosts（ansible_host、ansible_user）
# 2) 核對參數（第 4 節），寫到 inventory/group_vars/all.yml，不要直接改 role 的 defaults
# 3) 一次部署（含驗證）
ansible-playbook site.yml
```

部署結束會印出 Open WebUI 位址、admin 帳號，以及取回 admin 密碼的指令。

| tag | 內容 |
|---|---|
| `prereqs` | 節點標籤、PV 目錄、namespace / PV / PVC |
| `models` | 匯入 Ollama 模型並檢查 blob 完整性 |
| `es_security` | 建立 ES 唯讀角色與 `mcp_user` |
| `deploy` | 全部 k8s 資源（含 prereqs、es_security） |
| `verify` | 連線驗證：Ollama 模型、tool_calls、es-mcp 工具、`mcp_user` 權限、Open WebUI 已註冊 es-mcp |

`preflight` 與 `secrets` 永遠會跑（`always`），所以任何 tag 組合都可以用。**第一次部署請不要加 `--tags`。**

**重跑是安全的**：資源用 `kubectl apply`；模型只在缺少時才匯入；Secret 先讀後產生，密碼不會因重跑而更換。
注意 `--check` 對本 role 沒有意義（大量 `command` 在 check mode 會被跳過），請用 `--syntax-check` 與實跑。

### 部署後剩下的手動步驟

1. 用 admin 登入 Open WebUI，**Admin → Users** 建立其他使用者（開放註冊已自動關閉）。
2. 使用者在對話輸入框的 **Tools** 勾選 `Elasticsearch` 才會使用 MCP 工具。
3. 知識庫（各 index 的語意說明 `.md`）上傳與嵌入、System Prompt 範本：規劃書 §7.2、§7.5。
4. 規劃書 §9 各項任務（深度查詢、Geofence、topology…）的功能驗證。

---

## 4. 參數說明

全部在 `roles/kubectl/eck-llm-mcp/defaults/main.yml`（分「必須核對 / 通常要看 / 調校」三區，檔內有註解）。
覆寫請寫到 `inventory/group_vars/all.yml`（優先權較高）。

### 必須核對

| 變數 | 預設 | 怎麼查正確值 |
|---|---|---|
| `ollama_image` `open_webui_image` `es_mcp_image` | `registry.internal:5000/...` | 對照你實際 push 的結果；`curl -s http://<registry>/v2/_catalog`。不一致會 `ImagePullBackOff`。 |
| `ollama_models_src` | `/opt/eck-llm-mcp/ollama-models.tar` | 目標主機上 tar 或目錄的實際路徑。 |
| `ai_node_name` | `k8s-controller01` | `kubectl get nodes`（NAME 欄）；必須是 ansible 目標主機那台。 |

### 通常要看一下

| 變數 | 預設 | 說明 / 怎麼查 |
|---|---|---|
| `kubectl_bin` | `kubectl` | RHEL 系 sudo 的 secure_path 不含 `/usr/local/bin`；`command -v kubectl` 後填絕對路徑。 |
| `kubectl_kubeconfig` | `/etc/kubernetes/admin.conf` | k3s `/etc/rancher/k3s/k3s.yaml`、rke2 `/etc/rancher/rke2/rke2.yaml`。 |
| `eck_es_name` `eck_namespace` | 空＝自動偵測 | 叢集內只有一個 Elasticsearch 時自動採用；多個時 preflight 會列出清單。`kubectl get elasticsearch -A`。 |
| `es_mcp_es_url` `es_api_url` `es_admin_secret_name` | 空＝依 ECK 命名慣例推導 | 推導：`<name>-es-http.<ns>.svc:9200`、`<name>-es-http` 的 ClusterIP、`<name>-es-elastic-user`。ClusterIP 從主機不可達時，把 `es_api_url` 設成 ES 的 LB VIP / NodePort。 |
| `open_webui_service_type` | `LoadBalancer` | 沒有 MetalLB 改 `NodePort`；指定 VIP 用 `open_webui_service_annotations`，例如 `{metallb.universe.tf/loadBalancerIPs: "10.0.0.50"}`。 |
| `webui_admin_email` `webui_admin_password` | `admin@example.local`、空＝自動產生 | 只在 Open WebUI「第一次啟動、尚無使用者」時生效，之後請在 UI 改密碼。 |
| `image_pull_secrets` | `[]` | registry 需帳密（Harbor 等）：在 `ai` namespace 先建 docker-registry Secret，填名稱。 |
| `ai_tolerations` | control-plane 與 master 都容忍 | AI 節點若有其他 taint：`kubectl describe node <node> \| grep Taints`。 |
| `ollama_pv_path` `openwebui_pv_path` `ollama_pv_capacity` `openwebui_pv_capacity` | `/var/lib/ai/...`、`60Gi`、`10Gi` | **PV/PVC 容量建立後不可變更，要改須先刪除重建。** |
| `ollama_models` | qwen3.6:35b + nomic-embed-text | 第一個是主力模型。啟用備援 `qwen3-coder:30b` 時取消註解，並視情況把 `ollama_max_loaded_models` 調 3、加大記憶體 limit。 |
| `mcp_index_patterns` | `["*"]` | 建議收斂成實際要查的 pattern，例如 `["netflow-*"]`。es-mcp 的 `/mcp` 無認證，這是主要的權限邊界。 |
| `enable_network_policy` | `false` | `true` 時只允許 open-webui 連 es-mcp / ollama（CNI 需支援 NetworkPolicy）。 |

### 調校

| 變數 | 預設 | 說明 |
|---|---|---|
| `ollama_context_length` | `32768` | 太小會把 system prompt / 工具定義截掉，模型就不呼叫工具；調大會增加 KV cache 記憶體（× `ollama_num_parallel`）。 |
| `ollama_num_parallel` `ollama_max_loaded_models` `ollama_keep_alive` | `2` `2` `24h` | 併發與常駐模型數。 |
| `*_resources_*` | 依規劃書估算 | 用 `kubectl -n ai exec deploy/ollama -- ollama ps` 量測後校正。不建議對 Ollama 設 CPU limit（被限流會極慢）。 |
| `verify_tool_calls` `verify_tool_calls_timeout` | `true`、`900` | CPU 首次載入 35B 需數分鐘；不想等可設 `false`。 |
| `rollout_timeout` | `600s` | 各 Deployment 等待就緒的上限；逾時會印出 pod events 與 log。 |

---

## 5. 取捨與已知限制

- es-mcp 的 `/mcp` 沒有認證；`ES_SSL_SKIP_VERIFY=true`（ECK 自簽憑證）；Open WebUI 走 HTTP:80。內網可接受，但請用 `mcp_index_patterns` 收斂權限，必要時開 `enable_network_policy`。
- `TOOL_SERVER_CONNECTIONS`、admin 帳號都是「首次啟動寫入 Open WebUI DB」：之後若要改 MCP 連線，到 Admin → Settings → Integrations 改，或清空 `openwebui` PV 後重跑。
- Open WebUI 知識庫索引存在 `openwebui-data` 卷，不在 ES；搬到新環境要重新上傳嵌入。
- 本 playbook 不處理：映像 / 模型下載、insecure-registry 設定、PV 容量調整、規劃書 §9 的功能任務驗證。

---

## 6. 疑難排解

| 症狀 | 原因 / 處理 |
|---|---|
| preflight：`無法以 root 執行 kubectl` | 設 `kubectl_bin` 絕對路徑、確認 `kubectl_kubeconfig`。 |
| preflight：`找不到節點` / `目標主機必須就是節點` | `ai_node_name` 對照 `kubectl get nodes`；inventory 的 `ansible_host` 必須是該節點。 |
| preflight：`必須恰好對到一個 Elasticsearch` | 設 `eck_es_name` 與 `eck_namespace`。 |
| rollout 逾時，events 顯示 `ImagePullBackOff` | 映像路徑 / tag 與 registry 不一致、insecure registry 未設、需 `image_pull_secrets`。`exec format error` = 映像架構不對（用 `--override-arch amd64`）。 |
| Pod `Pending` | `kubectl -n ai describe pod`：node label / taint（`ai_tolerations`）、記憶體不足、PVC 未 Bound。 |
| `PVC 未全部 Bound` | PV 容量與 PVC 不一致（不可變，須刪除重建）。刪過 `ai` namespace 的舊 PV 會自動解除綁定。 |
| `blob 缺漏或大小不符` | 模型搬運不完整，重新帶入並比對 sha256。 |
| ES 連不到（es_security） | 目標主機打不到 ClusterIP：設 `es_api_url`（LB VIP / NodePort）。 |
| 模型不呼叫工具 | `ollama_context_length` 太小；Function Calling 需為 `Native`；`verify` 第 2 項可確認模型本身的 tool_calls。 |
| `invalid type: string, expected a map` | Native function calling 把 `query_body` 序列化成字串（見規劃書 §6）；換 prompt 或模型參數。 |
| `list_indices` 403 | `mcp_readonly` 角色需含 `monitor` 權限；確認 `mcp_index_patterns` 涵蓋要查的 index。 |
| 一般使用者看不到 Elasticsearch 工具 | 對話輸入框要勾選 Tools；若 Open WebUI DB 內已有舊連線設定，env 不會覆蓋（見第 5 節）。 |
| Open WebUI 下拉選單很慢 | 離線時等 OpenAI 逾時；本 playbook 已設 `ENABLE_OPENAI_API=false`、`OFFLINE_MODE=true`。 |
