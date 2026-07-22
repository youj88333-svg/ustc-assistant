# 中科大教务考试安排转换规则

本文记录综合教务系统“考试信息”页面的入口行为，以及将考试 HTML
转换为项目标准 `CalendarEvent` 和 `SourceRecord` 的原型规则。

## 1. 已确认的入口行为

登录教务系统后，请求固定入口：

```text
GET /for-std/exam-arrange
```

服务器返回 HTTP `302 Found`，并将当前登录用户重定向到：

```text
/for-std/exam-arrange/info/{contextId}
```

课表入口 `/for-std/course-table` 采用相同机制，当前观察到两个模块解析出的
`contextId` 相同。产品不需要根据学号推算、遍历或长期保存该值；新登录会话
从固定入口重新解析即可。

## 2. 数据来源

考试详情页不依赖额外的 Fetch/XHR 明细接口。服务器已经将完整考试安排渲染在：

```html
<table id="exams">
```

每个 `tbody tr` 表示一场考试，列顺序为：

| 序号 | 页面字段 | 是否必填 |
| --- | --- | --- |
| 1 | 课程号 / 课堂号 | 是；不同页面版本观察到两种表头 |
| 2 | 考试类型 | 是 |
| 3 | 课程名称 | 是 |
| 4 | 日期时间 | 是 |
| 5 | 考场 | 是 |
| 6 | 教学楼 | 是 |
| 7 | 考场所在校区 | 是 |
| 8 | 考试说明 | 否 |

教务系统通常只在考试安排确定后生成考试行。因此原型不创建
`pendingExams`：如果已出现的行缺少必填字段，视为页面结构或源数据异常。
空表是合法情况，表示当前没有已发布的考试。

## 3. 解析边界

当前原型只处理“已保存且正确解码为 UTF-8 的完整 HTML”：

```text
考试 HTML -> table#exams -> ExamRow -> CalendarEvent + SourceRecord
```

登录、Cookie、302 跳转、HTML 下载和本地数据库写入不属于该脚本。解析器只读取
`table#exams`，忽略页面中的姓名、学号和其他内容，也不会把原始 HTML 写入输出。

实现使用 Python 标准库 `html.parser.HTMLParser`，不使用正则表达式解析 HTML，
也不增加第三方依赖。

## 4. 校验规则

解析器会拒绝以下输入：

- 找不到 `table#exams`；
- 表头名称或顺序改变；第一列明确兼容“课程号”和“课堂号”，其余列仍严格校验；
- 数据行不是八列；
- 除考试说明外的字段为空；
- 日期时间不符合 `YYYY-MM-DD HH:MM~HH:MM`；
- 日期或时间数值无效；
- 结束时间不晚于开始时间；
- 同一输入中出现重复考试身份。

单元格会先解码 HTML 实体，并将连续空白归一为单个空格。

## 5. CalendarEvent 映射

| CalendarEvent 字段 | 来源或默认值 |
| --- | --- |
| `title` | `课程名称（考试类型）` |
| `type` | `exam` |
| `status` | `active` |
| `startAt` | 日期 + 开始时间，`+08:00` |
| `endAt` | 日期 + 结束时间，`+08:00` |
| `timezone` | `Asia/Shanghai` |
| `locationName` | 考场 |
| `buildingName` | 教学楼 |
| `campusName` | 考场所在校区 |
| `importance` | `critical` |
| `attendancePolicy` | `must_go` |
| `attendanceDecision` | `go` |
| `confidence` | `high` |
| `tags` | `exam`、考试类型 |
| `metadata.courseCode` | 页面第一列课程标识（表头可能为课程号或课堂号） |
| `metadata.examType` | 考试类型 |
| `metadata.examNote` | 考试说明，空值转为 `null` |

考试解析器不单独生成冲突关系。考试与课程、二课、个人安排之间的关系由统一日程
聚合层基于全部事件生成。

## 6. 外部身份与变更检测

稳定外部身份为：

```text
ustc_jw:exam:{semesterKey}:{courseCode}:{examType}
```

时间、考场或说明改变时，`externalId` 保持不变，应用可以更新原事件。若同一学期、
同一页面第一列课程标识和考试类型出现两行，原型会报错，不猜测两行的对应关系。

`SourceRecord.fingerprint` 是八个标准化源字段的 SHA-256 摘要。任何考试安排变化都会
改变指纹，但输出不保存姓名、学号、Cookie、Token、`contextId` 或完整 HTML。

## 7. 样例与命令

脱敏输入样例：

```text
examples/ustc-jw-exam-page.sample.html
```

标准输出样例：

```text
examples/ustc-jw-exam-events.sample.json
```

运行转换：

```powershell
conda run -n basic310 python scripts\convert_ustc_jw_exam_html.py `
  --input examples\ustc-jw-exam-page.sample.html `
  --output tmp\exam-events.generated.json `
  --semester-key 2026spring `
  --user-id user_sample
```

运行测试：

```powershell
conda run -n basic310 python -m unittest discover -s tests -v
```

## 8. 后续接入

移动端接入层需要完成：

1. 在受控登录会话中请求 `/for-std/exam-arrange`；
2. 自动跟随 HTTP 302；
3. 获取最终 HTML，但不把完整 HTML 发送给 LLM；
4. 在本地调用本文解析规则；
5. 用 `externalId` 更新事件，并用 `fingerprint` 判断安排是否改变；
6. 对旧事件消失的情况执行单独的源同步/停用策略。
