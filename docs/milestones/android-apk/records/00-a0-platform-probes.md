# A0：工具链与原生能力原型

日期：2026-10-16。状态：实施中，未完成技术准入或设备验收。

## 批准与本切规格

用户要求“请按照项目工作流和迁移计划开始进行迁移”，随后说明暂无Android手机，鸿蒙“应该是最新版”，模拟器选择成熟兼容版本。按[计划](../plan.md)先使用Android15/API35/x86_64官方镜像，Android14为后续兼容回归；鸿蒙具体版本、是否有APK兼容环境和实际能力均未验证。

设计依据为[07](../../../architecture/07-constitution.md)、[08](../../../architecture/08-target-architecture.md)、[09](../../../architecture/09-contracts.md)、[10](../../../architecture/10-runtime.md)、[11](../../../architecture/11-component-designs.md)、[12](../../../architecture/12-cross-cutting.md)、[13](../../../quality/13-risks-and-acceptance.md)、[14](../../../reviews/14-overall-review.md)及[15](../../../workflow.md)。Sol负责宿主、工具链、WebView及集成，Luna/max分别承接固定契约的Keystore和通知探针，文件不重叠。

只新增Android宿主和Debug专用QA原型，沿用现有Flutter工程与锁定依赖，不改Windows正式数据库、凭据、通知身份或1.00交付。QA包使用`.qa`独立身份；原型仅合成数据、loopback网页、临时密钥和固定静态提醒，不访问学校或读取已有浏览器/业务资产。生产Release不包含QA入口与Receiver。

验收条件：实际安装QA APK；两个Profile隔离及按Profile清理、重启恢复有可重复证据；Keystore用途绑定/nonce/缺失密钥拒绝；退出进程后实际OS投递与取消；如实报告提供方/权限/模拟环境的不足。源码完成、编译通过与上述运行结果分别登记，不用Android版本号推断WebView能力。

## 工具链盘点

- 原工程为Flutter3.44.5、Dart3.12.2，批准前无Android宿主；Windows1.00标签与私有包保留。
- 已有`E:\Android\Sdk`，platforms34/35/36/36.1、build-tools36/36.1/37、NDK28.2.13676358；未发现已安装系统镜像。沿用本机SDK，不另装整套工具链。
- Android Studio自带JBR21.0.10；Flutter当前模板采用Gradle9.1.0、AGP9.0.1、Kotlin2.3.20，Java/Kotlin目标17。实际解析/构建尚待执行。
- Emulator36.6.11的`-accel-check`报告加速驱动未安装。先尝试独立软件模拟，不修改系统虚拟化功能或安装驱动；若不能运行，保留具体失败并继续可独立验证的工程。

## 检查记录

尚未完成构建及模拟运行；后续在本节记录实际命令、失败与结果。目标实机与真实学校、真实模型和中文语音保持未验证。
