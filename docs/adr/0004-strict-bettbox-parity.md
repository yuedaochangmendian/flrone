# ADR 0004 — 严格 Bettbox 桥接架构（取代 ADR 0002 决策 3/8）

- 日期：2026-11-18
- 状态：已接受，分阶段执行
- 取代：`0002-bettbox-alignment.md` 的**决策 3**（保留 424 typed 导出、不动 bindgen）与**决策 8**（双 engine/状态管理留二期）；0002 的数据权威边界（Room 直写、profiles/groups 剩余不迁）继续有效
- 影响范围：内核构建、JNI shim、Kotlin 桥接、Dart FFI、CI、F-Droid、发布链

## 背景

ADR 0002 已经把**协议层**对齐到 Bettbox（`throne_invoke_action`、`Action/ActionResult`、id→Completer、长驻 isolate、message port），并在当时选择保留 gomobile Java 桥与全部 typed 导出作为 handler 实现，双 engine/状态管理留到二期。

2026-11-18 的 P0 调研给出了新的硬事实：

1. **核心侧可以纯 c-shared 构建。** `go build -buildmode=c-shared` 加一个 4 行 `package main` 包装即可产出 425 个 `throne_*` 导出；stripped arm64 78.9 MiB，与 gomobile AAR 里的 `libthrone.so` 量级相同。去掉 `_ "github.com/sagernet/gomobile"` 空导入后产物不变（425 符号），gomobile 不是运行前提。
2. **Dart 生产路径只用约 26/425 个导出（≈6%）。** 其余约 399 个是生成的死面；保留它只增加 bindgen/契约维护成本。
3. **平台面可以 20 槽收敛到 4 槽。** `throne_callbacks_t` 现有 19 个平台回调 + 1 个 `release_object`；`BboxCorePlatform` 的每个职责已经是 JSON 进出，可合并为一个 `platform_request(method, json) -> json`，只保留高频 tun 回调 `protect`、`resolver_process` 和内部 `release_object`。
4. **Kotlin 仍有 26 个文件 import `io.throneproj.mobile.*`（27 个类型）。** 这是去 gomobile 的真实成本；FFI 路径已具备 lifecycle/WARP/quic/action bus，主要缺口是平台回调与同步 `runAction` 孪生。
5. Bettbox 的 3 回调模型是 Mihomo 窄平台面决定的；Throne 的 `PlatformInterface` 更宽，因此本 ADR 采用 **4 槽（3 平台 + platform_request）**，不是逐字 3 回调。

## 决策

1. **保留 Throne 内核**（sing-box/Xray、协议/配置面不变），不引入 Mihomo。
2. **原生面统一为 c-shared `libthrone.so`**：标准 `go build -buildmode=c-shared` + `buildScript/cgoentry` 包装；不再由 gomobile 生成 Java 桥。C ABI（`throne_*`）是唯一原生契约。
3. **平台回调收敛到 4 槽**：
   - `protect`、`resolver_process`（tun-scoped，高频，不能走 JSON）；
   - `release_object`（JNI 引用回收，shim 内部）；
   - `platform_request(method: string, payload: json) -> json`（吞掉 DNS、通知、接口监控、WiFi、连接归属、包名等 15+ 职责）。
   Kotlin 侧把现有 `NativeInterface` 与 `BboxCorePlatform` 合并为一个 JSON 平台门面，删除双写。
4. **单一控制面**：Dart FFI/action bus 拥有 lifecycle 与内核控制；Kotlin 只保留 Android 平台职责（VpnService/TUN fd、通知、`state.stats`、`wifi.watch`、`apps.*`、SAF、data path、FFI 交接）。在 P4 删除 channel fallback、AIDL/handover 双路径。
5. **typed 导出退役**：P3 之后不再生成 340 个 Java→Go 包装；`tools/bindgen` 只保留 c-shared 所需的最小头文件/绑定，`symbol_audit.py`/`channel_audit.py`/`action_contract.py` 按新契约调整，不以放宽门禁修红。
6. **数据权威边界不变**：Room 仍是 profiles/groups 权威，路由文档仍归 Go；`profile*` 剩余与 `groups.*` 的控制面/模型归属不迁。严格对齐的是**桥接层**，不是出站协议模型或存储层。
7. **分阶段、可回滚**：P3 之前 gomobile AAR 仍是发布路径；c-shared 先作为并行产物验证，切换时保留一个版本的 AAR 回退开关。

## 分期

| 期 | 内容 | 验收 | 估算 |
| --- | --- | --- | --- |
| P1（本 ADR） | `buildScript/cgoentry` + `build-cshared.sh` + ADR 0004；不动应用 | 本地 `build-cshared.sh` 产出 3 ABI，425 符号；现有 AAR/CI 不受影响 | 1–2 天 |
| P2 | 平台门面：`throne_callbacks_t` 20→4，`platform_request` JSON schema；Kotlin `BboxCorePlatform` 吸收 `NativeInterface` | 连接/通知/DNS/分应用/接口监控/TV 回归；回调表 4 槽；无 gobind PlatformInterface 调用 | 5–8 天 |
| P3 | Kotlin 去 gobind：lifecycle/WARP/quic/runAction 切到 C ABI；`Func`→自有 CancelToken；删除 26 个 import / 27 类型；`ThroneCore.aar` 从构建链移除 | arm64 真机 + 模拟器连接/测速/订阅/备份全链路；CI 只产 `libthrone.so`；F-Droid prebuild 同步 | 3–4 天 |
| P4 | 单控制面清理：speedTest 收进 action bus；删除 channel fallback/handover/AIDL 双路径；bindgen 收窄 | 冷启动/强杀/接管/通知/磁贴回归；`channel_audit` 新契约全绿 | 2–3 天 |
| P5 | 死面清理与门禁：0 调用 extern/方法、`suspend`/`updateNetworkPath`、文档/CI/F-Droid/发布链 | 三方契约门禁、设备清单、稳定 prerelease | 1–2 天 |

## 后果与风险

**正面**：去掉 gomobile/JDK17/gobind/AAR 缓存整条构建链；桥接面从 425 导出/20 回调收敛到约 26 个实际调用/4 槽；Kotlin 平台职责一份实现；核心升级不再需要重生成整个 Java 面。

**风险**：
- 平台回调合并改变并发/异常语义（DNS 交换、通知、接口监控）；必须按域回归，不能只看编译。
- Kotlin 去 gobind 是跨 26 文件的机械+语义迁移，容易出现 `Instance` 句柄生命周期错误；`Func` 是最后一个 gobind 依赖，必须先替换。
- c-shared 构建的 CI/F-Droid/签名/16 KB/ABI 需要重跑整条发布链；`libthrone.so` 体积不会因此下降（协议引擎为主）。
- 回滚：P3 之前保留 AAR 路径；P2/P3 每步独立 PR，出现回归回到上一期。

## 明确不做

- 不换 Mihomo，不复制 Bettbox 的核心 fork 模型。
- 不重写出站协议模型/订阅/备份数据层；Room 权威边界继续有效。
- 不为了“对齐”删除 `symbol_audit`/`action_contract`/`channel_audit` 门禁；只按新契约收窄。
- 不在 P1–P5 内改状态管理框架/双 Flutter engine（ADR 0002 决策 8 的其余部分另议）。
