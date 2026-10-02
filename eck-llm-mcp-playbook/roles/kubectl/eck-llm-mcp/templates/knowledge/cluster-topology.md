# Elasticsearch 叢集與分片拓撲分析（Data Topology）

## 用途
回答「叢集健不健康、index 與 shard 怎麼分佈、哪些 index 最大」這類問題。不查業務資料，查的是叢集本身的狀態。

## 可用工具與用法
| 工具 | 用途 | 備註 |
|---|---|---|
| `list_indices` | 列出符合 `index_pattern` 的 index | 先用它找出有哪些 index，再決定查哪個 |
| `get_shards` | 查 shard 的分佈（對應 `_cat/shards`） | 每筆有 `index`、`shard`、`prirep`（p=primary、r=replica）、`state`、`docs`、`store`（大小）、`node`；不帶 `index` 則回傳全部 |
| `get_mappings` | 看某 index 的欄位 | 含巢狀欄位時可能報錯，改用 `search` 帶 `size:1` 取樣 |
| `search` | 帶 DSL 查詢 | `query_body` 必須是 JSON 物件，不是字串 |
| `esql` | ES\|QL 查詢 | 適合做彙總與排序 |

唯讀帳號只有 `monitor` 與指定 index 的 `read`、`view_index_metadata` 權限；沒有的權限會回 403，請照實回報，不要編造。

## 判讀規則
- shard 狀態 `STARTED` 為正常；`UNASSIGNED` 代表沒有被分配到任何節點（replica 在單節點叢集上未分配是常見且正常的）；`RELOCATING`、`INITIALIZING` 是搬移或恢復中。
- 「分佈不均」：比較各節點上的 shard 數與資料量，某節點明顯高於其他節點就是偏斜。
- 「節點快滿」：`get_shards` 只提供每個 shard 的大小（`store`）與所在節點，**沒有節點的磁碟總量與使用率**，無法直接判斷快滿。只能加總各節點上的 shard 資料量來比較誰最重，並明確說明這不是磁碟使用率；要看磁碟水位（超過 85% 的節點不會再被分配新的 shard）需要 `_cat/allocation`，目前沒有對應的工具。
- 單一 shard 過大（例如超過 50GB）或過小而數量過多，都值得提醒調整。

## 常見任務範例（自然語言 → 工具呼叫）

### 範例1：叢集有哪些 index，哪些最大
使用者問：「叢集現在有哪些 index，哪幾個最大」
作法：
1. `list_indices`，`index_pattern` 用 `*`：只有 index 名稱、狀態與文件數（`docs.count`），**沒有大小**。
2. 要比大小就用 `get_shards`，把同一個 index 的所有 shard 的 `store` 加總（primary 與 replica 都算，或只算 primary 並說明）。
3. 列出前幾名的大小與文件數；系統 index（`.` 開頭）另外標示。

### 範例2：哪些 index 的 shard 分佈不均
使用者問：「哪些 index 的 shard 分佈不均？」
作法：
1. `get_shards` 取得全部 shard。
2. 依節點統計 shard 數與總大小，找出明顯偏高或偏低的節點。
3. 回答時列出節點名稱、shard 數、資料量，並說明哪個節點偏斜，不要只給結論。

### 範例3：有沒有未分配的 shard
使用者問：「有沒有 shard 沒有被分配？原因是什麼？」
作法：
1. `get_shards`，篩出狀態為 `UNASSIGNED` 的列。
2. 區分 primary 還是 replica：primary 未分配代表資料目前不可用，需優先處理；replica 未分配只是少了備援。
3. 若無法取得原因（權限不足），說明需要有 `monitor` 以上權限的帳號，或請管理者查看分配說明。

### 範例4：某個 index 的 shard 配置
使用者問：「netflow-* 的 shard 與 replica 怎麼配置」
作法：`get_shards`，`index` 帶 `netflow-*`，整理成「index、shard 數、primary 與 replica 各幾份、各在哪個節點」。
