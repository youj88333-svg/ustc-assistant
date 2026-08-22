# M2 详细实施计划：Dart JW 规范化 + SourceBundle 构造，与 Python oracle 对齐

> 分支：`refactor/webview-minimal`（M1 已完成，HEAD 之上增量）
> 依据：`docs/plan-webview-minimal.md` §5（M2 目标）与 §3 里程碑表
> 目标（M2 门）：Dart 从 `course-datum.json` + `exam-page.html` fixture 构造的
> SourceBundle 1.0 与 Python oracle **逐字段对齐**（canonical digest 相等 + 关键身份 hash 相等）。

## 0. 范围与非范围

**做**（纯 Dart，无平台通道、无网络、无 Bridge）：
- 新增 `lib/features/sync/native/` 三个文件：`jw_course_normalizer.dart`、
  `jw_exam_parser.dart`、`jw_source_bundle_builder.dart`（+ 共享小工具）。
- 1:1 复刻 Python `course.py` / `exam.py` / `source_bundle.py` 的规范化与
  bundle 构造逻辑（字段、顺序、hash 算法、externalId 格式、identity tail）。
- 新增测试：用 fixture 输入跑 Dart builder，与 Python oracle 逐字段/digest 对比。

**不做**（留给 M3+）：
- WebView 采集 / CAS 会话 / `SourceCollectionGateway` 接口实现（M3）。
- 替换 Python Bridge 运行通道（M3 才接，M7 才删）。
- 改动现有 `ImportService` / `source_bundle_decoder.dart` / `source_bundle_semantics.dart`
  的消费侧逻辑（M2 只新增"生产侧"Dart builder；消费侧仍读 Bridge 产出的 bundle）。
- 改 schema / DB / UI。

## 1. 关键约束（必须与 Python 完全一致）

> 权威实现是 Python；Dart 是 1:1 端口。任何"看起来更 Dart 风格"的偏离都会导致
> digest 不等、身份 hash 不等，从而 M2 门失败。

### 1.1 hash 算法（两套，不能混）

- **`stable_hash(parts)`**（`course.py`）：`sha256("|".join("" if p is None else str(p) for p in parts)).hexdigest()[:24]`。
  用于：course `collision_discriminator`、exam `identity_hash`（`source_bundle._build_exam_data` 调 `course.stable_hash([...])`）。
  - 关键：`None` → 空串；其他 → `str(part)`；用 `"|"` 连接；取前 24 hex 字符。
  - Dart 必须用 `String` 拼接 + `sha256.convert(utf8.encode(...))`，取 `.toString().substring(0,24)`。
- **⚠️ SourceBundle 1.0 路径只用 `stable_hash`，不用 `digest`/`object_id`/`fingerprint`/`id` 字段**：
  - `exam.py` 里的 `digest()`（`\x1f` 分隔、64 全长）和 `object_id()`（`event_exam_`/`source_exam_` 前缀 hash）以及 `event`/`source` 的 `id`/`fingerprint` 字段，**仅属于 legacy `exam.convert_row`/`course.convert_group` 路径**。
  - `source_bundle.py` 的 `_build_course_data`/`_build_exam_data`/`_record` **完全不调用** `digest`/`object_id`，产出的 event 与 record **没有 `id`/`fingerprint` 字段**（record 只有 `externalId, recordType, entityType, entityExternalId, sourceStatus, sourceUpdatedAt`）。
  - **Dart 端口不要给 bundle entity 加 `id`/`fingerprint` 字段**，不要实现 `digest`/`object_id`。

### 1.2 externalId / identity tail 格式（M2 §5 已冻结，逐字复刻）

- **course series**：`ustc_jw:{semester_key}:series:lesson:{lesson_id}`
- **course occurrence event**：`ustc_jw:{semester_key}:event:course-occurrence:{lesson_id}:{group_id}:{date_token}:{start_hhmm}:{end_hhmm}:{discriminator}`
  - `date_token` = `str(row["date"]).replace("-","")`（如 `20260302`）
  - `discriminator` = `collision_discriminator(row)` = `stable_hash([place_key(row), exercise_key(row)])`
