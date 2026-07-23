# USTC Assistant

面向中国科学技术大学的本地优先校园助手数据层。目前提供教务课程与考试、二课报名中活动、已报名二课日程、评课社区公开内容和校内公开信息目录五条只读数据链路，为后续日程 App 和智能体提供结构化输入。

## 安装

```powershell
conda activate ustc_assistant
python -m pip install --no-build-isolation -e .
```

首次使用学校平台时会打开专用 Microsoft Edge 窗口。请在学校官方页面完成登录和验证码；浏览器 Profile 保存在本机，不写入项目目录。

## 命令

```powershell
python -m ustc_assistant collect jw
python -m ustc_assistant collect young-enrolment
python -m ustc_assistant collect young-schedule
python -m ustc_assistant query icourse --jw-bundle tmp/ustc-jw-import.generated.json
python -m ustc_assistant collect campus
python -m ustc_assistant query campus --text "选课"
python -m ustc_assistant read campus --entry-id <catalog-entry-id>
```

教务联动评课社区会把课程名称作为检索词发送给公开网站 `icourse.club`，但不会发送完整课表、时间、地点、用户 ID 或登录信息。首次使用前应确认这一隐私影响；仅需本地检查课程分组时可增加 `--group-only`，该模式不会联网。

校园公开信息目录只读取教务处和财务处的公开页面，不使用登录状态。通知保留北京时间最近 7 个自然日，办事指南和公开信息每个自然月刷新一次；加 `--force` 可强制刷新全部目录。`query campus` 只搜索本地目录，不联网；`read campus` 按目录条目 ID 按需读取正文并使用 30 天详情缓存，刷新失败时默认可返回带 `stale: true` 的旧缓存。

默认输出分别位于：

- `tmp/ustc-jw-import.generated.json`
- `tmp/ustc-young-enrolment.generated.json`
- `tmp/ustc-young-my-schedule.generated.json`
- `tmp/icourse-public-query.generated.json`
- `tmp/campus-catalog.json`
- `tmp/campus-query.generated.json`
- `tmp/campus-detail.generated.json`
- `tmp/campus-cache/`

运行 `python -m ustc_assistant <command> --help` 查看学期、日期、缓存和手动查询选项。

## 隐私

- 默认只保存规范化结果；原始响应仅在显式使用 `--save-raw` 时写入 `tmp/private/`。
- 不保存或输出密码、Cookie、Token、CAS ticket、教务上下文 ID 和二课加密请求参数。
- `tmp/`、`temp.md`、缓存和浏览器 Profile 不进入 Git。
- 二课报名和取消报名始终由用户在学校官方页面执行，本项目不会自动提交。

## 开发

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

架构和来源契约见 `docs/architecture.md` 与 `docs/data-sources/`。
