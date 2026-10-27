# 0.2 开发版验证记录

日期：2026-10-27。基线为 `main` / `2b84efc27d692c0845fd948dd91ce363ba85f1ab` / 0.1.1。开始时工作区干净；本轮一直在原分支工作，没有创建分支或 worktree。当前版本为 `0.2.0-dev.1`，发布状态见文末。

## 实现与能力边界

公共 Swift 核心、SwiftNIO HTTP 服务和 FFI 生命周期分别位于 `darwin/lib_mlx/Sources/MlxCore`、`MlxServer`、`lib_mlx`。Flutter iOS/macOS 共用 Darwin 源码；原生 Swift 宿主通过根 SwiftPM package 使用核心，不依赖 Flutter。两份 manifest 由同一个脚本生成。

生产加载使用官方 MLX 文本实现、真实 tokenizer 和固定模型的 chat template；没有 mock 回退。测试 backend 必须显式注入。文本、多轮、thinking、增量 SSE、取消和上下文准入已经实现。图片、音频、工具执行尚未完成，生产接口明确拒绝；协议类型仍保留内容顺序、工具 ID 和任意 JSON 参数。工具类型测试不能作为工具推理证据。

一个进程只持有一个生产模型，每模型一个活动生成。`queue_limit` 只计等待请求，不包含活动请求。事件 sink 等待网络写入；慢消费者会暂停生产或触发写超时，不丢 delta。停止和卸载关闭监听器、已接受连接，取消并等待队列/生成收尾，然后释放请求 KV，最后释放权重。每请求独立 KV，不进行前缀复用、KV 量化或压缩。

上下文限制包括模板输入及预留输出；真实 tokenizer 计数后准入，不静默截断历史。分块 prefill 默认 256 token。预检分别检查进程可用内存、Metal 推荐工作集及 MLX 分配上限，不把重叠指标相加。模型窗口上限 131072 不代表每台设备可运行 128K。

## 固定版本

| 项目 | 本轮使用 |
| --- | --- |
| Mac | MacBook Pro / MacBookPro18,4 / Apple M1 Max / 32 GB |
| macOS | 27.0.1 (26A434) |
| Xcode | 27.1 (27A9275) |
| Swift | 6.4 / swiftlang-6.4.0.34.1，最低 tools 6.3 |
| Metal compiler | 32023.921 / metalfe-32023.921.6 |
| Flutter / Dart | 3.47.8 / 3.13.7 |
| 示例目录 API | path_provider 2.1.6 / path_provider_foundation 2.6.0，锁定于 example/pubspec.lock |
| MLX Swift / LM | 0.32.3 / 3.32.3 |
| MLX C++ / C 子模块 | 1f8e74e3f12f31365464a6867c6579f0e9b29d85 (v0.32.2) / ebc88f10caa1b625e6b581437a8dea6df8a70085 |
| swift-transformers / SwiftNIO | 1.3.0 / 2.81.0 |
| 模型仓库 | mlx-community/gemma-4-e2b-it-4bit |
| 模型 revision | 238767527555cb75a05732a84dff5d6ba0dd6809 |
| 量化 | affine 4-bit / group size 64 |
| 部署下限 | macOS 14、iOS/iPadOS 17、tvOS 核心目标 17 |

`Package.resolved` 固定传递依赖；`tool/toolchain.json`、`tool/model-lock.json` 和核心资源记录工具链与资产校验信息。权重未纳入 Git。模型完整快照约 3.55 GB，官方文本实现过滤未使用的视觉/音频塔；实际常驻文本张量约 2.60 GB。未引入 VincentGourbin 实现，也未宣称 E2B 音频链路可用。

## 问题逐项处理