- **course occurrence record**：`ustc_jw:{semester_key}:record:course-occurrence:{identity_tail}`（identity_tail 同上）
- **course series record**：`ustc_jw:{semester_key}:record:course-series:lesson:{lesson_id}`
- **exam event**：`ustc_jw:{semester_key}:event:exam:{course_code}:{identity_hash}`
  - `identity_hash` = `stable_hash([course_code, exam_type, start_at, end_at, room, building, campus])`（24 截断）
  - `start_at`/`end_at` 是 **iso 字符串**（如 `2026-12-28T14:30:00+08:00`），不是原始 `date_time`
- **exam record**：`ustc_jw:{semester_key}:record:exam:{course_code}:{identity_hash}`

> ⚠️ 注意 Python `course.py`（legacy import package）用的是**另一套** externalId
> （`{SOURCE}:{semester_key}:{lessonId}:{group_id}:{date}:{start}:{end}` + collision 后缀）。
> **M2 复刻的是 `source_bundle.py`（SourceBundle 1.0）那套**，不是 `course.py` 的 legacy 那套。
> `source_bundle.py` 的 `_build_course_data` 完全重写了 externalId 格式（见上）。

### 1.3 字段顺序与空值

- bundle 顶层 key 顺序由 `make_bundle_envelope` 决定：`schemaVersion, bundleId, source,
  subject, collectedAt, producer, snapshot, manifest, data`。Dart 用 `Map<String,Object?>`
  时**必须按此顺序插入**（canonical digest 用 `jsonEncode(sortKeys: ...)` 会对 key 排序，
  所以顺序不影响 digest；但 `sourceDetails`/`time` 等嵌套 Map 的**值**必须逐字段相等）。
- `null` vs 缺失：Python 用 `or None` 产生的 `null` 必须在 Dart 用 `null`（不是省略 key）。
  例如 `courseCode: lesson.get("code") or None` → 缺 code 时为 `null`，不是省略。
- `bool`：`exerciseClass: bool(row.get("exerciseClass"))` → Python `bool(None)=False`、`bool({})=True`（非空 dict 为 True）。Dart 必须复刻这个语义。

### 1.4 文本规范化

- `_normalized_identity_text(v)` = `" ".join(str(v).split())`（合并空白、strip）。
  用于 `place_key` 的 location parts。
- `normalize_text(v)`（exam）= 同上。
- `hhmm(v)` = `str(v).zfill(4)`（如 `"945"` → `"0945"`）；非数字抛错。
- `iso_datetime(date, time)` = `"{date}T{hh}:{mm}:00+08:00"`，先 strptime 校验。
- exam `parse_exam_time`：正则 `^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})~(\d{2}:\d{2})$`，
  end>start 校验，输出 `{date}T{HH}:00:00+08:00`。

### 1.5 canonical digest（对比基准）

- Python `canonical_bundle_digest(bundle)` = `sha256(json.dumps(bundle, ensure_ascii=False,
  sort_keys=True, separators=(",",":")).encode("utf-8")).hexdigest()`。
- Dart 对比：把 Dart 产出的 bundle 与 Python oracle 各自 `jsonEncode`（排序 key、无空格）
  后比 sha256；或直接比序列化字符串。**但** `bundleId`/`collectedAt`/`producer` 是
  非确定字段——对比时必须**固定这些字段**（测试注入确定 `bundleId` + `collectedAt`），
  否则 digest 永远不等。
- `producer`：Python 硬编码 `{name:"ustc_assistant_python", version:"0.1.0", platform:"windows"}`。
  Dart builder 的 producer **不能**照抄 Python 的 name（否则谎报身份）。但 M2 门要求 digest
  相等——**决策**：测试对比时对两边 bundle 做"规范化对比"（剔除 `bundleId`/`collectedAt`/
  `producer` 后比 digest），或在 Dart builder 支持注入 producer（测试注入与 Python 相同的
  producer 以做 digest 对比，生产用 Dart 自己的 producer）。倾向后者（见决策 D-M2-1）。

## 2. 任务地图（文件级）

