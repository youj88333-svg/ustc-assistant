# 教务课程与考试来源

## 入口和认证

课程固定入口为 `/for-std/course-table`，考试固定入口为 `/for-std/exam-arrange`。两者会跳转到带动态上下文的详情页；上下文 ID 由登录会话解析，不写死、不记录。

## 课程

1. 打开课程固定入口并监听精确的 `GET /for-std/course-table/get-data` 响应。
2. 从实际 URL 解析动态 `dataId`，使用配置的内部 `semesterId` 再请求目标学期。
3. 读取 `lessonIds`，调用 `POST /for-std/course-table/datum`。
4. 使用 `lessonList`、`scheduleList` 和 `scheduleGroupList` 生成日程。

`semesterId` 不能根据年份推算。当前 Windows 自动同步和 CLI 默认使用
`semesterId=461`，对应产品学期键 `2026fall` 和显示名“2026 秋季学期”。
CLI 仍可通过完整的学期 ID、产品学期键和显示名三元组显式覆盖默认值。

同一节课可能因多教师产生多行，也可能存在不同地点或习题课分组。转换器按课程、排课组、日期、时间、地点和规范化习题课信息合并；`null`、`false` 和空习题课标记等价，多位教师进入同一事件。只有真实身份碰撞时才追加稳定哈希后缀。

## 考试

考试数据服务端渲染在 `table#exams`，无需额外 XHR。解析器只接受已知八列表头，第一列兼容“课程号”和“课堂号”。空表表示尚未发布考试安排，是有效结果；结构变化、时间错误和重复身份会明确失败。

## 输出

`python -m ustc_assistant collect jw --account-id <local-account-id>` 合并课程和
考试并输出 `docs/data-sources/source-bundle-v1.md` 定义的 SourceBundle 1.0。
同一个 `ustc_jw` Bundle 声明课程与考试组件完整，生成 CourseSeries 和规范化
CalendarEvent，不携带数据库 ID、远端 userId 或自动冲突关系。考试默认重要级别为
critical、出勤为 must_go；课程出勤默认 unknown。

旧版顶层 `calendarEvents` 文件仅由评课社区的只读兼容适配器接受，不再是采集 CLI
的输出格式，也不得进入 Flutter ImportService。

默认不保存完整 `datum` 或考试 HTML。`--save-raw` 仅用于本地调试。
