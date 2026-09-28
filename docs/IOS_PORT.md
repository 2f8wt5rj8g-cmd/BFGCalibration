# BFG电量校准 — iOS 移植设计

来源工程：`SourceCode-v5.0.35`（Android，1202 文件 / 9.5 MB）
本仓库：`/root/bfg-ios`

---

## 1. 结论摘要

**「全面移植」不可行，但不是因为难度——是平台层面不允许。**

按代码量计，原工程约 **60% 在 iOS 上没有任何实现路径**：

| Android 能力 | 实现规模 | iOS 现状 | 处置 |
|---|---|---|---|
| BlackBox 虚拟化（`Bcore`） | 285 Java + C++ native | iOS 无 ART 运行时、无 Binder、禁止 hook 系统库、禁止动态加载第三方代码 | **整体删除** |
| 虚拟运行「九号出行」APK | `blackbox-gallery-stub` + 宿主 | iOS 沙箱不允许运行未安装的第三方程序 | **整体删除** |
| Root 直读九号数据库（`RootDb`） | 422 行 | iOS 无 root、无 `su` | **整体删除** |
| 跨 App 读私有数据库（`VmDbBridge`） | 93 行 + Provider | iOS 容器隔离，系统级禁止 | **整体删除** |

**但真正有价值的部分可以完整移植**——关键在于一个已验证的事实：

> **配对流程是自足的。** App 用 `SecureRandom` 现场生成 32 字节密钥，经 `SET_PWD` 写给车端，车端按键确认。握手密钥只由硬编码常量 `DATA_BASIC` + 车辆公开广播的 SN 派生。九号数据库里的 `password` **只是「跳过按键」的捷径，不是功能依赖。**

因此凭据获取那一半**不需要移植，直接砍掉**即可——iOS 版本改用系统钥匙串保存自己协商的密钥，反而比 Android 版更好（Android 版密钥仅存内存，冷启动即失效）。

---

## 2. 移植后的分层

```
┌─ BFGCore（Swift Package，已在 Linux 上验证）
│    加密：Encryption2, AES128, SHA1, Hex
│    协议：NinebotFrame（帧构造/解析）
│    策略：13 个纯逻辑类（写入风控、模式识别、容量解析…）
│
└─ BFGCalibration（iOS App，需 macOS 编译）
     传输：BleTransport（CoreBluetooth）
     状态机：BfgBleClient
     凭据：KeychainCredentialStore   ← 替代 RootDb / VmDbBridge
     界面：PrototypeWebView（WKWebView 复用原 HTML，零改动）
```

---

## 3. 验证状态（务必看清）

| 层 | 状态 | 依据 |
|---|---|---|
| 加密 / 协议 / 策略 | ✅ **已验证** | 48 个测试在 Linux 上通过；AES 用 NIST FIPS-197 与 SP 800-38A 向量，SHA-1 用 RFC 3174 与 FIPS 180-4 向量 |
| 帧格式 | ✅ **已验证** | 字节级断言，与 Android 逐字段比对 |
| iOS App 层（CoreBluetooth / WKWebView / Keychain） | ⚠️ **仅编译验证** | 本机无 macOS，无法编译。由 GitHub Actions 的 macOS runner 编译 |
| 真机 BLE 通信 | ❌ **未验证** | 需要真车 + 真机，无法用任何自动化手段替代 |

### 移植过程中被标准向量抓到的一个真实缺陷

`AES128.mul2` 最初写作：

```swift
return shifted & 0x100 != 0 ? UInt8(shifted ^ 0x1B) : UInt8(shifted)
```

当 `shifted == 0x100` 时，`0x100 ^ 0x1B = 0x11B = 283`，超出 `UInt8` 范围 → **运行时崩溃**。

**协议层的移植测试完全发现不了这个错误**（它们只调用上层接口）。只有 NIST 标准向量能暴露它。这正是为什么加密原语必须用权威向量独立验证，而不能只靠「上面的测试都过了」。

---

## 4. 三个必须重新设计的点（CoreBluetooth 硬限制）