| 操作 | 文件 |
|---|---|
| 新增 | `app/lib/features/sync/native/jw_course_normalizer.dart` |
| 新增 | `app/lib/features/sync/native/jw_exam_parser.dart` |
| 新增 | `app/lib/features/sync/native/jw_source_bundle_builder.dart` |
| 新增 | `app/lib/features/sync/native/_jw_identity.dart`（共享：stable_hash/digest/object_id/hhmm/iso_datetime/normalize_text） |
| 新增 | `app/test/features/sync/native/jw_oracle_equality_test.dart`（Dart vs Python oracle 逐字段/digest） |
| 新增 | `app/test/fixtures/jw/course-datum.json`（复制自 `tests/fixtures/jw/course-datum.json`） |
| 新增 | `app/test/fixtures/jw/exam-page.html`（复制自 `tests/fixtures/jw/exam-page.html`） |
| 新增（生成） | `app/test/fixtures/jw/oracle-bundle.json`（Python oracle 输出，固定 bundleId/collectedAt/producer，作对比金标准） |
| 复用 | `schemas/source-bundle-1.0.schema.json`（Dart builder 输出必须过 schema——Python `validate_source_bundle` 用它；Dart 侧 M2 用 `source_bundle_semantics.dart` 做等价校验，不强引入 jsonschema Dart 包） |

**不改**：`import_service.dart`、`source_bundle_decoder.dart`、`source_bundle_semantics.dart`、
`bridge_client.dart`、`sync_coordinator.dart`、UI、DB。

## 3. Python 任务（生成 oracle 金标准）

### Task P1：生成固定 oracle bundle fixture
- 用 `build_jw_source_bundle` 从 `tests/fixtures/jw/course-datum.json` + `exam-page.html`
  生成 bundle，注入**确定的** `bundle_id="00000000-0000-0000-0000-000000000000"` 与
  `collected_at=datetime(2026,8,22,12,0,0,tzinfo=ZoneInfo("Asia/Shanghai"))`，
  producer 用 Python 默认。
- 写入 `app/test/fixtures/jw/oracle-bundle.json`（pretty-print，utf-8，ensure_ascii=False）。
- 这是 Dart 对比的**唯一金标准**——M2 门不依赖运行时调 Python，只比 Dart 输出与此文件。
- 同时记录 Python oracle 的 canonical digest（剔除 bundleId/collectedAt 前）以便 sanity。

## 4. Flutter 任务

### Task F1：共享身份工具 `_jw_identity.dart`
- `stableHash(List<Object?> parts)` → `sha256(parts.map((p)=>p?.toString() ?? "").join("|")).substring(0,24)`
- `digestSha(List<String> parts)` → `sha256(parts.join("\u001f")).toString()`（64 全长）
- `objectId(String prefix, String external)` → `"$prefix${sha256(external).substring(0,24)}"`
- `hhmm(Object? v)` → 校验数字、`padLeft(4,"0")`
- `isoDateTime(String date, Object? time)` → 校验 + `"$dateT$hh:$mm:00+08:00"`
- `normalizeText(String v)` → `v.split(Whitespace).join(" ")`（等价 `str.split()` 无参 = 任意空白分割）
- 常量：`source = "ustc_jw"`、`sourceSystem = "jw.ustc.edu.cn"`、`timezone = "Asia/Shanghai"`、`tzOffset = "+08:00"`
- ⚠️ `str.split()` 无参在 Python 按**任意空白**（含 \t\n\r\f\v 与连续）分割并丢弃空串。
  Dart `v.split(RegExp(r'\s+')).where((s)=>s.isNotEmpty)` 等价（需 strip 首尾）。

