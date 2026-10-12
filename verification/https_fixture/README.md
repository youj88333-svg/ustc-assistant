# 本机 HTTPS / WebTransport 合成 fixture

这是 WebView2 网络通道验证使用的一次性合成服务，不属于产品依赖。只绑定 `127.0.0.1` 的随机端口，不代理或转发请求，也不访问外部网络。

## 启动接口

使用 Conda `basic310`，并把本实验隔离的依赖目录仅加入当前进程：

```powershell
& 'E:\conda\envs\basic310\python.exe' verification/https_fixture/fixture.py `
  --runtime-root 'E:\107\.worktrees\rewrite\design-reset\verification\.runtime\https_fixture\run-<随机ID>' `
  --deps-root 'E:\107\.worktrees\rewrite\design-reset\verification\.runtime\transport-deps'
```

两个路径必须是 `verification/.runtime` 下已存在、逐级无符号链接或 reparse point 的目录。`runtime-root` 的末级目录名须以 `run-` 开头；fixture 不创建该目录。它会生成临时 ECDSA P-256 自签名证书，SAN 为 `127.0.0.1`、有效期六天；HTTPS SSL context 和 aioquic 配置读入证书后，立即删除运行根中的临时证书与私钥文件。

启动成功时 stdout 第一行是 JSON：

```json
{"event":"ready","fixture_version":1,"port":12345,"url":"https://127.0.0.1:12345/query","certificate_sha256_base64":"...","certificate_sha256_hex":"..."}
```

其中端口和证书指纹每次启动随机生成。`certificate_sha256_base64` 是 DER 证书的 SHA-256，可供浏览器 WebTransport 证书哈希选项使用。

## 合成行为与控制

- TCP/TLS 提供 `GET /query`，返回固定 JSON `{"fixture":"https-fixture","version":1,"result":"synthetic-ok"}`，并返回 `Access-Control-Allow-Origin: *`。相同路径的 OPTIONS 仅用于 CORS 预检；其他请求不会转发。
- UDP/QUIC 使用 HTTP/3，接受 `CONNECT`、`:protocol = webtransport`、`:path = /query`。只对固定 datagram `fixture-datagram-v1` 回送 `fixture-datagram-v1-echo`；其他 payload 不回送、不记录。`quic_udp_datagrams` 在 UDP endpoint 收到每个包时递增，包含进入 WebTransport 前的 QUIC 握手包；`webtransport_echoes` 只统计固定 payload 的成功回送。
- stdin 每行接收 `{"command":"snapshot|reset|stop","id":"..."}`。snapshot/reset 返回 `event=command`、原 id、四项整数计数和仅含异常类型名的 `fault_types`。reset 将计数和故障类型清零。stop 先关监听器和连接，再返回 `event=stop`、相同 id、`stopped=true` 及仅含异常类型名的 `fault_types`；close 阶段若出现新 fault，stop 仍会返回结果并以非零码退出。stdin EOF 同样清理；无 fault 时以 0 退出，有 fault 时以非零码退出。非法控制输入会清理并闭合，输出只含类型名的 JSON fault。
- HTTPS 自有 protocol 在 `connection_lost` 时立即消费 close Future；只有该 HTTPS protocol 上的精确 `ConnectionResetError` 作为对端关闭处理。loop handler 也只过滤异常上下文明示指向该 HTTPS protocol 或 `asyncio.sslproto` TLS protocol/transport 的精确 `ConnectionResetError`；其余 loop、QUIC 和 fixture handler 异常仍计入 `fault_types`。
- stdout 只输出 JSON-lines。aioquic 日志、qlog 和 TLS secrets log 均关闭；请求 headers 和 payload 不进入日志或证据。