| 编号 | 当前处理 | 验证证据与边界 |
| --- | --- | --- |
| B1 | 已替代 stub：真实初始化、资产/revision/哈希验证、Metal 与内存准入，无生产 mock 回退 | Swift 真模型测试、公开 Dart 真模型链路；不存在路径及同大小损坏权重均失败；初始化后才 ready |
| P1-1 | UTF-8 字节编码后设置准确 Content-Length；NIO 支持 chunked 和分段读取 | Dart→Swift 中文/emoji/工具/stream 协议集成；raw socket framing 测试 |
| P1-2 | 实际仅绑定 127.0.0.1/::1；localhost 显式转为 127.0.0.1；非回环拒绝 | socket 连接、实际端口/base URL 和非回环拒绝测试 |
| P1-3 | 可配置 header/body/连接数/元数据上限、读取及写入期限；长度校验不溢出 | 负数、溢出、冲突、超大 body/header/trailer、分段与未完成请求超时测试 |
| P1-4 | await 事件 sink 与逐步 socket 写入；一个活动生成及有界等待队列 | 首 delta 早于生产结束、500 个 delta 不丢失、慢消费者和真实模型流式测试 |
| P1-5 | Registry 串行完整生命周期操作；模型 actor 协调 drain/shutdown；stop 管理已接受连接 | 并发 start/stop、排队/活动取消、断开、已接受连接关闭、模型关闭不可逆测试；真实 unload/reload |
| P1-6 | 兼容性调整：移除无法构建的单模块 podspec，使用真实 SwiftPM 依赖和共享 Darwin targets | 具体上游构建/资源/模块证据见 migration-0.2.md；不宣称 CocoaPods 可消费 |
| P1-7 | 新增 macOS Flutter 宿主，Dart 支持 macOS+iOS；iPadOS 共用 iOS 接入 | 原生/Flutter、编译/运行状态分列于下表；tvOS 不新增独立宿主或 CI |
| P1-8 | 保留快速协议测试；新增公开 Dart→Swift 协议集成、FFI ABI 和真实模型 smoke 入口 | 测试 backend 与生产链路分开；CI 增加真实报告门禁，未用编译代替推理 |
| P2-1 | 有序角色/内容、instructions、thinking 历史、tool call/result/ID 保留 | 纯转换与 Dart→Swift 深层 JSON 测试；生产不支持的类型明确拒绝 |
| P2-2 | 递归 JSON 值替代 String 字典 | 数字、布尔、null、数组、嵌套对象及调用 ID 测试 |
| P2-3 | 默认服务身份来自 resident model，别名单独标记并校验；执行温度/top-p/top-k/seed/token 上限 | 真实 tokenizer usage，真实模板输出，非法及未支持参数拒绝测试；timings 为本地扩展 |
| P2-4 | 上下文、prefill、独立 KV、设备预算和压力策略已实现；资产校验缓冲按块释放；重复加载的资源恢复尚未通过 | 4K→8K→16K Mac 实际输入及核心 pressure/drain 测试通过；iPhone 已实测内存警告取消及修复后的预算拒绝；上游每次加载残留 4,464 B 仍阻断资源验收；前后台真机验收未完成 |
| P2-5 | Debug/Release entitlements 分文件；不含 debugging-only memory entitlement；更新真实依赖工具链 | 配置与 Release 签名检查；设备运行不能由 entitlement 文件本身推定 |

## 已执行的测试

下列日志在本地 `build/` 中，不提交模型、二进制或临时日志。

