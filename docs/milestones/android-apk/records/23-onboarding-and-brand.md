# 首次设置与图标

日期：2026-10-25。任务规格见本阶段任务单“A8首次设置与品牌准备”。用户授权直接实施四段引导和复用main图标；A7/实机未观察项继续开放。

## 研究与选择

使用已安装ui-ux-pro-max及flutter-build-responsive-layout：沿用项目已批准白色平面风格、窄表单和48dp触控。UX搜索建议跳过/返回，Flutter表单建议按提交验证并为键盘滚动。设计系统搜索中的Flat Design可用；Product Demo营销页结构、新字体及配色不适合本工程，因此不采用，不新增设计系统来源。

参考Android官方[权限请求](https://developer.android.com/training/permissions/requesting)：在相关功能处主动请求，拒绝可继续，不在进入引导时弹全部权限；应用本地提醒开关与OS通知许可分开。[自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)使用108dp图层与66dp安全区，保留完整原图，不重画。

## 图标来源

main提交e1b7ed32238e4fa2dba3d4a99855b2cf2268bb13仍是默认图标；用户意图所指自定义图标在E:\107的main工作区中（PNG未跟踪、ICO已修改），本切只读复制这两项，未修改该工作区。1024方形PNG的SHA256为a89623e9364cd95fe916ff0764407bf45ac11932a7eafc14bda47cb5175bbd7c，Windows ICO为40cf4b0e5d9fd6354b8fe747d2724bd984172ec75e8cfa0f56a7ae4d0a908c6d。根实际查看PNG；Android各密度缩放与自适应安全区采用此原图，系统背景白色，不新增AI图像或下载素材。

## 实施与检查

待根完成后按实际结果填写；不能将任务单或子代理声明视为检查已通过。
