# ECK 深度查詢擴充規劃書:LLM + MCP

> 定位:《ECK 部署規劃書》的**後續功能擴充**,在既有 ECK 叢集(6 node × 5 pod、Kibana、GeoIP、tileserver 已就緒)之上,建立「自然語言深度查詢」能力層。全部採**免費開源**元件。
> 目標環境:與 ECK 相同的 **air-gapped 離線環境**;所有映像、模型權重須**先在有網路環境下載保全**再帶入。
> 執行位置:LLM 能力層跑在 **k8s-controller**(256GB RAM、閒置資源多);模型現階段用 **CPU 推論**,未來可無痛遷移到 GPU 伺服器。
> 設計原則:**可重構**——元件容器化、設定檔化,映像/模型皆打 tag 版本控管,便於離線搬遷與重建。
> **範圍**:本版為 LLM + MCP + Open WebUI 主線,**排程/自動化(n8n)不在本版**,待主線在正式叢集穩定後另行規劃。

---

## 0. 這份規劃書要建立什麼(能力總覽)

| 能力 | 元件 | 對應章節 |
|---|---|---|
| 多人網頁介面,自然語言問 ES | Open WebUI | §5 |
| LLM 推論(模型可換、CPU→GPU 無痛) | Ollama | §4 |
| 把 ES/Kibana REST 包成 LLM 可呼叫的工具 | Elasticsearch MCP Server(+自建工具) | §6 |
| 深度查詢正確性工程(schema 文件、few-shot、RAG、自我修正) | 方法 + 範本 | §7 |
| 各類 ECK 任務(查詢/Geofence/topology/dashboard/分析) | 上述組合 | §9(每項含範例驗證) |
| 安全與正確性最佳實務 | 唯讀權限、驗證迴圈、agentic 流程 | §7 / §10 |

**與 ECK 規劃書的關係**:《ECK 部署規劃書》§14「後續擴充」已指向本文件。本文件所有對 ES 的存取,皆透過 ECK 規劃書已建立的 ES VIP(`prod-es-http` LoadBalancer)與唯讀帳號進行。

---

## 1. 架構總覽

**MCP client 是 Open WebUI,不是 Ollama。** Ollama 不懂 MCP 協定,只提供 OpenAI 相容的 tool-calling API——輸入 tools schema,輸出「要呼叫哪個工具、帶什麼參數」的結構化 JSON。呼叫 MCP server、把結果餵回 LLM、決定下一步的 **MCP client** 是 **Open WebUI**(v0.6.31+ 原生支援 Streamable HTTP MCP,§5.3)。

```
   多人使用者(瀏覽器)
        │
        ▼
 ┌──────────────────┐
 │   Open WebUI      │  多人帳號/RBAC
 │   (§5)            │  MCP client(原生)
 └───┬────────────┬───┘
     │ OpenAI 相容 │ Streamable-HTTP
     │ API(對話)  │ (呼叫工具/取結果)
     ▼            ▼
┌──────────┐  ┌──────────────────────────┐
│ Ollama   │  │  Elasticsearch MCP (§6)  │  list_indices / get_mappings /
│ (§4)     │  │  + 自建工具(dashboard、  │  search / esql / get_shards ...
│qwen3.6   │  │    topology)             │
│ :35b     │  └────────┬─────────────────┘
│純推論    │           │  唯讀帳號(§10 安全)
└──────────┘           ▼
                 ┌──────────────────┐
                 │  ECK 叢集         │  ES VIP(prod-es-http)+ Kibana
                 │  (既有)          │
                 └──────────────────┘
                知識庫(index 說明 .md → RAG,§7)存於 Open WebUI 內建向量庫
```

**部署位置**:Open WebUI、Ollama、MCP Server 以容器部署於 **k8s-controller**(比照 ECK 規劃書 Kibana/tileserver 的做法:toleration + nodeSelector 排到 controller),各自一個 Namespace(建議 `ai`)。

**MCP Server 選型**:`elastic/mcp-server-elasticsearch` 已標 deprecated(僅收資安更新),官方建議改用 Kibana Agent Builder MCP endpoint;但該功能在 self-managed 叢集需 Enterprise 授權,本叢集為免費 Basic(《ECK 部署規劃書》§1),故採獨立 MCP container、定版 `0.4.6`。未來若升 Enterprise 授權可改接 Agent Builder MCP,其餘架構(Open WebUI/Ollama)不變。

---

## 2. ⭐ 先期安裝清單(離線前必做,最重要)

**在有網路的環境**備妥下列所有項目,retag 推入內部 registry / 下載到介質,帶入 air-gapped。**模型權重是最大宗、最易漏**。

### 2.1 容器映像(推入內部 registry `registry.internal:5000`)

```
ollama/ollama:0.32.9                        # LLM 推論;需 ≥0.32 以支援目前模型的 tool-calling 模板
ghcr.io/open-webui/open-webui:v0.11.0       # 多人前端 + MCP client;需 ≥v0.6.31 才有原生 MCP(Streamable HTTP)
docker.elastic.co/mcp/elasticsearch:0.4.6   # Elasticsearch MCP,定版不用 latest(見 §1、§6)
```

> 版本務必**固定 tag 並記錄**,不要用浮動 `latest`。以 `docker pull` + `skopeo copy` 推入內部 registry。實際 digest 記於 `LLM_MCP/manifests/VERSIONS.md`。

### 2.2 模型權重(GGUF 量化,最大宗,務必先下載)