| 命令 | 结果 |
| --- | --- |
| `swift test --scratch-path example/build/macos/SourcePackages --skip-update --jobs 2` | 最新 51 项，49 通过、2 项真实资产/模型测试因未设环境变量跳过；0 失败。`build/swift-tests-asset-fix.log` |
| `LIB_MLX_TEST_MODEL_PATH="$PWD/build/models/gemma-4-e2b" swift test --scratch-path example/build/macos/SourcePackages --skip-update --jobs 2 --filter MlxRealModelTests` | 真实资产内存与真实推理 2 项单独执行通过；`build/asset-memory-green-real-model.log` |
| `LIB_MLX_PROTOCOL_HOST="$PWD/example/build/macos/SourcePackages/debug/ProtocolTestHost" flutter test test` | 最新 13 项通过；`build/dart-swift-asset-fix.log` |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tool.test_release_gate` | 29 项通过，包含缺失/伪造/过期摘要、宿主锁文件/配置漂移、上下文、计时与实际签名 entitlement 的严格布尔值检查；`build/release-gate-tests.log` |
| `dart format --output=none --set-exit-if-changed lib test tool example/lib` | 最新 17 文件，0 改动，包含新增资源探针 |
| `flutter analyze .` | 无问题；`build/flutter-analyze-final.log` |
| `python3 tool/package_manifests.py --check` | 两份 manifest 与生成器一致 |
| `swiftc darwin/lib_mlx/Sources/MlxCore/CoreTypes.swift tool/json_value_smoke.swift -o build/json-value-smoke && build/json-value-smoke` | 5 个整数边界序列化往返通过，包括 Int.min、Int.max、UInt64.max；已加入 Apple CI |
| `python3 tool/fetch_model.py MODEL_PATH --verify-only` | 固定 revision 的全部配置、模板、tokenizer 和权重通过大小/哈希验证 |
| `flutter test test/openai_transport_test.dart test/types_test.dart test/sse_parser_test.dart` | 最终 Dart 客户端与类型/解析检查 12 项通过 |

最新 Swift 真模型测试实际输出 `Paris`，输入 21、输出 2 token，prefill 0.366 秒；thinking 输出 413 字符、正文为 `43`，取消/清理约 0.020 秒。MLX active 2,604,110,606 字节、peak 3,550,531,684 字节、allocator cache 0。该证据是 macOS Swift 宿主测试，不是 Flutter 或 iOS 验收。

另以 APFS clone 保留相同 manifest、相同权重大小，仅翻转权重数据区一个字节，通过公开 Dart FFI 加载，得到 `invalid_model_assets: Checksum mismatch for model asset: model.safetensors.`，未进入 ready。原始权重没有修改，故意损坏的临时 clone 已删除；日志为 `build/corrupt-assets.log`。

协议测试使用可控制 backend；证明首 delta 在生产者完成前到达、队列满返回 429、排队取消释放位置、断开与 stop 等待收尾、慢连接写入受限。连接数上限曾暴露初始化期间提前关闭 socket 的 NIO 注册竞态，已改为激活时拒绝，并验证已准入及后续连接继续工作。

最终契约检查还复现了 NSNumber 转换把 `9223372036854775808` 改为负数的问题，现保留无符号 JSON 整数。独立整数边界回归、最终全量 Swift、真实模型及 Dart→Swift 测试均通过。Chat 流式 `stream_options.include_usage` 现按显式开关发送 usage，默认 false；非流式与 Responses 的统计不受影响。

另修复了加载过程中退后台通知被注册表长锁阻塞的竞态：独立的短锁状态持有加载任务及操作代次，通知立即取消加载；结果发布时再次校验，失效模型先 shutdown，不能在失活后返回 ready。6 项回归验证初始 inactive、及时取消、忽略取消的旧加载结果、快速失活/恢复及内存警告；这仍不是物理设备前后台验收。

## macOS 原生 dylib 的公开真实模型链路

依次执行：

```sh
dart run tool/runtime_smoke.dart build/models/gemma-4-e2b .build/debug/libMlxRuntimeFFI.dylib 4096
dart run tool/runtime_smoke.dart build/models/gemma-4-e2b .build/debug/libMlxRuntimeFFI.dylib 8192
dart run tool/runtime_smoke.dart build/models/gemma-4-e2b .build/debug/libMlxRuntimeFFI.dylib 16384
```

三个进程均通过不存在路径拒绝、真实加载、模型身份、文本及 usage、多轮+Responses instructions、thinking 增量、超限拒绝、接近窗口的输入、取消、stop/restart、unload 和重复加载。多轮回复保留 `aqua`，thinking 与正文分离。协议层通过实际 Swift HTTP 服务，没有测试 backend。

| 配置 | 实际输入/输出 token | prefill | 运行后进程物理占用 | MLX active / peak / cache |
| --- | --- | --- | --- | --- |
| Debug 4K | 3,986 / 2 | 此次 HTTP 尚未导出 timings | 2,949,860,952 B | 2,604,110,686 / 3,550,531,684 / 0 B |
| Debug 8K | 8,082 / 2 | 8.488 秒 | 2,966,179,392 B | 2,604,110,686 / 3,550,531,684 / 0 B |
| Debug 16K | 16,274 / 2 | 13.061 秒 | 2,984,971,864 B | 2,604,110,646 / 3,550,531,684 / 0 B |

完整 JSON 见 `build/dart-real-{4096,8192,16384}.json`。4K thinking 测试 78 个增量，首 delta 405 ms、共 6,332 ms；这些是该次运行的时序证据，不是跨设备性能承诺。16K 的成功只适用于本机、本配置、本输入；32K/64K/128K 尚未执行。

进程物理占用是采样值，不是进程峰值；MLX peak 是分配器峰值，包含模型初始化，不能与进程占用或 cache 相加。不同进程、shader 预热及系统压力会影响计时。重复加载/卸载的功能检查通过，但后续资源恢复探针失败，不能称资源已回到稳定范围；长期浸泡及进程峰值采样也尚未完成。

## 资源恢复：已复现的上游阻断

`tool/resource_smoke.dart` 在同一 Dart 进程执行五轮公开真实模型链路，共十次加载/卸载。它使用实际 macOS SDK 编译的 Metal library，公开 API 完成推理、取消和卸载，只通过上游 C API 读取卸载后的分配器统计。Dart CLI 没有应用资源 bundle，因此显式调用上游支持的 `mlx_metal_set_metallib_path`；Flutter 宿主不需要这个覆盖。

严格探针命令：

```sh
dart run tool/resource_smoke.dart "$PWD/build/models/gemma-4-e2b" \
  "$PWD/.build/out/Products/Debug/libMlxRuntimeFFI.dylib" \
  "$PWD/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
  "$PWD/build/resource-cycles-strict.json"
