# index: netflow-*

## 用途
網路流量記錄（NetFlow），每筆代表一條連線的統計。用來回答「誰連到誰、流量多大、來自哪個國家」這類問題。

## 欄位
| 欄位 | 型別 | 意義 | 範例值 |
|---|---|---|---|
| @timestamp | date | 連線時間 | 2026-07-20T10:00:00Z |
| src_ip | ip | 來源 IP | 192.168.1.10 |
| dst_ip | ip | 目的 IP | 8.8.8.8 |
| dst_port | integer | 目的埠 | 443 |
| protocol | keyword | 通訊協定 | tcp |
| bytes | long | 傳輸位元組 | 15000 |
| geo.location | geo_point | 來源地理座標（GeoIP 產生） | {lat,lon} |
| geo.country_name | keyword | 來源國家 | Taiwan |

## 查詢注意事項
- 時間範圍一律用 `@timestamp` 的 `range`，相對時間寫 `now-1h`、`now-24h`、`now-7d`。
- `src_ip`、`dst_ip` 是 ip 型別：`term` 可以直接帶 CIDR（例如 `10.0.0.0/24`）。
- 只要聚合結果、不要原始資料時，一律加 `"size": 0`。
- `terms` 聚合只能用 keyword / ip / 數值欄位；排序依另一個聚合（例如流量加總）時用 `order`。

## 常見任務範例（自然語言 → ES DSL）

### 範例1：過去 1 小時來自某網段的前 10 大流量來源
使用者問：「過去一小時 10.0.0.0/24 網段流量最大的前 10 個來源 IP」
DSL（index: netflow-*）：
```json
{ "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-1h" } } },
    { "term": { "src_ip": "10.0.0.0/24" } } ] } },
  "aggs": { "top_src": { "terms": { "field": "src_ip", "size": 10,
      "order": { "total_bytes": "desc" } },
    "aggs": { "total_bytes": { "sum": { "field": "bytes" } } } } },
  "size": 0 }
```

### 範例2：過去 24 小時各國家的流量佔比
使用者問：「昨天一整天各國家的流量排名」
DSL：
```json
{ "query": { "range": { "@timestamp": { "gte": "now-24h" } } },
  "aggs": { "by_country": { "terms": { "field": "geo.country_name", "size": 20,
      "order": { "total_bytes": "desc" } },
    "aggs": { "total_bytes": { "sum": { "field": "bytes" } } } } },
  "size": 0 }
```

### 範例3：每小時流量趨勢
使用者問：「過去 24 小時每小時的總流量」
DSL：
```json
{ "query": { "range": { "@timestamp": { "gte": "now-24h" } } },
  "aggs": { "per_hour": { "date_histogram": { "field": "@timestamp", "fixed_interval": "1h" },
    "aggs": { "total_bytes": { "sum": { "field": "bytes" } } } } },
  "size": 0 }
```

### 範例4：單筆流量超過 1MB 的連線
使用者問：「最近 6 小時有哪些單筆流量大於 1MB 的連線」
DSL：
```json
{ "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-6h" } } },
    { "range": { "bytes": { "gt": 1048576 } } } ] } },
  "sort": [ { "bytes": "desc" } ],
  "_source": [ "@timestamp", "src_ip", "dst_ip", "dst_port", "bytes" ],
  "size": 20 }
```

### 範例5：某個目的 IP 被哪些來源連線
使用者問：「過去一天有哪些來源連到 8.8.8.8，各傳了多少」
DSL：
```json
{ "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-1d" } } },
    { "term": { "dst_ip": "8.8.8.8" } } ] } },
  "aggs": { "by_src": { "terms": { "field": "src_ip", "size": 20,
      "order": { "total_bytes": "desc" } },
    "aggs": { "total_bytes": { "sum": { "field": "bytes" } } } } },
  "size": 0 }
```

### 範例6：疑似掃描行為（單一來源連到大量不同目的埠）
使用者問：「昨天有沒有疑似埠掃描的來源」
思路：先找「目的埠種類特別多」的來源，再看這些來源的埠分佈是否符合掃描特徵。
DSL：
```json
{ "query": { "range": { "@timestamp": { "gte": "now-1d" } } },
  "aggs": { "by_src": { "terms": { "field": "src_ip", "size": 20,
      "order": { "distinct_ports": "desc" } },
    "aggs": { "distinct_ports": { "cardinality": { "field": "dst_port" } } } } },
  "size": 0 }
```

### 範例7：同範例1，改用 ES|QL（esql 工具）
```
FROM netflow-*
| WHERE @timestamp >= NOW() - 1 hour AND CIDR_MATCH(src_ip, "10.0.0.0/24")
| STATS total_bytes = SUM(bytes) BY src_ip
| SORT total_bytes DESC
| LIMIT 10
```