这三点不是选择，是 iOS 平台强制：

### 4.1 拿不到 MAC 地址
CoreBluetooth **从不暴露外设 MAC**，只给 `CBPeripheral.identifier`（每次安装重装会变）。

而 Android 版全程以 MAC 为主键（`isExpectedDevice` 直接比对 `device.getAddress()`）。

**处置**：改用 **14 位 SN 作为设备身份主键**。SN 就广播在 BLE 设备名里，公开可得，而且比 MAC 更稳定。钥匙串也以 SN 为键。

### 4.2 没有 `requestMtu`
Android 显式 `requestMtu(512)`；iOS 由系统协商，**无对应 API**。

**处置**：用 `peripheral.maximumWriteValueLength(for:)` 取实际上限，写入按此分片（`BleTransport.write`）。现有帧最长 45 字节，iOS 最小保证 20 字节——**当前安全**，但分片逻辑保证未来出现大帧时不会被静默截断。

### 4.3 拿不到原始广播字节
Android 用 `getScanRecord().getBytes()` 在原始广播里搜索 SN 字节。iOS 只给**已解析**的 `advertisementData` 字典。

**处置**：改为匹配广播名（`CBAdvertisementDataLocalNameKey`），正则 `^[A-Za-z0-9]{14}$`。

### 附带差异

| 项 | Android | iOS |
|---|---|---|
| 开通知 | 手写 CCCD 描述符 | `setNotifyValue(true, for:)` 自动完成 |
| 定位权限 | 扫 BLE 需 `ACCESS_FINE_LOCATION` | **不需要** |
| 扫描模式 | `SCAN_MODE_LOW_LATENCY` | 无对应，系统决定 |
| 后台 | 前台扫描 | 需 `bluetooth-central` 后台模式；后台扫描须带 ServiceUUID 过滤 |
| 常量时间比较 | `MessageDigest.isEqual` | 手写 `constantTimeEquals`（Swift `==` 不是常量时间） |
| 密钥生成 | `SecureRandom` | `SecRandomCopyBytes` |

---

## 5. 凭据策略变更（本移植最重要的设计决定）

| | Android | iOS |
|---|---|---|
| 密钥来源 | 读九号 App 数据库（root 或虚拟容器） | **本 App 自己配对协商** |
| 存储 | 仅进程内存 → 冷启动失效 | **系统钥匙串**（`WhenUnlockedThisDeviceOnly`） |
| 免按键重连 | 靠读九号 DB 的已有密钥 | 靠钥匙串里自己存的密钥 |
| 是否需要 root | 是（或虚拟化容器） | **否** |
| 是否影响九号官方 App | 是（共用同一密钥槽） | **否** |

**这是纯改善**：iOS 版不碰任何其他 App 的数据，却能做到 Android 版做不到的「配对一次、跨启动免按键」。

副作用仍然存在且必须在 UI 说明：新配对会覆盖车端**单一**的 BLE 密码槽，因此九号官方 App 可能需要重新配对。

---

## 6. 协议参考

帧格式：`5A A5 LEN SRC DST CMD INDEX DATA...`
`LEN` 仅指数据段长度。`CMD 0x02` = 写需回执，`0x01` = 读。

| 方向 | 端口 |
|---|---|
| 手机/客户端 | `0x3E` |
| BLE 板 | `0x04` |
| BFG 计量模块 | `0x10` |
| 仪表 DIS | `0x01` |
| 中控 | `0x09` |

GATT（Nordic UART 风格）：

| 用途 | UUID |
|---|---|
| Service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| TX（写） | `6e400002-...` |
| RX（通知） | `6e400003-...` |

关键固定帧（全部有测试断言）：

| 用途 | 帧 |
|---|---|
| PRE_COMM | `5AA5003E045B00` |
| 读 Profile | `5AA5013E10010001` |
| 读 SOC | `5AA5013E10010201` |
| 读容量 | `5AA5013E10011C02` |
| 读仪表配置 0x92 | `5AA5013E01019202` |
| SET_PWD 头 | `5AA5203E045C00` + 32B 密钥 |
| AUTH 头 | `5AA50E3E045D00` + 14B SN |