用 Ollama 在有網路環境先 `pull`,再把模型 blob 打包帶走(見 §4.3 離線搬遷):

```
qwen3.6:35b        # 主力,Qwen3.6-35B-A3B(MoE,35B 總 / 3B 啟動);~22.6GB(含 ~0.9GB 視覺 projector,文字查詢用不到但一併下載)
qwen3-coder:30b    # 備援,Qwen3-Coder-30B-A3B(MoE,~3B 啟動,以上游 model card 為準);工具呼叫格式久經社群驗證 ~18.5GB
nomic-embed-text   # 嵌入模型(RAG 用,§7)~275MB
```

> **模型權重不在容器映像裡**,是 Ollama 另外下載的 blob。離線搬遷見 §4.3——這是整個部署最容易漏、且檔案最大的部分。
> 務必依 §4.2 實測 `qwen3.6:35b` 的 tool_calls 格式能否被 Open WebUI 正確解析;若不穩定,直接切 `qwen3-coder:30b`(不改架構,只換 Ollama 拉的 tag)。
> 已評估但不採用 `qwen3.8:27b`(dense 27B、CPU 逐 token 成本約本 MoE 的 9×);完整理由見 §4.4。

### 2.4 儲存規劃(k8s-controller 上)

| 用途 | 容量 | 放哪 |
|---|---|---|
| Ollama 模型 blob | qwen3.6:35b(~23.5GB)+ qwen3-coder:30b(~18GB)+ nomic-embed-text(~0.3GB)+ 換版緩衝(~18GB)≈ **60GB** | controller 本地 PV(RAID5) |
| Open WebUI 資料(帳號、對話、MCP 連線設定、**知識庫向量索引**) | ~10GB | controller 本地 PV |

> §3 的 PV 範本容量(`60Gi`)即依上表 Ollama 那列。controller 為 5×3.85TB SSD RAID5(~15.4TB),空間充裕。
> 這些 PV 用本地 local PV(比照 ECK 規劃書 master PV 手動建立方式,釘在跑該服務的 controller)。

### 2.5 先期安裝檢查清單

- [ ] §2.1 全部映像已推入內部 registry,tag 已固定並記錄(ollama 0.32.9 / open-webui v0.11.0 / mcp 0.4.6)。
- [ ] §2.2 全部模型已 `ollama pull`,blob 已打包(§4.3):qwen3.6:35b、qwen3-coder:30b、nomic-embed-text。
- [ ] §4.2 已驗證 `qwen3.6:35b` 的 tool_calls 輸出格式正確,否則已記錄改用 `qwen3-coder:30b`。
- [ ] §2.6 其他帶入項備妥(index `.md`、`mcp_user` 建立指令、`WEBUI_SECRET_KEY`)。
- [ ] controller 本地 PV 已規劃(Ollama 模型 60Gi、Open WebUI 資料 10Gi)。
- [ ] 記錄所有版本號於 `LLM_MCP/manifests/VERSIONS.md`(含映像 digest)與本規劃書附錄。

### 2.6 其他帶入項(非映像 / 非模型,易漏)

| 項目 | 說明 |
|---|---|
| 各 index 語意說明 `.md` | 每個 index 一份(§7.1),納入版控隨規劃書搬遷。範例:`LLM_MCP/schema-docs/`。 |
| Open WebUI 知識庫 | index `.md` 上傳後索引存於 `openwebui-data` 卷(內建向量庫,**不在 ES**),不隨 ES 快照走;帶入後需在目標端重新上傳 / 重新嵌入(§7.2)。 |
| `mcp_readonly` 角色 + `mcp_user` 帳號 | 建立指令見 §6.2,須在目標 ES 執行。 |
| `WEBUI_SECRET_KEY` 固定值 | 一次產生後固定保存(§5.1)。 |

---

## 3. 通用前置(Namespace、controller 排程、本地 PV)

所有 AI 元件放 `ai` namespace,排到 controller。

```bash
kubectl create namespace ai
# 給 controller 貼一個好選的 label(若尚未有)
kubectl label node k8s-controller01 ai-workload=true --overwrite
```

**共用排程片段**(每個 Deployment 都套):

```yaml
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, effect: NoSchedule }
      nodeSelector:
        ai-workload: "true"          # 釘到指定 controller(本地 PV 也在那台)
```

**本地 PV 範本**(比照 ECK 規劃書手動 PV;每個服務一個,`path` 換該服務目錄):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata: { name: ollama-models }
spec:
  capacity: { storage: 60Gi }
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local: { path: /var/lib/ai/ollama }
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: kubernetes.io/hostname, operator: In, values: ["k8s-controller01"] }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: ollama-models, namespace: ai }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ""
  volumeName: ollama-models
  resources: { requests: { storage: 60Gi } }