### Task F2：`jw_course_normalizer.dart`（复刻 `source_bundle.py._build_course_data`）
- 输入：`course-datum.json` 的 `result`（`lessonList`/`scheduleGroupList`/`scheduleList`）+ `semesterKey`。
- 输出：`(courseSeries, calendarEvents, sourceRecords)` 三列表。
- 步骤（逐字对齐 Python）：
  1. `_validate_unique_map_ids`（lessonList/scheduleGroupList 唯一 int id）。
  2. `build_maps`（lesson_map[group by int id]、group_map）。
  3. 校验每个 group 的 `lessonId` 在 lesson_map。
  4. `group_schedule_rows`：按 `merge_key`（lessonId, scheduleGroupId, date, startTime, endTime, place_key, exercise_key）分组，**保序**（OrderedDict → Dart 用 `LinkedHashMap` 或保序去重）。
  5. 对每组：校验 lesson_id 在 lesson_map、group_id 在 group_map、group.lessonId==lesson_id；校验组内 rows 在 `_PARTICIPANT_ROW_FIELDS` 外字段一致（`_merged_row_signature`）。
  6. `rows_by_lesson` 收集。
  7. 遍历 lesson_map（**Python 是 `lesson_map.items()` 即插入顺序 = lessonList 顺序**）：建 series + series record。
  8. 遍历 grouped_rows（分组顺序）：建 occurrence event + record。
- `place_key`、`exercise_key`、`room_parts`、`_public_participants`、`_merged_row_signature`、`_normalize_schedule_value` 全部复刻。
- ⚠️ `exercise_key`：`None/False/""` → `"none"`；否则 `jsonEncode(value, sortKeys:true, separators=(",",":"))`。
  Dart `jsonEncode` 不支持 sortKeys——必须手动对 Map key 排序后 encode，或用 `JsonEncoder` + sorted。
- ⚠️ `_normalize_schedule_value`：dict → tuple(sorted((str(k), rec(v))...))，list → tuple(rec)，str → " ".join(split)。
  Dart 需递归实现，用于 `_merged_row_signature` 比较组内 row 一致性。
- 事件 `sourceDetails` 字段逐字对齐（含 `weekIndex: int(row.weekIndex)`、`periods: int(row.periods)`、`exerciseClass: bool(row.get("exerciseClass"))`）。

### Task F3：`jw_exam_parser.dart`（复刻 `exam.py`）
- 输入：`exam-page.html` 字符串 + `semesterKey`。
- 输出：`ExamRow` 列表（先解析）。
- `ExamTableParser`：用 Dart HTML 解析。**决策**：不引入 `html` Dart 包（避免新依赖、离线）；
  用最小手写状态机解析 `<table id="exams">` 的 `<tr>/<th>/<td>`（Python 也是手写 HTMLParser）。
  - 必须复刻：找 `id="exams"` 的 table、table_depth 嵌套、th/td 不能混行、headers 必须是
    `VALID_HEADERS` 之一、cell 文本 `normalize_text`（合并空白）、8 列校验、非 note 字段非空校验。
  - `ExamRow.from_cells`：8 字段，按 dataclass 字段顺序。
- `parse_exam_time`：正则 + strptime 校验 + end>start。
- exam event/record 构造在 F4（builder）里，因为要和 series 联动（`seriesExternalId` 匹配）。

### Task F4：`jw_source_bundle_builder.dart`（复刻 `source_bundle.py.build_jw_source_bundle` + `_build_exam_data`）
- 输入：course-datum Map + exam-html String + accountId + semester + 可选 bundleId/collectedAt/producer。
- 步骤：
  1. `_require_course_result` 校验。
  2. F2 产 `(series, courseEvents, courseRecords)`。
  3. `_build_exam_data`：F3 解析 exam rows；建 `series_by_code`（courseCode→[seriesExtId]）；
     对每个 exam row：`identity_hash`、externalId、查 seriesExternalId（**仅当唯一匹配**才连，否则 null）、
     建 event + record；duplicate externalId 校验。
  4. 合并 data（records: course+exam；events: course+exam；series；relations:[]）。
  5. snapshot（completeness/scope/components，observedRecordCount=len(course_records)/len(exam_records)）。
  6. envelope：`make_bundle_envelope` 等价（schemaVersion="1.0"、bundleId、source、subject、collectedAt、producer、snapshot、manifest、data）。
  7. 可选：跑 `source_bundle_semantics.dart` 的 `validateSourceBundleSemantics` 做等价 schema 校验。
- `collectedAt`：`_collected_at_text` → Beijing 时间，秒精度，iso。Dart 用 `Asia/Shanghai`
  （项目已有 `BeijingClock`）；测试注入确定值。
