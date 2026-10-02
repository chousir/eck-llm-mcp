# 深度查詢正確性規則（所有 index 通用）

## 用途
產生 Elasticsearch 查詢前的檢查清單，以及查詢出錯或查無資料時的修正方式。

## 產生查詢前
1. 先確定要查哪個 index：檢索知識庫的 index 說明，或用 `list_indices` 確認 index 真的存在。
2. 欄位名稱以知識庫的欄位表為準，並用 `get_mappings` 確認型別；`get_mappings` 若報 `error decoding response body`
   （常見於含巢狀物件欄位的 index），改用 `search` 帶 `"size": 1` 取一筆樣本文件推斷欄位。不要臆測欄位名。
3. 時間條件一律明確寫出（`@timestamp` 的 `range`），沒有指定時預設最近 24 小時，並在回答中說明。
4. 只要統計結果時加 `"size": 0`；要看明細時限制 `size` 並用 `_source` 只取需要的欄位。

## 型別與寫法
| 情況 | 正確寫法 | 常見錯誤 |
|---|---|---|
| 比對 ip 欄位的網段 | `term` 帶 CIDR，例如 `10.0.0.0/24` | 用 `wildcard` 或 `prefix` 查 ip |
| 精確比對字串（國家、狀態碼） | 用 keyword 欄位的 `term` | 對 text 欄位用 `term`（分詞後比對不到） |
| 分組統計 | `terms` 聚合用 keyword / ip / 數值欄位 | 對 text 欄位做 `terms`（會報錯） |
| 依統計值排序分組 | `terms` 的 `order` 指向子聚合名稱 | 用 `sort` 想排序聚合結果（無效） |
| 時間序列 | `date_histogram` 搭配 `fixed_interval`（1h、1d） | 用 `interval` 舊參數 |
| 統計不同值的個數 | `cardinality` 聚合（近似值） | 用 `terms` 再自己數 |

## 查詢出錯或結果不對時
| 症狀 | 處理 |
|---|---|
| `parsing_exception` / `x_content_parse_exception` | DSL 結構錯：檢查大括號層級、聚合是否放在 `aggs` 內、`query_body` 是否為物件而非字串 |
| `invalid type: string, expected a map` | `search` 的 `query_body` 被當成字串送出；改成 JSON 物件 |
| `illegal_argument_exception`（欄位為 text） | 改用該欄位的 `.keyword` 子欄位，或改查正確的 keyword 欄位 |
| `index_not_found_exception` | 先 `list_indices` 確認 index 名稱與萬用字元 |
| 403 / `security_exception` | 唯讀帳號沒有該 index 的權限；照實回報，不要換其他方式繞過 |
| 命中 0 筆 | 先放寬時間範圍；改用 `exists` 查詢確認欄位有資料；檢查大小寫與欄位值的實際寫法（先取樣看看） |

## 回答格式
- 先給結論，再附上使用的查詢（DSL 或 ES|QL）與 index 名稱。
- 數字要附單位（bytes 請換算成 KB / MB / GB 並說明）。
- 查詢失敗而放棄時，說明已嘗試的做法與最後的錯誤訊息。