```

> 容量依 §2.4:`ollama-models` 用 60Gi。另建 `openwebui-data` 同結構 PV/PVC(`path` `/var/lib/ai/openwebui`,~10Gi;含知識庫向量索引)。在 controller01 上先 `mkdir -p /var/lib/ai/{ollama,openwebui}`。

---

## 4. Ollama(模型推論服務)

### 4.1 部署

`ollama.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: ollama, namespace: ai }
spec:
  replicas: 1
  selector: { matchLabels: { app: ollama } }
  template:
    metadata: { labels: { app: ollama } }
    spec:
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, effect: NoSchedule }
      nodeSelector: { ai-workload: "true" }
      containers:
        - name: ollama
          image: registry.internal:5000/ollama/ollama:0.32.9
          ports: [ { containerPort: 11434 } ]
          env:
            - { name: OLLAMA_HOST, value: "0.0.0.0" }
            - { name: OLLAMA_KEEP_ALIVE, value: "24h" }   # 模型常駐,避免每次重載
            - { name: OLLAMA_NUM_PARALLEL, value: "2" }   # KV cache 隨此值放大
            # - { name: OLLAMA_MAX_LOADED_MODELS, value: "1" }  # 見下方「三顆模型併存」說明
          resources:
            # 記憶體 ≈ 全專家權重常駐(~21.7GB Q4)+ projector(~0.9GB)+ KV cache(依 context × NUM_PARALLEL,約 4–6GB)+ 執行期緩衝(~2GB) ≈ ~30GB 工作集
            requests: { memory: "32Gi", cpu: "8" }
            limits:   { memory: "48Gi" }                   # controller 256GB,可再放寬;首次載入後用 `ollama ps` 實測校正
          volumeMounts: [ { name: models, mountPath: /root/.ollama } ]
      volumes:
        - name: models
          persistentVolumeClaim: { claimName: ollama-models }
---
apiVersion: v1
kind: Service
metadata: { name: ollama, namespace: ai }
spec:
  # 內部給 Open WebUI/MCP 用即可;需外部存取才改 LoadBalancer
  selector: { app: ollama }
  ports: [ { port: 11434, targetPort: 11434 } ]
```

```bash
kubectl apply -f ollama.yaml
kubectl -n ai get pods -l app=ollama -o wide     # 應在 controller01、Running
```

> **三顆模型併存**:主力(~24GB)+ 備援(~18GB)+ 嵌入(~0.3GB)blob 都在同一個 PV。Ollama 依請求動態載入 / 卸載,
> 記憶體足夠時可同時常駐多顆(受 `OLLAMA_MAX_LOADED_MODELS` 約束,預設會視可用記憶體決定)。
> controller 256GB 容得下,但若要避免尖峰同時載入,設 `OLLAMA_MAX_LOADED_MODELS=1` 強制單顆(換模型時多一次載入延遲)。

### 4.2 範例驗證(Ollama 本身可用)

```bash
kubectl -n ai exec deploy/ollama -- ollama list          # 應列出已載入模型
kubectl -n ai exec deploy/ollama -- \
  ollama run qwen3.6:35b "用一句話說明什麼是 Elasticsearch shard"
# 期望:回傳合理中文答案。MoE 全專家權重常駐 RAM(~24GB),但每 token 僅 3B 啟動計算量;
#       CPU 下互動延遲仍以數秒~數十秒計,載入後用 `ollama ps` 看實際佔用。