```

实际退出 **1**。每轮真实文本、多轮、thinking、上下文、取消、stop/restart 和卸载功能检查通过；但五轮 idle active 为 `8,976 / 17,944 / 26,872 / 35,800 / 44,768 B`，跨轮跨度 `35,792 B`，超过明确的 4 KiB 容差。cache 为 `40 / 40 / 40 / 80 / 0 B`。约 2.60 GB 权重已释放，但小额 active 持续累积，资源恢复验收未通过。结果及日志为 `build/resource-cycles-strict.json`、`build/resource-cycles-strict.log`。早期只检查 1 MiB 上限的诊断输出曾显示 passed，该检查不能证明稳定，已由严格的跨轮增长检查替代。

最小实验不依赖模型或 RuntimeRegistry：对 32×32 affine 4-bit QuantizedLinear 预热一次，再执行两批各 100 次构造/释放。直接释放的 active 为 `8 → 8 → 8 B`；通过 `Module.update(parameters:)` 替换三个未求值的量化参数后释放，为 `24 → 1,624 → 3,224 B`，即每次残留 **16 B**。先求值再替换的诊断对照为 `16 → 16 → 16 B`。全部 cache 为 0，helper 的 MLX 符号解析到现有 native image，没有第二份 MLX。复现入口与结果在 `build/rng-diagnostic/quantized_repro.py`、`quantized-repro.json`。这些临时实验不作为生产实现或工具推理证据。

上游 C++ `array` 复制/移动赋值覆盖旧 descriptor，绕过析构中解除多输出 sibling 引用环的逻辑；Swift 的参数更新最终调用这个赋值路径。该固定 checkpoint 有 276 个 Linear 和 2 个 Embedding，遗留的初始化标量为 `276 × 16 + 2 × 24 = 4,464 B/load`，与实测吻合。全局 RNG 求值/重置以及独立 RNG 作用域均没有消除残留，因此没有提交这些猜测补丁。

官方 [MLX #4453](https://github.com/ml-explore/mlx/pull/4453) 已修复引用环。实际尝试固定 MLX Swift `392aa34400708e2e73d9ba3e99a68055786ad9f3`，含 C++ v0.32.4 `36969c094354086e15d2a327a9c50feb20b9cf11` 和 C `a26f2d584a14ec619ae8db9a09be03becd47598a`。SwiftPM 解析成功，其他 14 个 pin 未漂移；但 `swift test --scratch-path example/build/macos/SourcePackages --jobs 2` 编译退出 **1**：`MLXLMCommon/CompiledTrace.swift:162` 把新 `compile(inputs:)` 的非 Sendable 返回值转换为 `@Sendable`，不再符合上游新契约。日志为 `build/swift-cycle-fix-tests.log`。

LM 当前主线 `efcedcd4cd245eb03b65050a6bd2c103d7252d42` 的相关代码相同。核对的较旧已发布版本 3.31.4/3.31.3 虽有 E2B 文本实现，却分别限制 MLX 为 0.31.x，均缺少当前 prefill 配置和块间取消，3.31.3 还没有 seed。它们不满足本轮行为要求。不可构建的候选 pin 已撤回，两份 manifest 和五份锁文件继续采用已实际执行的 0.32.3/3.32.3 组合。

资源恢复仍是**尚未完成的上游阻断**，不是环境验收通过。解除条件是取得保留 seed、分块取消等所需行为、同时包含引用环修复的兼容官方版本组合，更新全部 pin，重跑最小复现、严格公开链路循环和两平台 Release 验收。对随机占位模型先求值会改变初始化计算量和内存峰值，因此没有用它绕行。新 real-model workflow 会运行严格恢复探针；当前组合不能通过该 workflow，也不能据此发布。

随后实际构建了保留版本的原生 **Release** 库：`swift build --scratch-path example/build/macos/SourcePackages --jobs 2 -c release --product MlxRuntimeFFI` 退出 0，耗时 259.73 秒。通过 `swift build --scratch-path example/build/macos/SourcePackages -c release --show-bin-path` 得到真实产物目录，使用其中 dylib 和 SDK 编译的 `default.metallib` 执行同一探针。五轮功能检查均通过，资源恢复断言退出 **1**：idle active 为 `8,976 / 17,984 / 26,912 / 35,840 / 44,728 B`，跨度 **35,752 B**，cache 均为 0。报告为 `build/native-release-resource-report.json`，run ID `local-native-release-resource-20261027`，源码摘要仍为 `87854edbe36f6d34765506ca5dc18cc26ef5920e4b103c7f05086bc498d28cd1`；构建和运行日志为 `build/native-release-resource-build.log`、`build/native-release-resource.log`。因此恢复失败也在原生 Release 中得到实证，不仅是 Debug 现象。

原生库由根 SwiftPM package 构建；它与 Flutter app 的 framework 有不同的资源访问约定。尝试把 Flutter framework 直接装入 Dart CLI 时，先后遇到动态 framework 搜索和 `Bundle.module` 资源错误，未进入推理，故没有将其计作模型运行失败或成功。正式恢复入口采用原生 SwiftPM 产物；Flutter Release 链路继续由应用内 smoke 验证。最新静态分析、29 项发布门禁测试、YAML 解析与恢复步骤的 `bash -n` 均通过。

资产校验缓冲修复后，以相同固定依赖再次构建原生 Release（113.46 秒，退出 0），并用最新摘要 `32bfbc27ca7839a67d71f14bea63afc5c91e77815b8f825339668df3053abc41` 重跑严格五轮探针。五轮公开功能检查仍全部通过，但 idle active 为 `9,016 / 17,864 / 26,872 / 35,800 / 44,808 B`，跨度 **35,792 B**，cache 均为 0；进程退出 **1**。当前报告为 `build/native-release-asset-fix-resource.json`，run ID `local-native-release-asset-fix-e9513707-9f79-40c6-b45f-d576a92d81a1`；构建/运行日志为 `build/native-release-asset-fix-build.log`、`build/native-release-asset-fix-resource.log`。这确认 Foundation 校验临时内存缺陷已修复，但没有解决独立的上游 MLX 分配器残留，发布阻断继续保留。

## Flutter 与设备状态

| 平台/能力 | 实现状态 | 本轮实际验证 |
| --- | --- | --- |
| macOS Swift 核心与公开 Dart dylib 链路 | 实现完成 | 已实际执行并通过，Debug 4K/8K/16K |
| macOS Flutter Release | 实现完成 | 已实际执行并通过，arm64、ad-hoc 本地签名、独立启动、真实模型 4K |
| macOS 重复加载的资源恢复 | 尚未完成，上游阻断 | Debug 与原生 Release 实际执行均未通过；不能以功能检查通过替代资源验收 |
| iOS/iPadOS Flutter SwiftPM 接入 | 实现完成 | 默认 Increased Memory Limit 配置的 Release 构建、严格验签通过；两台设备曾安装默认版本，最新内存修复产物在 iPhone 安装/启动通过；不是分发签名 |
| iPhone 11 / iPhone12,1 / iOS 27.0.1 | 接入实现完成；模型 smoke 实际执行未通过 | 已定位并修复校验缓冲保留问题；最新默认签名 Release 独立运行后明确返回 insufficient_memory，当前配置不满足设备预算；没有真实 token 或上下文通过声明 |
| iPad Air 13-inch M3 / iPad15,5 / iPadOS 27.0.1 (24A446) | 接入实现完成；运行环境阻塞 | 较早默认签名 Release 已安装，已有模型保留；仍要求密码解锁，最新产物安装另遇 CoreDevice 4000 连接超时，尚未执行新版真实推理 |
| tvOS 核心 | 保留兼容目标 | 本轮按约定不新增独立工程、设备测试或 CI；未单独验证 |
| 图片/音频/工具执行 | 尚未完成，显式 unsupported | 已验证拒绝及协议语义保留；没有推理支持声明 |
| iOS 前后台、系统内存警告 | 处理策略实现完成 | 9 项核心生命周期测试通过；iPhone 已实际观察到内存警告取消加载；前后台恢复及压力后的真模型恢复尚未验证 |

### iOS 签名与诊断配置

默认 Release 请求 `com.apple.developer.kernel.increased-memory-limit`。早先的 `xcodebuild` 在签名阶段失败：当时选中的 wildcard provisioning profile 不包含 Increased Memory Limit capability，命令行还报告账户凭据无法加载。日志为 `build/ios-release-build.log`。这些旧日志不能证明当前 GUI 账户状态异常；签名阻断已在下述复核中解除。

此前实际执行带 `-allowProvisioningUpdates` 的默认 Release 构建时仍退出 65。命令行报告 `missing Xcode-Token`、`No Accounts`，已有 wildcard profile 也不包含该 entitlement。账号标识已打码，日志为 `build/ios-default-profile-refresh.log`。当时没有成功更新 profile；不能将这一历史结果推定为用户现在必须重新登录。

为独立检查标准系统内存预算下的真实设备行为，另用任务临时的空 entitlement 文件覆盖构建参数，未修改项目 Release entitlement，也未降低模型预算或校验。这份诊断 Release 构建与 `codesign --verify --deep --strict` 均通过，6 个 FFI 符号保留；签名为 development provisioning，`get-task-allow=true`，并非分发签名。提取的实际签名确认 increased-memory-limit=false、debugging-memory-limit=false；因此即使模型 smoke 成功，也不能代替默认配置的发布验收。

诊断构建命令（在 `example` 目录执行）：

```sh
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos \
  -destination 'id=00008122-001A243136BB801C' \
  -derivedDataPath build/ios -clonedSourcePackagesDirPath build/macos/SourcePackages \
  -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO DEBUG_INFORMATION_FORMAT=dwarf \
  CODE_SIGN_ENTITLEMENTS=/Users/gao/Workspace/gsmlg-app/lib_mlx/build/ios-standard-memory.entitlements \
  -quiet build
