# 二课平台来源

## 安全边界

本项目只查询活动和个人日程。报名和取消报名始终由用户在学校官方页面完成，不复刻写接口，也不处理前端加密参数。

## 报名中活动

入口为 `/login/sc-wisdom-group-learning/myproject/SignUp`，列表响应路径为 `/login/wisdom-group-learning-bg/mobile/item/enrolmentList`。

动态 `_t` 和加密 `requestParams` 完全由学校前端生成。采集器点击“报名中”和 Ant Design 下一页按钮，使用响应中的 `pages` 与 `total` 校验，不能信任始终可能为 1 的 `current`。活动按来源 ID 去重；冲突重复或最终数量不一致时失败。

登录后若 SPA 落到数据看板，采集器会在同一超时内重新打开报名页面。

## 已报名日程

入口为 `/login/sc-wisdom-group-learning/personalInformation/mySchedule`，日历响应路径为 `/login/wisdom-group-learning-bg/personal/scCalendar/getPageUserList`。

查询窗口是北京时间闭区间 `[今天 - 7 天, 今天顺延一个自然月]`。目标月没有同号日期时取月末。采集器逐日点击中文 `YYYY年M月D日` 标题的日期单元格，兼容跨月箭头和年月下拉框。

空日期有效。单日多页目前明确失败，避免静默缺失。日程按来源日程 ID 去重，并校验记录覆盖所选日期、结束时间不早于开始时间。

## 快照语义

输出是本次窗口完整快照，不代表历史删除。未来 App 同步层应执行 upsert，区分窗口外、窗口内缺失、来源取消和用户删除，并始终保留用户覆盖层。

当前 Python 输出的顶层 `schedules` 是 legacy 开发格式。Flutter 接入时必须转换为
`docs/data-sources/source-bundle-v1.md` 定义的
`ustc_young_my_schedule` Bundle：每条已报名日程变为 CalendarEvent，日期窗口
声明完整检查天数和空日期数量，不携带远端 userId 或原始 HTML。