# 工具呼叫格式驗證(接 Open WebUI 前務必先單獨測此鏈路)
# ollama 映像內無 curl/jq,從叢集外打:
kubectl -n ai port-forward deploy/ollama 11434:11434 &
curl -s http://localhost:11434/api/chat -d '{
  "model": "qwen3.6:35b",
  "messages": [{"role":"user","content":"台北現在天氣如何?"}],
  "tools": [{"type":"function","function":{"name":"get_weather","description":"查天氣","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
  "stream": false
}' | jq '.message.tool_calls'
# 期望:回傳 tool_calls 陣列,name 為 get_weather、arguments 含 city。
# 若是 null:模型/模板未正確觸發 tool-calling,檢查 Ollama 版本或改用 qwen3-coder:30b。
```

### 4.3 ⭐ 模型離線搬遷(關鍵)

模型 blob 不在映像裡。在有網路環境先 pull,再搬 blob:

```bash
# 有網路的機器(或臨時 Ollama,版本需與 §2.1 一致:0.32.9)
ollama pull qwen3.6:35b
ollama pull qwen3-coder:30b
ollama pull nomic-embed-text
# 模型存於 ~/.ollama/models(含 blobs/ 與 manifests/)
tar czf ollama-models.tgz -C ~/.ollama models
```

帶入離線環境後,解壓到 controller01 的 PV 目錄:

```bash
# 在 controller01
tar xzf ollama-models.tgz -C /var/lib/ai/ollama       # 對應 PV 的 /root/.ollama
kubectl -n ai rollout restart deploy/ollama
kubectl -n ai exec deploy/ollama -- ollama list        # 確認模型已在,無需連網
```

### 4.4 換模型 / 未來上 GPU

- **換模型**:blob 放進 PV → Open WebUI 下拉切換。無需改架構。若 `qwen3.6:35b` 工具呼叫不穩(§4.2 驗證失敗),直接切 `qwen3-coder:30b`。
- **不採用 `qwen3.8:27b`**:為 dense 27B(全參數啟動),CPU 逐 token 運算量約為本 MoE(3B 啟動)的 9×,不符「先 CPU 驗證、再投資 GPU」的前提。待 GPU 就緒後可再評估 dense 大模型。
- **上 GPU**:在 GPU 伺服器跑 Ollama(同映像 `ollama/ollama:0.32.9` + `--gpus all`),把 §2.2 模型 blob 複製到該機的 `~/.ollama/models`;
  然後把 Open WebUI 的 `OLLAMA_BASE_URL` 從 `http://ollama.ai.svc:11434` 改成 GPU 伺服器位址,`kubectl rollout restart deploy/open-webui`。**MCP / ES / 知識庫完全不動**(這是本架構刻意的解耦)。

---

## 5. Open WebUI(多人前端)

### 5.1 部署

`WEBUI_SECRET_KEY` 為必要項(非選配):沒有固定值,pod 重啟後既有的 MCP OAuth/Token 會解密失敗。先建 Secret:

```bash
kubectl -n ai create secret generic open-webui-secret \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
```

`open-webui.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: open-webui, namespace: ai }
spec:
  replicas: 1
  selector: { matchLabels: { app: open-webui } }
  template:
    metadata: { labels: { app: open-webui } }
    spec:
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, effect: NoSchedule }
      nodeSelector: { ai-workload: "true" }
      containers:
        - name: open-webui
          image: registry.internal:5000/open-webui/open-webui:v0.11.0
          ports: [ { containerPort: 8080 } ]
          env:
            - { name: OLLAMA_BASE_URL, value: "http://ollama.ai.svc:11434" }
            - { name: WEBUI_AUTH, value: "true" }          # 開啟多人帳號
            - { name: ENABLE_SIGNUP, value: "true" }        # 兩階段 bootstrap(§5.2):建完 admin 與使用者後改 "false" 再 rollout restart
            - { name: WEBUI_SECRET_KEY, valueFrom: { secretKeyRef: { name: open-webui-secret, key: WEBUI_SECRET_KEY } } }
            # RAG 嵌入走 Ollama + nomic-embed-text(§7.2)
            - { name: RAG_EMBEDDING_ENGINE, value: "ollama" }
            - { name: RAG_EMBEDDING_MODEL, value: "nomic-embed-text" }
            - { name: RAG_OLLAMA_BASE_URL, value: "http://ollama.ai.svc:11434" }
          resources:
            requests: { memory: "2Gi", cpu: "1" }
            limits:   { memory: "4Gi" }
          volumeMounts: [ { name: data, mountPath: /app/backend/data } ]
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: openwebui-data }
---
apiVersion: v1
kind: Service
metadata: { name: open-webui, namespace: ai }
spec:
  type: LoadBalancer                 # MetalLB VIP(從 pool 取一個)
  selector: { app: open-webui }
  ports: [ { port: 80, targetPort: 8080 } ]
```

```bash
kubectl apply -f open-webui.yaml
kubectl -n ai get svc open-webui -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
```

### 5.2 範例驗證(多人問答可用)

**兩階段 bootstrap**(`ENABLE_SIGNUP=false` 時無法建第一個 admin,故分兩步):

1. 以 `ENABLE_SIGNUP=true` 部署,瀏覽器開 `http://<Open-WebUI-VIP>` 註冊 → 第一個帳號即管理員。
2. 管理員在 **Admin → Users** 建立其餘使用者帳號(多人使用)。
3. **然後**把 Deployment 的 `ENABLE_SIGNUP` 改 `"false"`、`kubectl -n ai rollout restart deploy/open-webui`。
4. 對話框選模型 `qwen3.6:35b`,問「你好,請自我介紹」→ 應正常回覆。

**驗證通過標準**:多個帳號可各自登入、各自對話、切換模型;對話歷史持久(重啟 pod 後仍在,證明 PV 生效)。

### 5.3 接上 Elasticsearch MCP

Open WebUI 是這條主線裡實際的 **MCP client**(§1)。前提是 §6 的 `es-mcp` 已部署、用 `http` 模式、`/ping` 回 200(§6.3)。

1. **Admin Settings → Integrations**(External Tool Servers)→ 新增連線。
2. **Type** 選 `MCP (Streamable HTTP)`(不是 OpenAPI)。
3. **Server URL** 填 `http://es-mcp.ai.svc:8080/mcp`。
4. **Auth** 選 `None`(內網;ES 認證已在 §6.2 的 MCP container 端用唯讀帳號做好,這段不需再加一層)。
5. 儲存後確認 `list_indices` / `get_mappings` / `search` / `esql` / `get_shards` 五個工具出現。
6. 模型 `qwen3.6:35b` 的設定裡,把 **Function Calling 設為 `Native`**(Native 模式才會把 Ollama 回的 tool_calls 直接對應到 MCP 工具,而非 prompt-based 間接方式)。
7. 對話框把 MCP 工具掛到 `qwen3.6:35b` → 問「目前 ES 上有哪些 index?」→ 應觸發 `list_indices` 並回傳實際清單。

> 步驟 1 與 6 的實際 UI 路徑以 Open WebUI v0.11.0 為準,已於本地 Docker 驗證(§13)實測,見 `LLM_MCP/README.local-test.md`。

**驗證通過標準**:工具清單能看到 §6.1 的 5 個工具;對話能觸發正確工具呼叫並回傳真實 ES 資料;非管理員帳號能使用已掛好的工具,但不能自己新增/修改 MCP 連線(§10 安全)。

---

## 6. Elasticsearch MCP Server(把 ES 包成工具)

MCP(Model Context Protocol)Server 把 ES/Kibana 的 REST API 暴露成 LLM 能呼叫的「工具」。LLM 產生 function call → MCP 執行 → 回結果。

### 6.1 官方 Elasticsearch MCP 提供的工具(起步已足夠)

典型工具:`list_indices`(列 index)、`get_mappings`(看欄位)、`search`(查詢,支援完整 DSL)、`esql`(ES|QL 查詢)、`get_shards`(shard/topology)。**這些已涵蓋大部分「深度查詢」與「data topology」需求;Geofence 本質是 `search` 帶 geo query,直接涵蓋。**

> `search` 的 `query_body` 參數要求是 **JSON 物件**(不是 JSON 字串)。若 §5.3 step 6 的 Native function calling 把它序列化成字串,es-mcp 會回 `invalid type: string, expected a map`——本地測試(§13)已遇到,設定 Open WebUI 模型參數時留意。

### 6.2 部署(以容器化 MCP + 唯讀帳號)

先在 ES 建**唯讀角色與帳號**(§10 安全的核心),再讓 MCP 用它連線。

```bash
# ES 建唯讀角色(只能讀,不能寫/刪)
# ⚠️ ES 9.4.2:_cat/indices(list_indices 工具)需要 index 層級 monitor 權限,
#   光靠 cluster: ["monitor"] 會 403(本地測試實證);故 index privileges 要含 monitor。
curl -k -u "elastic:$PW" -XPUT "https://$ESIP:9200/_security/role/mcp_readonly" \
  -H 'Content-Type: application/json' -d '{
  "cluster": ["monitor"],
  "indices": [ { "names": ["*"], "privileges": ["read","view_index_metadata","monitor"] } ]
}'
# 建帳號綁該角色
curl -k -u "elastic:$PW" -XPUT "https://$ESIP:9200/_security/user/mcp_user" \
  -H 'Content-Type: application/json' -d '{
  "password": "<強密碼>", "roles": ["mcp_readonly"], "full_name": "MCP readonly"
}'
```

> **映像特性(已對 `0.4.6` 二進位實測)**:Chainguard wolfi-base 極簡映像,entrypoint `elasticsearch-core-mcp-server`,**容器內無 shell、無 curl**。
> `args: ["http"]` 是必要的子命令(另一個是 `stdio`);漏掉則容器只印 usage 後結束。
> 連線設定由內建預設 config 讀環境變數:`ES_URL`(必要)、`ES_USERNAME`+`ES_PASSWORD`(或 `ES_API_KEY`)、`ES_SSL_SKIP_VERIFY`。
> 映像已內建 `CONTAINER_MODE=true`(會把 `localhost` 改寫為 host 位址、調整綁定位址)。
> HTTP 端點(已對 `0.4.6` 實測):`/ping` → HTTP 200 + 純文字 `Ready`;`/mcp`(MCP streamable-HTTP);`/mcp/sse`(SSE);`/` 回端點清單。

`es-mcp.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: es-mcp, namespace: ai }
spec:
  replicas: 1
  selector: { matchLabels: { app: es-mcp } }
  template:
    metadata: { labels: { app: es-mcp } }
    spec:
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, effect: NoSchedule }
      nodeSelector: { ai-workload: "true" }
      containers:
        - name: es-mcp
          image: registry.internal:5000/mcp/elasticsearch:0.4.6
          args: ["http"]                          # ⭐必要:streamable-HTTP 子命令
          env:
            - { name: ES_URL, value: "https://prod-es-http.elastic-stack.svc:9200" }
            - { name: ES_USERNAME, value: "mcp_user" }
            - { name: ES_PASSWORD, valueFrom: { secretKeyRef: { name: es-mcp-cred, key: password } } }
            - { name: ES_SSL_SKIP_VERIFY, value: "true" }    # ECK 自簽,跳過驗證
            - { name: HTTP_ADDRESS, value: "0.0.0.0:8080" }  # 明確綁定,供 Service 轉發
          ports: [ { containerPort: 8080 } ]
          resources:
            requests: { memory: "256Mi", cpu: "200m" }
            limits:   { memory: "512Mi" }
---
apiVersion: v1
kind: Service
metadata: { name: es-mcp, namespace: ai }
spec:
  selector: { app: es-mcp }
  ports: [ { port: 8080, targetPort: 8080 } ]
```

```bash
kubectl -n ai create secret generic es-mcp-cred --from-literal=password='<強密碼>'
kubectl apply -f es-mcp.yaml
```

### 6.3 範例驗證(MCP 工具可用)

容器內無 shell/curl,健康檢查從 pod 外做:

```bash
kubectl -n ai port-forward deploy/es-mcp 8080:8080 &
curl -s http://localhost:8080/ping          # 期望 HTTP 200 + "Ready"
# MCP 端點在 /mcp(streamable-HTTP,非根路徑);最終以 §5.3 Open WebUI 能列出 5 個工具為準
# 本地驗證另有腳本:LLM_MCP/mcp-smoke.sh(打 /ping 與 /mcp 的 initialize + tools/list,斷言 5 工具)
```

**驗證通過標準**:透過 Open WebUI 呼叫 `list_indices` 能回傳 ES 上實際的 index 清單;呼叫 `search` / `esql` 能回傳真實查詢結果。這代表 LLM ↔ MCP ↔ ES 的鏈路打通。
(`get_mappings` 對含巢狀欄位的 index 會失敗,見 §7.3——不影響鏈路判定,靠靜態 `.md` 補。)

### 6.4 自建工具(擴充查詢以外的能力)

MCP 的價值是「任何 REST API 都能包成工具」。以下視需求自建(用輕量 MCP SDK 寫一個 custom MCP):

- **Dashboard / Data View**:包裝 Kibana Saved Objects API(建立/修改 data view、dashboard)。
- **Data topology**:包裝 `_cat/shards`、`_cat/nodes`、`_cluster/health`、`_nodes/stats`。
- **Geofence 專用工具**:包裝常用 geo_bounding_box/geo_polygon 查詢範本,讓 LLM 只需填座標。

> 起步先用官方 MCP(查詢/mapping/shard 已涵蓋 80% 需求);dashboard 等寫入型工具再按 §9 各任務逐步加。

---

## 7. ⭐ 深度查詢正確性工程(成敗關鍵)

LLM 查得準不準,取決於「你給它多少你資料的上下文」,而非模型大小。四個支柱:

### 7.1 每個 index 一份語意說明 `.md`(schema 文件)

**範本**(每個 index 一份,存版控 + 進 RAG 知識庫):

```markdown
# index: netflow-*

## 用途
網路流量記錄(NetFlow),每筆代表一條連線的統計。

## 欄位
| 欄位 | 型別 | 意義 | 範例值 |
|---|---|---|---|
| @timestamp | date | 連線時間 | 2026-07-20T10:00:00Z |
| src_ip | ip | 來源 IP | 192.168.1.10 |
| dst_ip | ip | 目的 IP | 8.8.8.8 |
| bytes | long | 傳輸位元組 | 15000 |
| geo.location | geo_point | 來源地理座標(GeoIP 產生) | {lat,lon} |
| geo.country_name | keyword | 來源國家 | Taiwan |

## 常見任務範例(自然語言 → ES DSL)
### 範例1:過去 1 小時來自某網段的前 10 大流量來源
使用者問:「過去一小時 10.0.0.0/24 網段流量最大的前 10 個來源 IP」
DSL:
{ "query": { "bool": { "filter": [
  { "range": { "@timestamp": { "gte": "now-1h" } } },
  { "term": { "src_ip": "10.0.0.0/24" } } ] } },
  "aggs": { "top_src": { "terms": { "field": "src_ip", "size": 10,
    "order": { "total_bytes": "desc" } },
    "aggs": { "total_bytes": { "sum": { "field": "bytes" } } } } },
  "size": 0 }

### 範例2:某地理範圍內的異常連線(Geofence)
...(5~10 組由淺入深)
```

> **few-shot 範例(自然語言 → 正確 DSL)對正確率提升最大**,每個 index 附 5~10 組。欄位說明讓 LLM 懂語意,範例讓 LLM 學會你的查法。

### 7.2 RAG:只餵「相關的」說明,不要全塞

index 一多,全部 .md 塞進 prompt 會爆 context 且稀釋注意力。用 RAG 檢索出「與問題最相關的 1~3 個 index 說明」再餵 LLM。

**主線(Open WebUI 內建知識庫)**:

1. 每個 index 的 `.md`(§7.1)上傳到 Open WebUI 的「知識庫(Knowledge)」集合。嵌入引擎在 §5.1 已設 Ollama + `nomic-embed-text`。
2. 把集合掛到模型,或對話中用 `#` 引用 → Open WebUI 自動檢索命中片段注入 prompt。
3. **好處**:零額外元件、context 精簡、index 可無限擴充。

**重要後果**:知識庫的向量索引存在 Open WebUI 自己的資料卷(`/app/backend/data` 的內建向量庫),**不在 ES**。因此:

- §2.6 已把 index `.md` 列為帶入項;
- air-gap 帶入後需在目標環境**重新上傳 / 重新嵌入**(或整個 `openwebui-data` PV 一起搬),不能只靠 ES 快照。

### 7.3 動態 mapping(MCP 工具)+ 靜態語意(.md)結合

- 靜態 .md 給「語意/業務意義/範例」(LLM 猜不到的)。
- 動態 `get_mappings`(MCP)給「即時、精確的欄位與型別」(避免 .md 過時)。
- 兩者結合:LLM 先讀你的語意說明,再用工具確認實際欄位,最準。

> ⚠️ **es-mcp 0.4.6 `get_mappings` 限制(本地測試實證)**:無法解析含「物件子欄位(`properties` 巢狀)」的 mapping,
> 會回 `error decoding response body`。ECS / Beats / GeoIP 產生的資料(如 `geo` 物件下的 `geo.location`)幾乎都是巢狀的 → 對這類 index `get_mappings` 會失敗。
> 扁平 mapping、`subobjects: false`、multi-field(`fields`)則正常。
> **緩解**:(a) 主要靠 §7.1 的靜態 `.md` 當欄位權威;(b) System Prompt 加一句「`get_mappings` 若失敗,改用 `search` 帶 `size:1` 取一筆樣本文件推斷欄位」;(c) 欄位名錯由 §7.4 自我修正迴圈兜住。升級到 Enterprise Agent Builder MCP(§1)或 es-mcp 後續修正版可重新驗證。

### 7.4 自我修正迴圈(reflection)

LLM 產生的 DSL 可能語法錯或查空。流程加一層:

```
產生 DSL → 執行 → 若 ES 回錯/查無 → 把錯誤訊息+原問題回饋 LLM → 修正 → 重試(最多 N 次)
```

目前依靠 Open WebUI 原生的 agentic tool loop——LLM 看到工具回傳的錯誤訊息會自行重新呼叫,受 Open WebUI 的工具呼叫輪數上限約束,不是自訂邏輯但夠用。**此迴圈對正確率提升巨大**。

### 7.5 System Prompt 範本(引導 agentic 行為)

```
你是 Elasticsearch 深度查詢助手。工作流程:
1. 先用 list_indices / 檢索知識庫,找出與問題相關的 index。
2. 用 get_mappings 確認欄位與型別,不要臆測欄位名。get_mappings 若報錯,改用 search 帶 "size":1 取一筆樣本文件推斷欄位。
3. 產生小範圍查詢先驗證,再擴大。
4. 若查詢報錯,讀錯誤訊息並修正後重試。
5. 只做唯讀查詢;不執行任何刪除/修改。
6. 回答時附上你用的查詢邏輯與依據的 index。
```

> `qwen3.6:35b` 預設思考模式(`<think>`)開啟,產查詢結構前會先推理,正確率較高但較慢;CPU 互動場景可在 Open WebUI 模型參數把 `enable_thinking` 設 `false` 換速度,批次/背景任務保留思考模式換正確率。

---

> §8(排程/自動化,原規劃為 n8n)不在本版範圍——待 §9 的 LLM + MCP + Open WebUI 主線在正式叢集穩定驗證後,另行規劃並補上此節。

---

## 9. 各項 ECK 任務(每項含範例驗證)

不只查詢——以下每項任務給「怎麼實現 + 範例 + 驗證通過標準」。任務皆走 §7 的正確性方法(語意說明 + few-shot + 自我修正)。§9.1~9.3、9.5 於本地 Docker 端到端驗證(§13)已先跑過機制面。

### 9.1 深度查詢(聚合/多條件)

- **實現**:Open WebUI → LLM 讀 index 說明 → 產生含 `bool`/`aggs` 的 DSL → MCP `search` 執行。
- **範例**:「上週每天 5xx 錯誤最多的前 3 個服務」→ LLM 產生 date_histogram + terms + filter 的聚合查詢。
- **驗證**:回傳結果與手動寫 DSL 一致;換不同自然語言問法仍得正確結果。

### 9.2 Geofence(地理圍欄查詢)

- **實現**:資料需有 `geo_point`(GeoIP 產生的 `geo.location`)。LLM 產生 `geo_bounding_box` 或 `geo_polygon` 查詢(§7.1 範本已含)。
- **範例**:「找出來源落在台北市範圍(這組座標)內、且流量 > 1MB 的連線」→ LLM 產生 geo_polygon + range 複合查詢。
- **驗證**:圈選範圍內外的測試資料能被正確篩選;與 Kibana Maps 手動繪製多邊形的結果一致。

### 9.3 Data Topology(叢集/分片拓撲分析)

- **實現**:MCP 的 `get_shards` / 自建 `_cat/nodes`、`_cluster/health` 工具 → LLM 解讀。
- **範例**:「哪些 index 的 shard 分佈不均?有沒有節點快滿?」→ LLM 呼叫 `_cat/allocation`、`_cat/shards`,分析後給出人話結論與建議。
- **驗證**:LLM 的結論與 `_cat/allocation` 原始數據相符;能正確指出偏斜或高水位節點。

### 9.4 Dashboard / Data View 建立

- **實現**:自建 MCP 工具包裝 Kibana Saved Objects API;LLM 產生 saved object 定義 → 工具寫入 Kibana。
- **範例**:「幫我建一個顯示各國流量佔比的圓餅圖 dashboard」→ LLM 產生 data view + visualization + dashboard 定義。
- **驗證**:Kibana 中出現該 dashboard 且資料正確;此為**寫入操作**,須經 §10 的受控路徑(非唯讀帳號、需審核)。

### 9.5 分析任務思考(多步推理)

- **實現**:agentic 流程——LLM 拆解問題 → 多次查詢 → 綜合。用 Open WebUI 的 agent 能力。
- **範例**:「分析昨天是否有疑似掃描行為」→ LLM 自主:查連線數異常的來源 → 查這些來源的目的埠分佈 → 判斷是否符合掃描特徵 → 給結論。
- **驗證**:多步查詢邏輯合理;結論有數據支撐;能說明推理過程。

> 定期/排程執行(原規劃 9.6,靠 n8n)不在本版——見 §8 的範圍說明。

---

## 10. 安全與正確性最佳實務(對應「高效正確完成任務」)

| 建議 | 做法 | 為何重要 |
|---|---|---|
| **選 function calling 強的模型** | 主力 `qwen3.6:35b`(MoE 3B 啟動,tool use / agentic 佳、中英強);備援 `qwen3-coder:30b` | 深度查詢的本質是 LLM 產生結構化工具呼叫,這比模型大小更關鍵;§4.2 務必實測驗證 |
| **唯讀權限隔離** | 查詢一律用 `mcp_readonly` 帳號(§6.2);只能 read | 多人 + LLM 產生查詢,防破壞性操作與 prompt injection 災難 |
| **寫入操作走受控路徑** | Dashboard 等寫入用另一個帳號、需人工審核/確認 | 讀寫分離,寫入不可自動化放行 |
| **自我修正迴圈** | 查詢報錯→回饋 LLM→修正重試(§7.4) | 大幅提升一次成功率 |
| **agentic:先縮小再深入** | System prompt 引導:先 list_indices→get_mappings→小查詢驗證→擴大(§7.5) | 比一步到位猜大查詢準得多 |
| **RAG 只餵相關 index** | §7.2 | 避免 context 爆掉與注意力稀釋 |
| **few-shot 範例** | 每 index 5~10 組自然語言→DSL(§7.1) | 對正確率提升最大 |
| **CPU 推論的預期管理** | 互動偏慢(數秒~數十秒);未來走 GPU(§4.4) | 先 CPU 驗證價值,再投資 GPU |
| **查詢逾時/資源保護** | MCP/ES 設查詢 timeout、限制回傳筆數 | 防 LLM 產生的重查詢拖垮叢集 |
| **稽核記錄** | Open WebUI 對話歷史 + ES slow log | 追溯誰查了什麼、除錯 |

---

## 11. 部署順序總覽

```
0.  (建議)先在有 Docker 的機器跑 LLM_MCP/docker-compose.local-test.yml 做端到端功能驗證(§13)
先期(有網路):§2 下載所有映像 + 模型 blob → 推內部 registry / 打包 tar
────────────────── 移入 air-gapped ──────────────────
1. §3  建 ai namespace、controller 貼 label、建本地 PV(ollama 60Gi / openwebui 10Gi)、mkdir 目錄
2. §4  部署 Ollama → §4.3 匯入模型 blob → 驗證 ollama run + tool_calls 格式(§4.2)
3. §6  ES 建唯讀帳號 mcp_user → 部署 es-mcp(args: ["http"])→ §6.3 驗證 /ping 回 200 + es-mcp 能連 ES(list_indices)
4. §5  部署 Open WebUI(先建 WEBUI_SECRET_KEY Secret;ENABLE_SIGNUP=true)→ 建管理員/使用者 → 改 ENABLE_SIGNUP=false rollout → §5.3 接上 MCP → 驗證多人問答 + 工具呼叫
5. §7  撰寫各 index .md 說明(含 few-shot)→ 上傳 Open WebUI 知識庫、設 nomic-embed-text 嵌入(§7.2);目標環境需重新嵌入
6. §9  逐項任務驗證(查詢 / Geofence / topology / 分析)
7. §10 落實唯讀權限、逾時、稽核
```

> **依賴順序**:Ollama(含模型)就緒 → es-mcp `/ping` 回 200 且能連 ES → 才部署 Open WebUI 接線。任一前置未就緒,後者無法驗證。

---

## 12. 已知風險與緩解

- `qwen3.6:35b` 為較新的模型,tool-calling 模板穩定性未經長期驗證 → §4.2 已加驗證指令,異常直接切 `qwen3-coder:30b`(同為 MoE、工具呼叫久經社群驗證)。
- 官方 MCP container 已 deprecated,只收資安更新、不再加新工具 → 若未來升 Enterprise 授權,§1 已預留改接 Agent Builder MCP endpoint 的路徑。
- CPU 推論慢 → 管理使用者預期;重任務未來走 GPU(§4.4);預留 GPU 遷移路徑。
- Open WebUI 知識庫索引不在 ES、不隨 ES 快照走(§7.2)→ air-gap 帶入後須在目標端重新嵌入。

---

## 13. 本地 Docker 端到端驗證(上線前)

正式 k8s 尚未就緒前,先用單機 Docker 驗證「Open WebUI → Ollama(tool_calls)→ es-mcp → ES」整條鏈路與各項功能。

- **位置**:`LLM_MCP/docker-compose.local-test.yml` + `LLM_MCP/README.local-test.md`(依序步驟與驗證矩陣)。
- **組成**:ES 9.4.2 + Kibana 9.4.2 + Ollama(跑小模型 `qwen3.5:4b`)+ es-mcp 0.4.6(`http`)+ Open WebUI v0.11.0 + `nomic-embed-text`(RAG)。
- **與正式環境的刻意差異**:單機、明文 http(無 ECK 自簽 TLS)、`qwen3.5:4b` 取代 `qwen3.6:35b`、單節點 ES、無 MetalLB / 排程。
- **驗證涵蓋**:§4.2 tool_calls 格式、§5.2 多人 + 持久化、§5.3 MCP 工具清單、§6.3 `/ping`+`/mcp`、§7.2 Open WebUI 知識庫 RAG、§9.1 深度查詢、§9.2 Geofence、§9.3 `get_shards`。
- **不涵蓋**(需正式環境或後續):§9.4 Kibana 寫入、`qwen3.6:35b` 實際延遲 / 正確率、單節點下真實 topology 傾斜、ECK 自簽 TLS 路徑。
- **通過標準是「機制正確」**(工具被呼叫、參數合法、ES 回資料、回答有引用所用查詢),**不評估答案品質**——`qwen3.5:4b` 遠弱於 `qwen3.6:35b`。

---

## 附錄:版本清冊(可重構依據,填入實際採用版本)

| 元件 | 映像 / 模型 | 版本 tag | 用途 |
|---|---|---|---|
| Ollama | ollama/ollama | 0.32.9 | 模型推論 |
| 主力模型 | qwen3.6:35b | Ollama 官方 tag(Qwen3.6-35B-A3B,MoE 3B 啟動;含 ~0.9GB 視覺 projector) | 深度查詢(function calling) |
| 備援模型 | qwen3-coder:30b | Ollama 官方 tag(Qwen3-Coder-30B-A3B,MoE ~3B 啟動,以上游 model card 為準) | 工具呼叫穩定性備援 |
| 測試模型 | qwen3.5:4b | Ollama 官方 tag | **僅**本地 Docker 驗證(§13),不進正式叢集 |
| 嵌入模型 | nomic-embed-text | latest | RAG 向量化(Open WebUI 知識庫) |
| 前端 | open-webui/open-webui | v0.11.0 | 多人問答 + MCP client(需 ≥v0.6.31 原生 MCP) |
| MCP | mcp/elasticsearch | 0.4.6(deprecated,僅收資安更新) | ES 工具(唯讀) |

> 所有版本以實際採用為準,務必固定 tag 並隨規劃書一同版控;離線重建時依此清冊還原。實際下載的映像 digest / checksum 記錄於 `LLM_MCP/manifests/VERSIONS.md`。
