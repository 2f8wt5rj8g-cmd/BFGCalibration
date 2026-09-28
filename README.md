# BFG电量校准 — iOS 移植

BFG电量校准的 iOS 版本。原工程是 Android 的第三方九号车辆电量校准工具。

**完整设计说明见 [`docs/IOS_PORT.md`](docs/IOS_PORT.md)**，自签与安装见 [`docs/IOS_SIGNING.md`](docs/IOS_SIGNING.md)。

---

## 这个移植做了什么、没做什么

原工程约 **60% 无法移植**——BlackBox 应用虚拟化、root 直读九号数据库、跨 App 读私有数据库，这些在 iOS 上不是「难」，是平台层面不存在实现路径。

**但核心价值 100% 保留**：BLE 配对、加密协议、寄存器读写、写入风控，以及整个界面。

关键事实是**配对流程本身是自足的**（现场生成密钥 + 车端按键确认），九号数据库只是「跳过按键」的捷径。所以凭据获取那一半直接砍掉，改用系统钥匙串保存本 App 自己协商的密钥。

| | Android | iOS |
|---|---|---|
| 凭据来源 | 读九号 App 数据库（root / 虚拟容器） | 本 App 自行配对协商 |
| 凭据存储 | 仅进程内存，冷启动失效 | 系统钥匙串，跨启动有效 |
| 需要 root | 是（或虚拟化容器） | 否 |
| 界面 | WebView 加载 HTML | WKWebView 加载同一份 HTML（已做 iOS 适配，见 `docs/IOS_PORT.md` §8） |

---

## 目录

```
Sources/BFGCore/         可移植核心（加密 / 协议 / 策略）
Tests/BFGCoreTests/      67 个测试
ios/BFGCalibration/      iOS 应用层（CoreBluetooth / WKWebView / Keychain）
ios/project.yml          XcodeGen 工程定义
.github/workflows/       macOS 构建流水线
docs/                    设计与签名文档
```

---

## 验证状态

| 层 | 状态 |
|---|---|
| 加密 / 协议 / 策略 | ✅ 67 个测试通过（AES 用 NIST 向量，SHA-1 用 RFC 3174 向量） |
| 帧格式 | ✅ 字节级断言 |
| iOS 应用层 | ✅ **类型检查通过**（`Tools/typecheck-ios.sh`）；行为验证在 CI 的 macOS runner |
| 真机 BLE | ❌ 未验证，需真车 + 真机 |

### 在 Linux 上做 iOS 类型检查

CoreBluetooth / WebKit / UIKit / SwiftUI / Security 在开源 Swift 工具链里不存在，所以本机无法编译 iOS 层。`Tools/AppleStubs/` 声明了用到的 Apple API 子集，让 iOS 源码能在 Linux 上**真正编译并类型检查**——这比 `swiftc -parse` 的语法解析强得多。

它已经抓出两个真实缺陷：`BfgBleClient` 缺 `import Security`、`PrototypeWebView` 缺 `import Foundation`（两者在 macOS 上同样会编译失败）。

```bash
Tools/typecheck-ios.sh
```

**局限**：桩的签名若与 Apple 实际不符会产生假通过，且不验证行为。**CI 的 macOS runner 仍是权威。**

### 在 Linux 上运行测试

```bash
# 需要 Swift 6.0 工具链
export PATH=/opt/swift/usr/bin:$PATH
export LD_LIBRARY_PATH=/opt/swift/usr/lib/swift/linux:$LD_LIBRARY_PATH
swift test
```

### 构建 iOS 应用

macOS 上：

```bash
brew install xcodegen
xcodegen generate --spec ios/project.yml
open ios/BFGCalibration.xcodeproj
```

或直接推到 GitHub，让 `.github/workflows/ios.yml` 在 macOS runner 上构建。

---

## 许可证

根目录 `LICENSE` 使用 Apache License 2.0。

原 Android 工程内含 BlackBox 等上游模块，各自版权与许可证需按其目录保留——**本移植已删除全部 BlackBox 相关代码**，因此不再继承其许可约束。