- producer：**D-M2-1（决策）**：builder 接受 `producer` 参数（默认 Dart 自己的
  `{name:"ustc_assistant_flutter", version:"...", platform:"..."}`）；测试注入与 Python 相同的
  producer 做 digest 对比。生产用 Dart 自己的。

### Task F5：oracle equality 测试 `jw_oracle_equality_test.dart`
- 读 `course-datum.json` + `exam-page.html` fixture。
- 跑 Dart builder，注入固定 `bundleId`/`collectedAt`/`producer`（与 P1 oracle 相同）。
- 读 `oracle-bundle.json`。
- 断言：
  1. **canonical digest 相等**（两边 `jsonEncode` 排序 key 无空格后 sha256）。
  2. 逐集合长度相等（events/series/records/relations）。
  3. 逐 externalId 集合相等（顺序无关，set 对比）。
  4. 抽样逐字段深比（取首个 course event + 首个 exam event + 首个 series + 首个 record，`DeepCollectionEquality`）。
- 边界用例：`jw-empty-exam.json`（已有 fixture，无考试）→ Dart builder 产 0 exam event，digest 对比（需 P1 也为 empty-exam 产 oracle，或复用现有 fixture 做 semantics 校验）。

### Task F6：M2 门验证
- `flutter analyze` 0 error。
- `flutter test test/features/sync/native/` 全绿（oracle equality + 单元）。
- Python oracle 生成脚本可重跑（`python -m ustc_assistant ...` 或一次性脚本）确认 oracle fixture 可复现。
- 不要求改 `flutter test` 全量（M2 新增测试独立绿即可，不回归 M1）。

## 5. 已关闭的决策

- **D-M2-1（producer 注入）**：builder 接受 `producer` 参数，测试注入 Python producer 做 digest 对比，生产用 Dart producer。避免谎报身份 + 允许确定性对比。
- **D-M2-2（不引 html 包）**：exam HTML 解析用手写状态机（与 Python 的手写 HTMLParser 对等），不引 `package:html`（离线 + 少依赖）。
- **D-M2-3（digest 对比固定字段）**：oracle 与 Dart 都注入确定 `bundleId`/`collectedAt`/`producer`，使 canonical digest 可逐位对比；非确定字段不参与门。
- **D-M2-4（只复刻 source_bundle.py 那套）**：不复刻 `course.py` legacy import package 的 externalId（那是旧 `collect_jw_bundle` 路径，SourceBundle 1.0 不用）。
- **D-M2-5（schema 校验）**：Dart 侧用现有 `validateSourceBundleSemantics` 做等价校验，不在 Dart 引 jsonschema；oracle fixture 已过 Python `validate_source_bundle`，Dart 输出与 oracle 逐字段等即隐含过 schema。

## 6. 风险与对策

- **R-M2-1（jsonEncode key 排序）**：Python `sort_keys=True`；Dart `jsonEncode` 不排序。
  canonical digest 对比时，Dart 必须先对**所有层级的 Map key 递归排序**再 encode。
  实现一个 `canonicalJsonEncode(Object?)` 工具（递归：Map→SortedMap、List→递归、其他原样）。
- **R-M2-2（str.split 空白语义）**：Python `str.split()` 无参 = 任意 Unicode 空白 + 丢空串。
  Dart `RegExp(r'\s+')` 默认只 ASCII 空白；若 fixture 含全角空格需 `RegExp(r'[\s\u3000]+')`。
  M2 fixture 是合成 ASCII，先按 `\s+` 实现，测试验证；若不符再扩。
- **R-M2-3（bool(dict) 语义）**：Python `bool({})` = False（空 dict）、`bool({"a":1})`=True。
  Dart `Map.isNotEmpty`。`exerciseClass` 可能是 dict/bool/str——`bool(row.get("exerciseClass"))`
  在 Python：None/False/""→False，{}→False，非空 dict/True/非空 str→True。Dart 按类型分派复刻。
- **R-M2-4（int 转换）**：Python `int(value)` 接受 str/int/float；`int(True)`=1 但 Python 先用
  `_source_integer` 排除 bool。Dart 用 `int.tryParse`（str）+ 类型检查，复刻 `_source_integer` 的 bool 拒绝。
  - ⚠️ 区分：`_source_integer`（带 bool 拒绝）用于 id/lessonId/scheduleGroupId；**raw `int()`（不拒绝 bool）**
  用于 `weekIndex`/`periods`（`int(row["weekIndex"])`、`int(row["periods"])`）。Dart 端口要分别处理。
