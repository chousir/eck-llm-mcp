# 地理圍欄（Geofence）查詢範例：netflow-*

## 用途
依來源地理位置篩選連線。資料需有 `geo_point` 欄位：`netflow-*` 的 `geo.location`（GeoIP 產生），另有國家欄位 `geo.country_name`（keyword）。
地理查詢本質上就是 `search` 帶 geo query，不需要額外工具。

## 查詢注意事項
- 座標一律寫成 `{ "lat": 緯度, "lon": 經度 }`，不要把經緯度順序弄反。
- 圓形範圍用 `geo_distance`（要有 `distance`，例如 `50km`）；矩形範圍用 `geo_bounding_box`（`top_left` + `bottom_right`）；
  任意多邊形用 `geo_polygon` 或對 `geo_shape` 欄位查詢。
- 地理條件放在 `bool.filter`（不計分、可快取）。
- 沒有座標的文件不會被地理條件命中；若結果比預期少，先確認 `geo.location` 是否存在（`exists` 查詢）。
- 台北市中心座標約 lat 25.033、lon 121.565。

## 常見任務範例（自然語言 → ES DSL）

### 範例1：台北市中心 50 公里內的連線
使用者問：「過去 24 小時來源在台北 50 公里內的連線有幾筆」
DSL：
```json
{ "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-24h" } } },
    { "geo_distance": { "distance": "50km", "geo.location": { "lat": 25.033, "lon": 121.565 } } } ] } },
  "track_total_hits": true,
  "size": 5 }
```

### 範例2：矩形範圍內且流量大於 1MB 的連線
使用者問：「來源落在這個矩形範圍內、流量大於 1MB 的連線」
DSL：
```json
{ "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-24h" } } },
    { "range": { "bytes": { "gt": 1048576 } } },
    { "geo_bounding_box": { "geo.location": {
        "top_left": { "lat": 25.3, "lon": 121.3 },
        "bottom_right": { "lat": 24.9, "lon": 121.8 } } } } ] } },
  "sort": [ { "bytes": "desc" } ],
  "size": 20 }
```

### 範例3：多邊形範圍內的連線（Geofence）
使用者問：「來源落在這組座標圍成的範圍內的連線」
DSL：
```json
{ "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-24h" } } },
    { "geo_polygon": { "geo.location": { "points": [
        { "lat": 25.10, "lon": 121.45 },
        { "lat": 25.10, "lon": 121.65 },
        { "lat": 24.95, "lon": 121.65 },
        { "lat": 24.95, "lon": 121.45 } ] } } } ] } },
  "size": 20 }
```

### 範例4：台灣以外的大流量來源
使用者問：「過去一天來源不在台灣、流量加總最大的前 10 個 IP」
DSL：
```json
{ "query": { "bool": {
    "filter": [ { "range": { "@timestamp": { "gte": "now-1d" } } } ],
    "must_not": [ { "term": { "geo.country_name": "Taiwan" } } ] } },
  "aggs": { "top_src": { "terms": { "field": "src_ip", "size": 10,
      "order": { "total_bytes": "desc" } },
    "aggs": { "total_bytes": { "sum": { "field": "bytes" } },
              "country": { "terms": { "field": "geo.country_name", "size": 1 } } } } },
  "size": 0 }
```

### 範例5：依地理格網統計連線數（畫熱點用）
使用者問：「過去 24 小時連線在地圖上的分佈熱點」
DSL：
```json
{ "query": { "range": { "@timestamp": { "gte": "now-24h" } } },
  "aggs": { "grid": { "geohash_grid": { "field": "geo.location", "precision": 4, "size": 20 } } },
  "size": 0 }
```