```

实际签名记录在 `build/ios-final-signed-entitlements.plist`。两台设备均安装了此诊断 app 与固定模型。iPad UDID 为 `00008122-001A243136BB801C`，iPhone 为 `00008030-001A74A62ED9802E`。iPad 的独立启动被系统明确以 Locked 拒绝；iPhone 的独立启动成功，但未取得本次 run ID 的 smoke 报告，不能将安装或启动计为推理通过。

两台设备最初均未产生进度或结果文件。DDI、Release Flutter engine、AOT 入口及 run ID 的检查未发现异常；LLDB/Instruments 没有取得稳定栈，已停止这些无结果尝试。用户随后解锁 iPad，独立启动成功，但报告依旧缺失。Console 的设备日志给出了确定证据：Impeller/Metal 已初始化，Dart 在 `smoke.dart:69` 报 `PathNotFoundException`，写入位置是应用容器的 `tmp/Documents/lib_mlx-smoke-report.json`。

根因是独立 iOS 启动没有提供 `HOME`，示例把 `Directory.systemTemp` 当成应用根目录。第一次写进度时已经失败，catch 后写报告又在相同错误目录失败，尚未进入模型加载。这不是设备内存或 MLX 推理失败的证据。两个真机入口现在均使用 Flutter 官方 `path_provider` 的平台 Documents API，不再依赖 `HOME`；依赖固定并记录在示例锁文件。原生日志摘录见 `build/ipad-startup-root-cause.txt`。

修复后的标准内存诊断 Release 已通过实际 iOS 消费工程构建、严格签名检查，`lib-mlx.framework` 的导出表保留全部 6 个 FFI 符号；日志为 `build/ios-documents-build.log`。该次源码摘要为 `87854edbe36f6d34765506ca5dc18cc26ef5920e4b103c7f05086bc498d28cd1`，run ID 为 `local-ios-documents-d7a6fc6f-e10a-44ad-b62e-60b66e1a444c`。此时 iPad 的实时锁状态为 `passcodeRequired=true`，用户也说明暂时无法解锁，因此尚未取得新版模型报告；没有将这次编译通过计为真机推理通过。

这份签名 app 在早先默认签名重试前以 APFS clone 保留于 `build/ios-documents-standard.app`，再次严格验签后安装到 iPad，已有模型保留。当时默认重试失败时 Xcode 清除了 Products 中的旧签名，保存的 clone 是该轮有效诊断产物。iPhone 当时无法建立可信连接/使用断言（CoreDevice 4016），该轮新版 app 尚未安装到 iPhone；后续默认配置的成功产物和安装见下文。

### 默认签名复核：阻断已解除

2026-10-27 晚间复核确认，GUI 与命令行使用同一份 Xcode 27.1，Team、bundle ID 和自动签名选择一致，没有硬编码旧 profile。Xcode 的 Release Signing & Capabilities 页面已选中本项目专用的 `iOS Team Provisioning Profile: app.gsmlg.libMlxExample`，明确包含 Increased Memory Limit 和两台测试设备；读取实际 profile 也确认该 entitlement 为布尔 true。因此没有继续要求用户重新登录，也没有修改工程签名配置或删除 entitlement。打开 GUI 产生的格式/objectVersion 自动改写经语义比较后撤回，构建使用原提交的工程设置。

在 `example` 目录执行默认配置：

```sh
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios -clonedSourcePackagesDirPath build/macos/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO DEBUG_INFORMATION_FORMAT=dwarf \
  -quiet build