- **R-M2-5（place_key / exercise_key 内部 JSON 序列化——最高影响）**：
  `place_key`（course.py:65-69）在无 room.code 时构造
  `json.dumps(["room", *location_parts], ensure_ascii=False, separators=(",",":"))`——
  是一个**列表**、不 sort_keys、非 ASCII 直通、紧凑分隔。
  `exercise_key`（course.py:77-82）在非空时构造
  `json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",",":"))`——
  dict 时**sort_keys=True**、紧凑。
  这两个序列化字符串喂入 `collision_discriminator` → `identity_tail` → **externalId**。
  Dart 必须逐位复刻：列表用 `jsonEncode(["room",...])` 紧凑无空格（Dart `jsonEncode` 默认无空格✓、非ASCII直通✓）；
  exercise_key 的 dict 必须**先对 key 排序**再 `jsonEncode`。
  任何 CJK 转义/空格/key 顺序差异都会让 externalId 静默漂移。
- **R-M2-6（collectedAt 时区校验）**：`_collected_at_text`（source_bundle.py:384-392）
  要求 `utcoffset() is not None`（naive datetime 抛错），并 `astimezone(BEIJING_TZ).replace(microsecond=0).isoformat(timespec="seconds")`。
  Dart 端口：测试注入确定 tz-aware collectedAt；生产用 `BeijingClock`（已 tz-aware）；
  复刻 microsecond=0 + 秒精度 + `+08:00` 后缀。

## 7. 字段形状清单（附录，逐字对齐 source_bundle.py）

> 此附录列出 Dart 端口必须产出的**每一个字段**；遗漏任一都会让 canonical digest 不等。

### 7.1 顶层 envelope（`make_bundle_envelope`，contracts/source_bundle.py）
```
schemaVersion: "1.0"
bundleId: <String>
source: "ustc_jw"
subject: { accountId: <String> }   // ⚠️ 是 {accountId}, 不是裸 string
collectedAt: <iso String, 秒精度, +08:00>
producer: { name, version, platform }   // 可注入；测试注入与 oracle 相同
snapshot: { completeness:"complete", scope:{...} }   // 见 7.2
manifest: { sourceRecordCount, calendarEventCount, courseSeriesCount, scheduleRelationCount }  // 各 = len(...)
data: { sourceRecords, calendarEvents, courseSeries, scheduleRelations }   // 见 7.3-7.6
```

### 7.2 snapshot.scope
```
type: "semester"
semesterKey: <semester.semester_key>
sourceSemesterId: <semester.semester_id>   // int
components: [
  { name:"course_table", status:"complete", observedRecordCount: <len(course_records)> },
  { name:"exam_arrange",  status:"complete", observedRecordCount: <len(exam_records)> },
]
```

### 7.3 courseSeries 元素（_build_course_data，每个 lesson）
```
externalId: "ustc_jw:{sem}:series:lesson:{lesson_id}"
title: lesson.courseName or "未知课程 {lesson_id}"
courseCode: lesson.code or null   // ⚠️ or None → null
semesterKey: <sem>
participants: [ {role:"teacher", name:<str>} ... ]   // _public_participants：去重 (role,name)，仅 role+name 两字段
sourceDetails: { kind:"jw_course_series", lessonId: str(lesson_id) }   // ⚠️ lessonId 是 str
```