---

## 7. 构建与部署（方案 1）

iOS 层无法在 Linux 上编译，因此用 **GitHub Actions 的 macOS runner 作为验证环境**。

```
本机(Linux) 写代码 → git push → GitHub Actions (macOS)
                                    ├─ swift test        （核心层，与 Linux 同源）
                                    ├─ xcodegen + xcodebuild （iOS 层编译）
                                    └─ 产出 .ipa
```

`.github/workflows/ios.yml` 提供两个产物：

1. **`BFGCalibration-unsigned.ipa`** — 始终产出，交给你本地自签工具
2. **`BFGCalibration-signed.ipa`** — 仅当仓库配置了签名 secrets 时产出（见 `docs/IOS_SIGNING.md`）

### 为什么用 XcodeGen 而不是提交 `.xcodeproj`

`.xcodeproj` 是几千行不可读的 pbxproj，手写易错且会与源码漂移。`ios/project.yml` 只有 40 行，可 review、可 diff、不可能失同步。

---

## 8. 界面迁移

**几乎免费。** 原主界面是单文件、零外部资源、零 localStorage 的内联 HTML（68 KB）。

- 已复制到 `ios/BFGCalibration/Resources/`，**MD5 与 Android 版完全一致**（`31653d53...`）
- 桥接：Android 用 `addJavascriptInterface` 注入 `BfgNative` 对象；iOS 无对应 API，改用 `WKUserScript` 在文档开始注入一个**同名同形的 shim**：

```js
window.BfgNative = { action: (a, b) =>
  window.webkit.messageHandlers.BfgNative.postMessage({action: String(a), value: String(b ?? '')}) };
```

→ **HTML 一个字都不用改。** 反向 `evaluateJavascript` 与 `evaluateJavaScript` 本就是同一个调用。

只有一处小改进：`<meta viewport>` 建议补 `viewport-fit=cover`，否则 `env(safe-area-inset-*)` 在 iOS 上恒为 0。

**可整体丢弃**：`page_ninebot_*.xml`（5 个被 WebView 覆盖的死布局）、`ninebot_styles.xml` / `ninebot_dimens.xml` 设计系统、大部分 `ic_ninebot_*` drawable、以及全部 BlackBox 界面。

---

## 9. 风险清单

| 风险 | 等级 | 说明与缓解 |
|---|---|---|
| 真机 BLE 未验证 | **高** | 无真车无法验证。必须由你在真车上跑第一轮 |
| iOS 层未编译验证 | 中 | 由 CI 的 macOS runner 覆盖；首次运行大概率有编译错误需修 |
| 设备身份从 MAC 改为 SN | 中 | 架构级改动。已按 SN 实现，但真车广播名是否严格为 14 位 SN 需实测确认 |
| 后台/息屏断连 | 中 | 已声明 `bluetooth-central`；写入过程建议保持前台 |
| 与九号官方 App 互斥 | 低但需告知 | 新配对覆盖车端唯一密钥槽，UI 必须明确提示 |
| App Store 上架 | — | 此类工具几乎不可能过审。自签 / TestFlight 内部测试是现实路径 |

---

## 10. 剩余工作

已完成：
- [x] 核心层 14 个类移植 + 48 个测试在 Linux 通过
- [x] 帧层移植 + 字节级测试
- [x] iOS 层代码（CoreBluetooth / WKWebView / Keychain）
- [x] XcodeGen 工程配置 + CI 流水线
- [x] HTML 资源零改动复用

待办：
- [ ] 在 GitHub Actions 跑通首次编译（预计需修若干编译错误）
- [ ] 补齐写入流程的完整状态（`waitWriteAck` / `waitAfterProfile` / `waitAfterDis` 的回执处理仍是骨架）
- [ ] 容量兼容扫描（`CAPACITY_SCAN_COMPAT`）的重复探测循环
- [ ] 寄存器扫描（`registerScan`）的完整实现
- [ ] 真车联调
