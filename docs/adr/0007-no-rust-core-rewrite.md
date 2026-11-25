# ADR 0007 — 热路径继续用 Go，不引入 Rust

- 状态：已接受（2026-11-25）。
- 决策：**不做 Rust 重写，也不引入 Rust 热点模块**。单包转发、规则匹配、DNS、加解密继续留在 Go 内核；性能工作限定在 Go 内部优化与跨语言边界（日志已改二进制帧，见下）。
- 背景：曾评估「为性能更换编程语言」，候选为 Rust 替换 TUN/规则/DNS/加解密中的热点。为了不让讨论停留在偏好上，先做了一次同算法基准（spike，已从树中移除以避免死代码；完整代码与说明在 git 历史 `381403f3`，`tools/rule-match-spike/`）。

## 依据：同算法基准（2026-11-25）

规则匹配是这批候选里唯一能按「每连接一次」而不是「每包一次」跨 C ABI 的模块，因此先测它。同确定性数据（20 万条 apex 规则、100 万次查询、50% 命中构造、命中数两侧一致 166,549），同算法（规则后缀哈希集合 + 按标签边界探测），host x86_64 release：

| 实现 | 哈希器 | 建索引 ms | ns / query |
| --- | --- | ---: | ---: |
| Go 1.27 `map[string]struct{}` | runtime memhash | 10.6–13.3 | **93–100** |
| Rust 1.99 `HashSet<Vec<u8>>` + ahash | ahash（固定种子） | 27.3–32.8 | 96–103 |
| Rust 默认 hasher | SipHash-1-3 | 26.6 | 112.6 |
| Rust + FNV-1a | FNV-1a | 30.8 | 129.2 |
| Rust + FxHash 风格 | rotate/xor | 84.7 | 316.3（碰撞严重） |

结论：

1. **同算法下 Rust 与 Go 打平，最好也只有持平（±10% 噪声内），没有语言级收益。** Go 运行时 map/hasher 已经高度优化，Rust 的默认 SipHash 反而更慢。
2. **每连接一次 cgo 调用会把这点差距变成净损失。** 调用与参数编组是几十到上百 ns，与一次匹配本身同量级；真要做必须批量接口（`match_many -> bitset`），那是接口设计收益，不是语言收益。
3. **per-packet 跨 FFI 不可行。** TUN 每包一次 Go↔Rust 跨越会直接压垮包循环；包循环必须留在单一运行时里。
4. Rust 真正可能的优势在**算法与内存形态**：紧凑 trie/双数组自动机、SIMD IP 前缀、共享只读索引、GC 停顿上限。这些用 Go 也能做（或已有），且必须先对 sing-box 真实 matcher、在 arm64 真机上量到端到端瓶颈，才值得投入。
5. 整体换 Rust 内核（如 clash-rs）会丢掉本项目的 tailscale/ccm/ocm/cloudflared/usbip/openconnect 等扩展与路由文档权威线，成本与风险不成比例。

## 已做的边界优化（与语言无关，保留）

- 内核日志从「每行一个 JSON 事件」改为**每次泵出一个二进制 `FLB1` 帧**（`perf(bridge)`，commit `1bd790bb`）：去掉每行一次 `json.Marshal` + 字符串拷贝 + Dart `jsonDecode`，单帧上限 256 行，Dart 按偏移切分。Kotlin 宿主 sink 保持逐行路径。两侧各有契约测试。
- 后续边界工作仍按需推进：动作总线的大 payload（全局规则表、节点列表、测速结果）可评估 protobuf/字节化与批量事件；这不涉及换语言。

## 复查条件（满足其一再重新评估）

- 端到端 profile（Go pprof + Perfetto/Flutter timeline）证明**规则匹配/包处理**是主要 CPU 或延迟来源，而不是 UI 重建、日志、IPC。
- 规则集规模或并发连接数增长到 Go GC 停顿成为可观测问题（`GODEBUG=gctrace=1`、pprof heap/block）。
- 需要跨进程/只读共享索引或确定性延迟上限（例如大量并发短连接）。
- 届时的第一步是**算法级**基准（trie/SIMD/批量 API），并在 arm64 真机上与 sing-box 现有 matcher 对比；语言级重写仍不是默认选项。
