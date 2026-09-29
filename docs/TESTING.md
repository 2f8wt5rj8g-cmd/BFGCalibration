# 测试流程与方法

四层验证，从快到慢、从便宜到贵。**每一层能抓到的东西不同，不能互相替代**——尤其最后一层。

---

## 第 0 层：本机类型检查（秒级，无需 Mac）

iOS 层用的 CoreBluetooth / WebKit / UIKit / SwiftUI / Security 在开源 Swift 工具链里不存在，`Tools/AppleStubs/` 声明了用到的 API 子集，让这些代码能在 Linux 上真正编译。

```bash
export PATH=/opt/swift/usr/bin:$PATH
export LD_LIBRARY_PATH=/opt/swift/usr/lib/swift/linux:$LD_LIBRARY_PATH
Tools/typecheck-ios.sh
```

**能抓到**：类型错误、拼写错误、协议实现不符、缺 import
**抓不到**：运行时行为、构建配置、平台差异

> 实际战绩：抓出 `BfgBleClient` 缺 `import Security`、`PrototypeWebView` 缺 `import Foundation`——这两个在 macOS 上同样编译失败。

---

## 第 1 层：核心逻辑单测（秒级）

```bash
swift test
```

92 个测试：加密（NIST/RFC 标准向量）、帧格式（字节级）、写入风控策略、通信模式识别、容量解析、写入类型选型与配对前置校验。

**能抓到**：协议逻辑错误、加密实现错误
**抓不到**：BLE 传输、UI、构建配置

> 实际战绩：NIST 向量抓出 `AES128.mul2` 缺掩码导致 `UInt8` 溢出崩溃——**上层协议测试完全发现不了**。

---

## 第 2 层：UI 渲染（秒级，无需设备）

界面是单文件 HTML，屏幕切换走全局的 `window.bfgNativeGo(name)`——**iOS 里 WKWebView 调的就是这个入口**。所以无头 Chrome 注入一小段脚本就能把每个界面渲染成图片。

```bash
# 全部 14 个界面 → build/screenshots/
Tools/render-screens.sh

# 指定尺寸（试不同机型）
Tools/render-screens.sh /tmp/shots 430 932      # iPhone 15 Pro Max
Tools/render-screens.sh /tmp/shots 375 667      # iPhone SE
```

**前提**：装了中文字体，否则中文渲染成方框（本机：`apt-get install fonts-noto-cjk`）

**能抓到**：布局错乱、文字溢出、间距/配色问题、安全区处理不当
**抓不到**：真机 WebView 的差异、真实数据下的表现

> 界面用占位值渲染（没有原生层喂数据），验证的是**布局与样式**，不是数据流。

### 手动渲染单个界面

```bash
python3 - <<'PY'
src = open('ios/BFGCalibration/Resources/bfg-calibration-flow.html', encoding='utf-8').read()
inject = '<script>window.addEventListener("load",()=>window.bfgNativeGo("review"))</script>'
open('/tmp/one.html','w',encoding='utf-8').write(src.replace('</body>', inject+'</body>'))
PY
google-chrome --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
  --virtual-time-budget=4000 --window-size=390,844 \
  --screenshot=/tmp/one.png file:///tmp/one.html
```

可选屏幕名见 `render-screens.sh` 里的 `SCREENS` 数组。

---

## 第 3 层：iOS 构建 + 配置断言（CI，约 2 分钟）

推到 GitHub 自动触发 `.github/workflows/ios.yml`。本地无需 Mac。

**CI 做四件事**：
1. `swift test`（第 1 层，在 macOS 上复跑，验证无平台差异）
2. `xcodegen` 生成工程
3. **断言源 `Info.plist` 含 `UILaunchScreen` / `NSBluetoothAlwaysUsageDescription` / `UIBackgroundModes`**
4. **断言构建产物内的 `Info.plist` 含同样两个键**
5. 产出未签名 IPA

**为什么要断言 plist**：XcodeGen 的 `info:` 键会**生成并覆盖**手写 plist，静默删掉这两项——

- 缺 `UILaunchScreen` → iOS 以旧版兼容模式渲染 → **应用只占一部分屏幕（半屏）**
- 缺 `NSBluetoothAlwaysUsageDescription` → **访问蓝牙时被系统直接杀死**

