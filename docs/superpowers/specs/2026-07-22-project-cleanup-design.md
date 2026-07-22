# USTC Assistant Project Cleanup Design

## Goal

在不损失任何已验证采集能力的前提下，将当前平铺的抓包原型整理为可供后续 App 直接导入的 Python 包，统一命令入口，减少重复浏览器、存储和 CLI 编排代码，并清理已经完成使命的过程文档与派生样例。

本次精简必须继续支持四条真实链路：

1. 获取教务系统课程和考试数据并生成统一导入包。
2. 获取二课平台当前处于“报名中”的活动列表。
3. 获取二课平台用户已经报名的活动日程。
4. 查询评课社区公开内容，并支持与教务导入包自动联动及手动查询。

## Confirmed Decisions

1. 不保留现有 `scripts/collect_*.py` 命令路径的长期兼容层。
2. 最终采用“统一 CLI + 可导入 Python 包 + 按来源隔离模块”的结构。
3. 不将不同网站的 DOM、接口和解析规则强行合并成大文件。
4. 旧实现与新实现迁移期间并存；新实现通过离线测试、输出契约对比和真实网站验收后，才能删除对应旧文件。
5. 测试文件可以合并，但真实故障对应的回归场景不得删除。
6. 二课报名和取消报名始终由用户在官方页面执行，本项目只读采集。
7. `temp.md`、`tmp/`、原始抓包和登录信息不得进入 Git。

## Target Structure

```text
ustc-assistant/
|-- pyproject.toml
|-- README.md
|-- AGENTS.md
|-- src/ustc_assistant/
|   |-- __init__.py
|   |-- __main__.py
|   |-- cli.py
|   |-- common/
|   |   |-- __init__.py
|   |   |-- browser.py
|   |   `-- storage.py
|   `-- sources/
|       |-- __init__.py
|       |-- jw/
|       |   |-- __init__.py
|       |   |-- collector.py
|       |   |-- course.py
|       |   |-- exam.py
|       |   `-- service.py
|       |-- young/
|       |   |-- __init__.py
|       |   |-- enrolment.py
|       |   `-- schedule.py
|       `-- icourse/
|           |-- __init__.py
|           |-- client.py
|           |-- parser.py
|           `-- service.py
|-- tests/
|   |-- __init__.py
|   |-- fixtures/
|   |-- test_cli.py
|   |-- jw/
|   |   |-- __init__.py
|   |   |-- test_collector.py
|   |   `-- test_transform.py
|   |-- young/
|   |   |-- __init__.py
|   |   |-- test_enrolment.py
|   |   `-- test_schedule.py
|   `-- icourse/
|       |-- __init__.py
|       `-- test_public.py
`-- docs/
    |-- architecture.md
    |-- schedule-data-model.md
    `-- data-sources/
        |-- jw.md
        |-- young.md
        `-- icourse.md
```

该结构以职责边界而不是最少文件数为目标。来源之间共享基础设施，但各自保留易变化的网站规则。

## Component Responsibilities

### Common browser layer

`common/browser.py` 负责：

- 专用可见 Edge 持久 Profile 的默认路径。
- Playwright 持久上下文的创建和关闭。
- 浏览器异常到脱敏采集异常的统一转换。
- 可由测试注入假的 Playwright factory。

它不负责识别任何具体网站页面、接口或登录完成条件。

### Common storage layer

`common/storage.py` 负责：

- UTF-8 JSON 输出和父目录创建。
- 默认只写规范化结果。
- 只有显式 `--save-raw` 时才向 `tmp/private/` 写原始数据。
- 为 CLI 返回实际写入路径。

它不解释来源字段，也不改变规范化数据。

### JW source

- `jw/collector.py`：CAS 登录等待、动态 `dataId`、指定 `semesterId` 课表请求及考试 HTML 获取。
- `jw/course.py`：`datum` 分组、教师合并、地点和习题课区分、事件身份及冲突关系生成。
- `jw/exam.py`：`table#exams` 严格解析、表头别名、考试事件和来源记录生成。
- `jw/service.py`：组合课程与考试结果、检查跨来源 ID 唯一性并返回统一导入包。

### Young source

- `young/enrolment.py`：报名中页面登录恢复、前端分页点击、响应校验、活动去重和规范化。
- `young/schedule.py`：北京时间查询窗口、日历跨月导航、中文日期单元格、逐日响应校验、日程去重和规范化。

采集与规范化放在同一来源文件，但拆成纯函数和浏览器边界函数，测试仍可独立覆盖。

### iCourse source

- `icourse/client.py`：公开 HTTP 请求、一次性搜索 token、限速错误和 24 小时本地缓存。
- `icourse/parser.py`：搜索页、课程页和教师页公开 HTML 解析。
- `icourse/service.py`：教务课程分组、课程教师匹配、偏好排序、代表性点评和查询编排。

### CLI and App boundary

`cli.py` 只负责参数解析、调用来源 service、写输出和打印脱敏状态。后续 App 直接导入 service 函数，不启动子进程解析 CLI 输出。

统一命令为：

```powershell
python -m ustc_assistant collect jw
python -m ustc_assistant collect young-enrolment
python -m ustc_assistant collect young-schedule
python -m ustc_assistant query icourse --jw-bundle <path>
```

## File Migration Map

### Scripts

