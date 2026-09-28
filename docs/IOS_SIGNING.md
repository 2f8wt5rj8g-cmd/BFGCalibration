# 构建、自签与安装

---

## 0. 先解决「没有 Mac 怎么编译」

开发机是 Linux，无法编译 iOS 层。以下是可行路径，按成本排序：

| 方案 | 免费额度 | 超出后单价 | 备注 |
|---|---|---|---|
| **GitHub Actions（公开仓库）** | **macOS 分钟无限免费** | — | 非试用额度，长期有效。**首选** |
| GitHub Actions（私有仓库） | ~200 等效 macOS 分钟/月 | $0.062/min | 公开源码不可接受时用这个 |
| Codemagic | 500 macOS M2 分钟/月 | $0.095/min | 仅个人账号，不含 Teams |
| Expo EAS | 15 次 iOS 构建/月 | — | 适合托管式项目，本项目用不上 |
| MacInCloud / MacStadium 等云 Mac | — | €2.64/24h 起 | 需要交互式 Xcode 时才值得 |

**注意**：macOS runner 的计费倍数约为 Linux 的 10.3 倍。公开仓库不受影响（无限），私有仓库要按此换算免费额度。

本仓库的 `.github/workflows/ios.yml` 已按此配置，推到 GitHub 即可用。

---

## 0.1 装到 iPhone 上需要签名

编译免费，但**安装到真机必须有签名**：

| 路径 | 成本 | 纯 Linux 可用？ |
|---|---|---|
| 免费 Apple ID + AltStore/Sideloadly | 免费（证书 7 天） | ❌ 签名工具需 Windows/Mac |
| **付费开发者账号 + TestFlight** | **$99/年** | ✅ **全程无需 Mac** |
| 付费开发者账号 + Ad Hoc | $99/年 | 需要 Mac 或 Diawi 类服务 |

纯 Linux 环境下，**TestFlight 是唯一无需 Mac 的安装路径**，这 $99/年 无法绕过。

> 另有 `pymobiledevice3` 等纯 Python 侧载工具方向，涉及 anisette 等环节，**未经验证**，不作为建议。

---

## 1. 路线 A：免费 Apple ID（7 天有效期）

## 路线 A：免费 Apple ID（7 天有效期）

不需要 Mac，但需要一台能运行签名工具的机器。

1. 从 GitHub Actions 下载 `BFGCalibration-unsigned.ipa`
2. 用 AltStore 或 Sideloadly 签名并安装到 iPhone
   - 需要一个可用的 Apple ID（免费账号即可）
   - 证书有效期 7 天，到期需重新签名
   - 免费账号同时最多 3 个自签 App

**注意**：这类工具通常需要 Windows 或 macOS 主机来运行签名服务端；纯 Linux 环境无法完成。如果你只有 Linux，走路线 B。

---

## 路线 B：付费开发者账号（$99/年）—— 推荐

可以完全在 CI 内完成，不需要本机装任何工具。

### 1. 准备签名材料

在 Apple Developer 后台：

1. **创建 App ID**
   - Identifier: `com.bfgtools.calibration.imported`
   - 勾选能力：**Bluetooth**（无需勾选其他）

2. **创建 Ad Hoc 描述文件**
   - 类型选 Ad Hoc
   - 关联上面的 App ID
   - **必须把目标 iPhone 的 UDID 加进去**（Xcode → Window → Devices，或 developer.apple.com 手动添加）

3. **导出证书为 .p12**
   - 钥匙串访问 → 导出证书 → 设一个密码

### 2. 转成 base64

```bash
# 证书
base64 -i certificate.p12 | pbcopy      # macOS
base64 -w0 certificate.p12 > cert.txt   # Linux

# 描述文件
base64 -i profile.mobileprovision > profile.txt
```

### 3. 配置 GitHub Secrets

仓库 → Settings → Secrets and variables → Actions，添加：

| Secret | 内容 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `.p12` 的 base64 |
| `P12_PASSWORD` | 导出 .p12 时设的密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `KEYCHAIN_PASSWORD` | 随便一个临时密码（CI 内部用） |
| `APPLE_TEAM_ID` | 10 位团队 ID（Developer 后台右上角） |

配置齐后，CI 会自动多产出一个 `BFGCalibration-signed.ipa`。

### 4. 安装到 iPhone

- **Apple Configurator 2**（Mac）直接拖入
- 或 **Diawi** / **TestFlight**（后者需改用 App Store Connect 上传流程）
- 或 `xcrun devicectl device install app`（Xcode 15+）

---

## 为什么不走 App Store

这个工具会向车辆控制器写入参数，并且需要读取车辆 BLE 配对凭据。无论技术实现如何，这类应用**基本不可能通过 App Store 审核**（Guideline 2.5.1 关于使用非公开 API，以及 5.2.5 关于车辆控制）。

自签 / Ad Hoc / TestFlight 企业内部测试是现实可行的路径。