这类问题代码检查永远抓不到，只能靠对产物做断言。**这道断言已挡住过一次真实回归。**

**能抓到**：编译错误、链接错误、签名配置、构建配置、产物完整性
**抓不到**：运行时行为、BLE 通信、UI 在真机的观感

```bash
# 看 CI 状态
curl -s "https://api.github.com/repos/QL2007na-hue/BFGCalibration/actions/runs?per_page=1" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['workflow_runs'][0]; print(r['status'], r['conclusion'])"
```

---

## 第 4 层：真机 + 真车（必须人工，无法自动化）

**前三层再绿，也替代不了这一层。** BLE 射频、握手时序、车端行为都只有真车能验。

### 装机

见 `docs/IOS_SIGNING.md`。纯 Linux 环境走 TestFlight（需 $99/年账号）。

### 首次启动必查

| 检查项 | 预期 | 失败意味着 |
|---|---|---|
| 界面是否**满屏** | 铺满整个屏幕，无黑边/留白 | 启动屏配置仍有问题 |
| 标题栏是否避开刘海 | 标题不被灵动岛/刘海遮挡 | `viewport-fit=cover` 或安全区 CSS 失效 |
| 底部导航是否避开 Home 条 | 不被小白条压住 | 同上 |
| 首次点蓝牙时是否弹权限框 | 弹「允许使用蓝牙」 | `NSBluetoothAlwaysUsageDescription` 缺失（会直接闪退） |

### BLE 测试顺序（务必按此顺序，写操作放最后）

1. **扫描** — 车辆唤醒后能否在列表里看到（SN 为 14 位设备名）
2. **配对** — 走「临时密钥配对」，车上按键确认，观察 60 秒窗口
3. **重连** — 杀掉 App 重开，验证钥匙串生效、**免按键**直连（这是 iOS 版相对 Android 版的改进点）
4. **只读** — 读电量/电压/容量/固件四项，与车辆实际显示比对
5. **写前快照** — 确认 `COMPARE_READ` 备份流程走通
6. **写入** — 最后一步。风控门槛（仪表 30 秒 / 计量 3 秒冷却）必须完整走完
7. **写后回读** — 确认只回读、不重写

### 出问题时抓什么

- **首选：App 内的「设置 → 导出诊断」**。落盘到「文件」App 的 BFGCalibration 目录，含连接状态、服务与特征发现、TX 特征的写入属性、协商写入长度、选用的写入类型、每次写入的结果、每次收包长度，以及协议层日志。**真车上失败时这个文件是唯一能定位断点的证据**，比 Xcode 控制台更全。
- **日志**：Xcode → Window → Devices and Simulators → 选设备 → Open Console
- **对照**：Android 版在同一台车上的行为是最强参照

### 已踩过的坑（真机实测记录）

| 现象 | 原因 | 状态 |
|---|---|---|
| 配对时车端毫无反应，手机一直转圈且不给原因 | 失败时只写 `errorMessage`、不离开进度页也不弹窗，页面永远停在转圈并回落到兜底文案 | 已修：失败一律路由到终止页/弹窗 |
| 同上 | iOS 传输层恒用 `.withResponse` 写入，而原版按 TX 特征属性优先选无应答写入；属性不符时 CoreBluetooth 会拒发整帧 | 已修：按属性选型（`BleWritePolicy`） |
| 状态与报错有时不更新 | 编排层在 BLE 队列上改 `state` 并调用主线程专属的 `WKWebView.evaluateJavaScript` | 已修：所有回调切主线程 |
| 未配对时去做只读扫描，报「AUTH无回复」 | 车端已有密钥槽、本机无凭据，AUTH 必然失败，但提示指向了车辆 | 已修：提前提示「请先配对」 |

---

## 快速回归清单

改完东西，按这个顺序跑，任何一层挂了就不要往下走：

```bash
# 1. 类型检查
Tools/typecheck-ios.sh

# 2. 核心单测
swift test

# 3. UI 渲染（看截图）
Tools/render-screens.sh

# 4. 推到 GitHub 看 CI 绿灯
git push
```

全绿之后再上真车。
