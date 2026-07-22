# USTC Assistant

面向中国科学技术大学的本地优先校园助手数据层。目前提供教务课程与考试、二课报名中活动、已报名二课日程和评课社区公开内容四条只读数据链路，为后续日程 App 和智能体提供结构化输入。

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
```

默认输出分别位于：

- `tmp/ustc-jw-import.generated.json`
- `tmp/ustc-young-enrolment.generated.json`
- `tmp/ustc-young-my-schedule.generated.json`
- `tmp/icourse-public-query.generated.json`

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