实现依据 aioquic 官方 [asyncio API](https://aioquic.readthedocs.io/en/latest/asyncio.html)、[HTTP/3 API](https://aioquic.readthedocs.io/en/latest/h3.html) 与 [HTTP/3 server 示例](https://raw.githubusercontent.com/aiortc/aioquic/main/examples/http3_server.py)。

## 验证记录

- Conda `basic310` / Python 3.10 语法检查通过。使用隔离依赖 `aioquic 1.3.0` 的本机 smoke 已通过：HTTPS GET 返回固定 JSON 和 CORS；aioquic 客户端收到 WebTransport CONNECT 200 与固定 datagram echo；CONNECT 前 snapshot 已观察到 UDP 握手包，且 connect/echo 计数为 0。snapshot/reset/stop、stdin EOF 和非法控制输入的闭合路径通过；停止后 TCP/UDP 端口可重新绑定，运行根无临时证书或私钥残留，fixture stderr 为空。
- 首次 HTTP/3 echo 尝试发现 datagram handler 缩进在协议类之外，导致 callback `AttributeError`；将 handler 放回协议类后重跑通过。Windows 受限运行环境中的 `Path.resolve()` 返回 WinError 5，路径检查改为规范化绝对路径、逐组件拒绝 reparse/symlink 并检查最终目录类型。
- 默认 sandbox 阻止 Python asyncio 初始化其 loopback socketpair；本机合成 smoke 在仅访问 `127.0.0.1` 的受限执行命令中通过。此环境现象不代表浏览器测试结果。
- 首轮真实 WebView2 联调失败记录保留：五个 reference/guard/restart contexts 都报告唯一 `fault_types=["ConnectionResetError"]`，同时每个 HTTPS GET 已计数 1；reference 的 WebTransport echo 成功，guard 的 QUIC/CONNECT/echo 均为 0。stop 回复正确，但进程退出码为 `3221225477`，stderr 长度 295；根代理安全分类确认是 `BufferedReader` shutdown lock 错误。修复为控制线程以 `os.read` 分块取 stdin，避免解释器关闭时等待 `sys.stdin.buffer` 锁；loop handler 只过滤 SSL protocol/transport 上的精确 `ConnectionResetError`，其他异常仍保留。
- 修复后本机 synthetic smoke 重跑通过：TLS 自签验证拒绝后进行固定 HTTPS GET；aioquic 在 CONNECT 前观察到 UDP 计数大于 0 且 WT 计数为 0，随后 CONNECT 200 和固定 datagram echo 成功；snapshot/reset/stop 均通过。stdin 保持打开时 stop 后 5 秒内退出码 0、stderr 为空，TCP/UDP 端口可重新绑定，临时运行根无残留。该轮仅证明本机 synthetic client；真实 WebView2 修复后复验由 Sol 执行，当前未据此声称浏览器已通过。
- 第二轮真实 WebView2 回归失败记录也保留：stop 已为 `stopped=true` / exit 0，但 15 个 contexts 中 13 个仍有唯一 `ConnectionResetError`，HTTPS GET 与 WT/CONNECT 计数符合预期，两个 contexts 没有 fault。检查 Python 3.10 `StreamReaderProtocol.connection_lost` 可见它会把该错误放入协议自己的 `_closed` Future；如果该 Future 晚于连接回调才被销毁，asyncio 可能以未取回的 Future 异常上报且上下文不再带 TLS transport。此路径尚需 WebView2 回归确认。当前修复在 fixture 自有 HTTPS protocol 的 `connection_lost` 阶段立即取回 close Future：只消费精确的 `ConnectionResetError`，其他 close 异常仍记录；stop ack 现在带 close 完成后的 `fault_types`，并在有 fault 时退出非零。真实 WebView2 修复后回归由 Sol 执行，尚未声称通过。
- 最新本机 TLS 回归使用 Python 3.10 asyncio debug：系统信任验证拒绝临时自签证书，随后 synthetic HTTPS GET 返回 200 且计数为 1；snapshot 与 stop ack 的 `fault_types` 均为空。stdin 保持打开时 stop 后 exit 0、stderr 为空，TCP/UDP 端口可重新绑定，运行根无残留。此结果未覆盖真实 WebView2，也不证明第二轮浏览器故障已消失。
- WebView2/Chrome 实际客户端：由 Sol 集成验证；上述 aioquic 客户端 smoke 不作为真实浏览器通过证据。

### 最终集成结果

主代理的第二次原生回归仍遇到 `ConnectionResetError`；只记录库类型的诊断表明异常来自 Python 3.10 Windows Proactor 的 SSL transport 回调。最终仅合成服务选择 `WindowsSelectorEventLoopPolicy`，服务仍只使用 socket，stdin 仍由 `os.read` 线程处理；WebView2、代理、Conda 与系统证书信任未改。其他 loop、protocol 和关闭异常仍记录，stop 返回关闭后的 `fault_types` 和固定类型诊断 `fault_contexts`，存在故障时退出非零；不会用一条无故障 snapshot 替代停止检查。

[最终真实 WebView2 独立轮](../windows/evidence-connection-allowlist-https-selector-independent.json)为 107 pass / 0 fail / 31 info / 1 not_run、退出 0：五类文档的 reference GET、WebTransport CONNECT 和固定 echo 全部阳性，guard 首次/重启的 GET 阳性而 QUIC/CONNECT/echo 全为零，故障数和 stderr 均为零。主代理最终三组控制/清理检查与五个异常分类反例通过，记录见[独立验收元数据](../evidence-continuation-review.json)。旧失败 JSON 保留；这里的通过不解决 CAL 在后续文档 RTC 构造时的原生崩溃，也不关闭 V-02。