```

实际退出 **0**，耗时 **373.01 秒**，没有账户或 profile 错误。`codesign --verify --deep --strict` 通过；实际签名与 embedded profile 均包含 increased-memory-limit=true、debugging-memory-limit=false，AOT framework 和全部 6 个 FFI 导出符号保留。签名仍为 development provisioning、get-task-allow=true，不是分发签名。构建日志为 `build/ios-default-signing-recheck.log`，签名和 profile 检查记录为 `build/ios-default-signing-recheck-evidence.json`、`build/ios-default-signing-recheck-entitlements.plist`。

这份默认配置产物已成功安装到 iPhone 11 和 iPad Air，分别记录于 `build/iphone-default-release-install.json`、`build/ipad-default-release-install.json`。iPad 此时仍为 passcodeRequired=true，不能计为运行通过。iPhone 已解锁；本机固定快照重新通过校验后复制到其应用 Documents，再使用 `devicectl device process launch` 独立启动成功，没有附加调试器。安装或启动本身不作为真实推理通过的证据。

iPhone 这次已写出 `Documents/lib_mlx-smoke-progress.json` 和结果文件，说明之前的 Documents 路径错误不再阻止记录。进度到达 `loading_pinned_model`，最终报告为 **failed**：`MlxLifecycleException(load_cancelled): Model loading was cancelled before a resident handle could be published.`，尚未进入 ready 或真实生成。报告的 run ID 与构建中保留的 `local-ios-documents-d7a6fc6f-e10a-44ad-b62e-60b66e1a444c` 一致，源码摘要仍为 `87854edbe36f6d34765506ca5dc18cc26ef5920e4b103c7f05086bc498d28cd1`。原始结果、带实际签名注记的结果及进度分别保存在 `build/iphone-default-release-report-raw.json`、`build/iphone-default-release-report.json`、`build/iphone-default-release-progress.json`。

该次运行后设备锁状态仍为 passcodeRequired=false，Runner 进程仍存在，当时尚不足以确定取消原因。设备日志采集要求管理员权限，Console 又受本机锁屏阻塞，因此改为在每次加载的状态所有者中保留首个取消来源。没有根据旧日志修改账户或降低准入；后续项目内存缺陷的复现与修复如下。

### 加载校验内存：项目缺陷与修复

取消诊断现在区分 `application_inactive`、`memory_pressure`、`caller_cancelled` 和后端自行抛出的取消。首个原因随同一加载操作保留，后续通知不能覆盖它；协作取消与忽略取消后被拒绝发布的路径都有测试。新增断言在修改前实际出现 5 次预期失败；修改后 9 项生命周期测试通过。调用方取消测试还显式等待取消到达受控 loader 后才释放结果，避免把另一条有效终止路径误当成失败。

默认 iOS Release 在没有修改签名配置的情况下重新构建，退出 0、耗时 35.77 秒。iPhone 独立启动后的本次错误明确为 `load_cancelled; source=memory_pressure`，确认触发源是 UIKit 内存警告，而不是 Xcode 账户。报告为 `build/iphone-cancellation-report-raw.json`，run ID `local-ios-cancellation-5417471c-3c68-4d5b-8313-18ecd4c2a777`，该诊断版本摘要为 `753ea3535ad9cb2acbbbaaa16ba4b8c9b7cf6aad637222708ef4c64ca5ff2e2a`。

随后隔离验证发现 `FileHandle.read(upToCount:)` 的 Foundation 缓冲会被调用线程的 autorelease pool 保留。即使逐次只读 8 MiB，原循环仍会累积整个 checkpoint。对真实 3,550,670,554 B 权重的单独实验中，物理占用由 2,163,240 B 增至 3,561,622,552 B；只增加每块的 autorelease pool 后，采样峰值为 12,993,088 B，SHA-256 完全一致。日志为 `build/model-hash-unpooled.log`、`build/model-hash-pooled.log`。这是 Mac 上隔离校验的测量，不是 iPhone 峰值。

生产 `ModelAssets.validate` 现在在每块读取、取消检查和哈希更新完成后立即排空该块的 pool，保持全部大小/revision/哈希校验。直接调用真实生产校验器的回归测试在修改前以增长 **3,592,210,976 B** 失败，修改后增长 **11,206,680 B**，低于 64 MiB 断言。日志为 `build/asset-memory-red.log`、`build/asset-memory-green-real-model.log`；真实模型工作流也会执行这项测试，未设置资产的快速 CI 明确跳过。

内存修复后的默认 iOS Release 再次构建退出 0，耗时 **34.58 秒**，严格验签通过，实际 increased-memory-limit=true。iPhone 已安装并在解锁状态独立运行；文件校验完成后，预检明确返回 **insufficient_memory**：additional=3,818,787,782 B、process_available=2,392,062,136 B、process_footprint=69,994,312 B、metal_allocated=45,842,432 B、metal_recommended=2,863,316,992 B、mlx_active=0、mlx_cap=3,836,583,116 B。进程占用是预检时采样，不是峰值；各预算指标不能相加。没有降低预留或绕过 Metal 上限，所以这台 4 GB iPhone 的当前 4K 配置不算推理通过。

最新 iPhone 结果为 `build/iphone-asset-fix-report.json`，run ID `local-ios-asset-fix-c76ccd33-ff24-44e6-b09c-37c4780f56f2`，摘要为 `32bfbc27ca7839a67d71f14bea63afc5c91e77815b8f825339668df3053abc41`；原始报告、实际签名 entitlement、构建和安装分别保存在同名前缀文件中。单平台 gate 正确以退出 1 拒绝 failed 状态。测试结束后仅终止本次 iPhone 进程，保留安装和模型。

再次读取 iPad 状态仍为 passcodeRequired=true。尝试安装同一最新修复产物时，CoreDevice 返回 4000 / tunnel interrupted / timeout，记录为 `build/ipad-asset-fix-install.json`。没有重复无证据重试，也没有将较早默认版本的安装成功写成最新版推理通过。解除条件是设备解锁并恢复可信连接，再执行已有的真机入口；无需重新登录已验证可用的 Xcode 账户。

前后台真机入口是现有工程的 `example/lib/lifecycle_smoke.dart`，无需新建宿主：签名 Release 构建此入口后，等 `Documents/lib_mlx-lifecycle-ready.json` 出现，再将 Settings 前置并重新激活原进程（恢复时不要 `--terminate-existing`）。它校验中断、恢复后的安全停止状态、重新启动、真实生成和卸载，结果写入 `Documents/lib_mlx-lifecycle-report.json`。本轮尚未取得这份物理设备报告。

普通宿主 `swift build`、模拟器编译、mock 协议结果都不算真机推理。真实设备入口为 `tool/device_smoke.sh UDID MODEL_PATH 4096`；它验证资产、构建签名 Release、安装、复制资产、不附加调试器独立启动，并收集带本次 run ID 和源码摘要的报告。macOS 使用现有 Flutter example 的同一 smoke 入口及 app container 内的资产。

macOS Flutter Release 实际执行了 `flutter build macos --release --config-only --no-pub -t lib/smoke.dart`，再使用 `xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/macos -clonedSourcePackagesDirPath build/macos/SourcePackages -jobs 2 ARCHS=arm64 EXCLUDED_ARCHS=x86_64 COMPILER_INDEX_STORE_ENABLE=NO DEBUG_INFORMATION_FORMAT=dwarf -quiet build`。全局架构参数也约束 SwiftPM 依赖，避免额外编译 Intel 产物。使用 `codesign --verify --deep --strict` 验证，通过 `open -n` 启动，没有 Flutter debugger。资产在 app container 内，校验后使用；运行结束仅关闭本次启动的 app。

目录修复前的一次报告为 `build/macos-final-report.json`，run ID `local-macos-fa7932da-905a-417c-a8bd-10964a8e6dc5`，源码摘要 `22ae2272e874251c05967883ee1f9f82396bcf716111d0bcefca9be6cb3be68d`。该报告在当时通过单平台 release gate：实际输入 3,986、输出 2 token，prefill 1.324 秒；thinking 78 个增量，首个 94 ms、总计 903 ms。过程包含缺失路径拒绝、多轮/instructions、真实 usage、取消、停止/重启、卸载及再次加载。

该次 Release 的进程物理占用采样为 2,890,157,680 B；MLX active 2,604,110,566 B、peak 3,550,531,684 B、cache 0 B。日志分别为 `build/macos-release-build-completion.log` 与 `build/macos-final-signing.txt`。上游 Metal 编译器有 C++17 扩展警告，未修改或抑制；构建退出 0。签名种类为本地 ad-hoc。中途一次构建因磁盘写满失败（`build/macos-release-disk-exhausted.log`），清理本任务已完成检查产生的中间产物后重跑通过；没有清理共享缓存或其他项目。

目录修复后再次构建 macOS Flutter Release、严格验签并以 `open -n` 独立启动，完整真实模型链路再次通过，测试结束后仅关闭本次 app。该次报告为 `build/macos-documents-report.json`，run ID `local-macos-documents-69623d7a-6b78-4080-9fa3-324e551448c3`，源码摘要 `87854edbe36f6d34765506ca5dc18cc26ef5920e4b103c7f05086bc498d28cd1`。13 个检查均完成，实际 4K 探针输入 3,986、输出 2 token，prefill 1.307 秒；thinking 78 个增量，首个 93 ms、总计 899 ms。进程物理占用采样为 2,880,245,384 B；MLX active 2,604,110,606 B、peak 3,550,531,684 B、cache 40 B。这些指标仍不相加，也不把采样值当成进程峰值。构建和签名记录分别为 `build/macos-documents-build.log`、`build/macos-documents-signing.txt`。

资产内存修复后，macOS Flutter Release 再次构建退出 0，耗时 **37.75 秒**；严格验签、ad-hoc 本地签名、`open -n` 独立启动及 13 项真实公开链路检查全部通过。最新报告为 `build/macos-asset-fix-report.json`，run ID `local-macos-asset-fix-1c42d32d-f804-4b74-8f30-a0028a3bb931`，与最新 iPhone 产物共用摘要 `32bfbc27ca7839a67d71f14bea63afc5c91e77815b8f825339668df3053abc41`。4K 探针输入 3,986、输出 2 token，prefill 1.301 秒；thinking 78 个增量，首个 92 ms、总计 899 ms。进程物理占用采样为 2,881,228,400 B，MLX active=2,604,110,606 B、peak=3,550,531,684 B、cache=0 B。报告完成后仅关闭本次 Mac app；没有将功能上的重复卸载成功当作分配器恢复通过。

## CI、发布门禁与交付

快速 CI 运行 Dart/Swift 协议、核心和生命周期测试；Apple job 检查 Release FFI 导出，并编译实际 Flutter macOS/iOS Release 消费工程。宿主 CI 编译使用显式 unsigned 配置，不计运行通过。手动 self-hosted workflow 执行签名、独立启动的真实模型测试，并增加真实资产内存回归及原生真实推理测试；不新增 tvOS 专用 job。

初始实现提交 `233840a68e5f80721756bf6a7628ed586d9f623c` 的 [远端 CI 40412656694](https://github.com/gsmlg-app/lib_mlx/actions/runs/40412656694) 全部通过，包括 Dart、受控 Swift、Release FFI、公开 Dart→Swift 协议集成，以及 macOS/iOS Flutter Release 实际消费工程编译。后续目录修复单独提交；这条旧运行不能代替该后续提交的 CI。

目录修复提交 `935502816eb58a352baf312f0b4388294e7c3a5e` 的 [远端 CI 40420777235](https://github.com/gsmlg-app/lib_mlx/actions/runs/40420777235) 也已全部通过，包括两种 Flutter Release 消费工程编译。新增资源恢复探针及门禁的提交 `583cf09504caa23a95ceabc54c6ffddd080743a1` 的 [远端 CI 40429043531](https://github.com/gsmlg-app/lib_mlx/actions/runs/40429043531) 已全部通过；这些快速 CI 成功不表示真实模型资源恢复通过。

Release/publish/first-publish 必须取得同一 commit 的成功模型 workflow 报告，验证当前源码摘要（包含宿主配置与锁文件）、固定模型 revision、真实 token/计时、接近上下文窗口的输入、thinking、取消/卸载及签名。iOS 报告的 Increased Memory Limit 必须来自实际签名且严格为布尔 true；标准内存诊断构建不能满足此门禁。没有两平台合格报告时，门禁拒绝发布。

本轮版本为 `0.2.0-dev.1`，不创建发布 tag 或发布包：默认 iOS 签名阻断已解除，但尚未取得合格真机模型报告，资源恢复也有已复现的上游阻断。新的 real-model macOS job 构建原生 SwiftPM Release 动态库，用其 macOS Metal 资源运行恢复探针；这与独立启动的 Flutter Release 验收分别记录。恢复失败会阻断工作流；发布流程只接受同一 commit 的成功 real-model workflow。代码交付以 `main` 上本轮提交为准；本地记录不等同于远端 CI、商店签名、公证或正式发布。

较早 Documents 修复报告在当时通过单平台 macOS gate，日志为 `build/full-release-gate-documents.log`；该旧摘要不代替当前源码验证。最新 `python3 tool/release_gate.py --platform macos --run-id local-macos-asset-fix-1c42d32d-f804-4b74-8f30-a0028a3bb931 build/macos-asset-fix-report.json` 退出 **0**。通过 `LIB_MLX_MACOS_REPORT=build/macos-asset-fix-report.json LIB_MLX_IOS_REPORT=build/iphone-asset-fix-report.json python3 tool/release_gate.py` 执行完整 gate 时退出 **1**，明确拒绝 iOS 的 failed 状态，日志为 `build/full-release-gate-asset-fix.log`。签名成功和预算拒绝都没有被当成推理成功，发布仍被阻断。