### 7.4 course occurrence event（_build_course_data，每个 grouped row）
```
externalId: "ustc_jw:{sem}:event:course-occurrence:{identity_tail}"
seriesExternalId: "ustc_jw:{sem}:series:lesson:{lesson_id}"
title: lesson.courseName or "未知课程 {lesson_id}"
descriptionText: null   // ⚠️ course 恒 null
eventType: "course"
time: { kind:"timed", startAt:<iso>, endAt:<iso>, timezone:"Asia/Shanghai" }
location: { name:<location>, building:<building>, campus:<campus> }   // room_parts：null 也保留 key
participants: [ {role:"teacher", name:<str>} ... ]   // _public_participants(rows)
sourceDefaults: { importance:"normal", attendancePolicy:"unknown", listeningMode:"unknown" }
sourceDetails: {
  kind:"jw_course_occurrence", semesterKey:<sem>,
  lessonId: str(lesson_id), scheduleGroupId: str(group_id),   // ⚠️ str 包裹
  courseCode: lesson.code or null, courseTypeName: lesson.courseTypeName or null,
  weekIndex: int(row.weekIndex), periods: int(row.periods),   // ⚠️ raw int()，不拒 bool
  exerciseClass: bool(row.exerciseClass)   // bool() 语义见 R-M2-3
}
```
identity_tail = `{lesson_id}:{group_id}:{date_token}:{start_hhmm}:{end_hhmm}:{discriminator}`
（date_token = row.date.replace("-","")；discriminator = stable_hash([place_key, exercise_key])）

### 7.5 exam event（_build_exam_data）
```
externalId: "ustc_jw:{sem}:event:exam:{course_code}:{identity_hash}"   // course_code 是 row.course_code（已 normalize_text）
seriesExternalId: matching_series[0] if len(matching_by_code)==1 else null   // ⚠️ 单匹配才连
title: row.course_name   // ⚠️ exam title 无 "（exam_type）" 后缀（那是 legacy exam.py；source_bundle 用裸 course_name）
descriptionText: row.note or null
eventType: "exam"
time: { kind:"timed", startAt:<iso>, endAt:<iso>, timezone:"Asia/Shanghai" }
location: { name: row.room, building: row.building, campus: row.campus }
participants: []
sourceDefaults: { importance:"critical", attendancePolicy:"must_go", listeningMode:"unknown" }
sourceDetails: {
  kind:"jw_exam", semesterKey:<sem>,
  classroomNumber: row.room, examType: row.exam_type,
  courseCode: row.course_code or null, instructions: row.note or null
}
```
identity_hash = stable_hash([course_code, exam_type, start_at, end_at, room, building, campus])（24 截断；start_at/end_at 是 iso 字符串）

### 7.6 sourceRecords（_record）
course-series record：`{ externalId:"ustc_jw:{sem}:record:course-series:lesson:{lesson_id}", recordType:"jw_course_series", entityType:"course_series", entityExternalId:<series extId>, sourceStatus:"active", sourceUpdatedAt:null }`
course-occurrence record：`{ externalId:"...:record:course-occurrence:{identity_tail}", recordType:"jw_course_occurrence", entityType:"calendar_event", entityExternalId:<event extId>, sourceStatus:"active", sourceUpdatedAt:null }`
exam record：`{ externalId:"...:record:exam:{course_code}:{identity_hash}", recordType:"jw_exam", entityType:"calendar_event", entityExternalId:<event extId>, sourceStatus:"active", sourceUpdatedAt:null }`
⚠️ record **无 id/fingerprint 字段**；`sourceUpdatedAt` 恒 `null`（保留 key）。

### 7.7 data 顺序
```
sourceRecords: [*course_records, *exam_records]   // course 在前，exam 在后
calendarEvents: [*course_events, *exam_events]     // course 在前，exam 在后
courseSeries: <按 lessonList 顺序>
scheduleRelations: []
```

## 8. 审核轮记录

### 第 1 轮审核（子 agent 对比 Python 实现）
发现并修正：
- §1.1 错误声称 exam SourceBundle record 带 `digest` fingerprint + 含 legacy `object_id`/`id` 前缀逻辑——已改为"SourceBundle 路径只用 stable_hash，不加 id/fingerprint"。
- 新增 R-M2-5（place_key/exercise_key 内部 JSON 序列化，喂入 externalId，最高影响）。
- 新增 R-M2-6（collectedAt tz 校验）。
- 新增 §7 字段形状清单（sourceStatus/sourceUpdatedAt/descriptionText/sourceDefaults/subject.accountId/str 包裹 id/exam title 无后缀 等之前漏列字段）。
- R-M2-4 区分 `_source_integer`（拒 bool）vs raw `int()`（不拒 bool，用于 weekIndex/periods）。