| Current file | Destination |
| --- | --- |
| `scripts/collect_ustc_jw.py` | `cli.py` and `jw/service.py` |
| `scripts/ustc_jw_collector.py` | `jw/collector.py` |
| `scripts/convert_ustc_jw_datum.py` | `jw/course.py` |
| `scripts/convert_ustc_jw_exam_html.py` | `jw/exam.py` |
| `scripts/import_ustc_jw.py` | `jw/service.py` |
| `scripts/collect_ustc_young.py` and `scripts/ustc_young_collector.py` | `young/enrolment.py` |
| `scripts/collect_ustc_young_schedule.py` and `scripts/ustc_young_schedule_collector.py` | `young/schedule.py` |
| `scripts/collect_icourse_public.py` | `cli.py` and `icourse/service.py` |
| `scripts/icourse_public_client.py` | `icourse/client.py` |
| `scripts/icourse_public_parser.py` | `icourse/parser.py` |
| `scripts/icourse_public_query.py` | `icourse/service.py` |

全部来源完成真实验收后删除旧 `scripts/`，不留下兼容包装脚本。

### Tests and fixtures

- 教务浏览器测试迁入 `tests/jw/test_collector.py`。
- 课表、考试、导入和教务 CLI 行为迁入 `tests/jw/test_transform.py` 与 `tests/test_cli.py`。
- 二课两条链路分别迁入 `tests/young/test_enrolment.py` 和 `tests/young/test_schedule.py`。
- 评课社区四个测试文件合并为 `tests/icourse/test_public.py`，内部继续按 client、parser、matching 和 orchestration 分测试类。
- 删除只验证模块存在的测试，保留其余真实行为、隐私和异常回归用例。

Fixture 目标位置：

```text
tests/fixtures/jw/course-datum.json
tests/fixtures/jw/exam-page.html
tests/fixtures/jw/import-bundle.json
tests/fixtures/icourse/search.html
tests/fixtures/icourse/course.html
tests/fixtures/icourse/teacher.html
```

不同来源没有共同输出结构，因此不创建虚构的单一规范化输出样例。删除重复派生样例，完成迁移后删除空的 `examples/`。
评课社区 fixture 只保留验证解析契约所需的最小公开或合成片段，不保存用户身份，也不复制无关的完整网页内容。

### Documentation

- 五份教务抓包、转换和导入文档归并为 `docs/data-sources/jw.md`。
- 二课两条链路的稳定结论归并为 `docs/data-sources/young.md`。
- 评课社区公开查询、缓存和匹配结论归并为 `docs/data-sources/icourse.md`。
- `docs/architecture.md` 描述包结构、统一 CLI、来源服务和 App 调用边界。
- `docs/schedule-data-model.md` 保留，本轮不进行大幅模型重写。
- 有效结论归并后删除旧教务文档以及 `docs/superpowers/plans/`、`docs/superpowers/specs/` 中的历史过程文件；Git 历史继续保存这些内容。

### Root files

- 新增 `README.md`，记录安装、统一命令、输出位置和隐私边界。
- 新增 `pyproject.toml`，声明 Python 3.10 和 Playwright、Requests、Beautiful Soup 依赖。
- 删除 `requirements.txt`，避免维护两份依赖声明。
- 精简 `AGENTS.md`，只保留项目目标、强制安全约束、当前结构、真实验收状态和开发规则。
- 保留 `.gitignore`。
- `temp.md` 与 `tmp/` 保持本地忽略，不自动删除。

## Migration Sequence

1. 在 `refactor/project-cleanup` 分支建立包骨架与公共层，旧脚本保持可用。
2. 迁移教务链路，完成 fixture 对比和真实登录验收后删除旧教务文件。
3. 迁移二课报名中列表，完成输出对比和真实验收后删除旧文件。
4. 迁移二课已报名日程，完成固定日期测试和真实验收后删除旧文件。
5. 迁移评课社区，完成 fixture、公开网络查询和真实教务包联动验收后删除旧文件。
6. 完成统一 CLI、文档和 fixture 整理，最后删除剩余旧目录并运行完整测试。

每个来源单独提交。一个来源失败时停止后续清理，其他已验证来源不回退。

## Verification Gates

每条来源迁移必须依次满足：

1. 迁移前当前旧测试通过。
2. 对应测试迁移到新包并通过。
3. 同一脱敏输入的新旧输出契约一致；时间戳字段可忽略，结构、身份和记录数量必须一致。
4. 日志不包含 Cookie、Token、CAS ticket、上下文 ID、学号或完整原始响应。
5. 默认模式不写原始数据，`--save-raw` 仍明确写入私有目录并显示警告。
6. 用户在真实网站完成该来源验收。
7. 满足以上条件后才删除对应旧实现。

最终验收包括：

```powershell
python -m unittest discover -s tests -v
python -m ustc_assistant --help
python -m ustc_assistant collect jw --help
python -m ustc_assistant collect young-enrolment --help
python -m ustc_assistant collect young-schedule --help
python -m ustc_assistant query icourse --help
```

还必须确认包可在 `ustc_assistant` Conda 环境安装，四条真实链路完成验收，旧 `scripts/` 删除后完整测试仍通过，并且 `git status` 中不存在敏感或生成数据。

## Error Handling and Rollback

- 所有终端错误使用脱敏消息，不附带请求 URL 查询参数、响应体或认证信息。
- 浏览器上下文无论成功或失败都必须关闭。
- 网络或页面契约变化必须明确失败，不输出看似完整的部分结果。
- 新旧实现并存阶段，新实现失败可继续使用旧命令。
- 不使用 `git reset --hard`。通过来源级提交、分支和普通文件恢复完成回滚。
- 真实页面验收失败时只修复当前来源，不提前删除旧文件，也不继续后续来源清理。

## Out of Scope

- 本轮不实现手机 App、数据库或 LLM Agent。
- 本轮不改变日程核心模型的产品决策。
- 本轮不增加二课报名或取消报名能力。
- 本轮不优化评课社区抓取速度或改变缓存策略。
- 本轮不处理滚动快照进入未来 App 后的历史 upsert 逻辑。
