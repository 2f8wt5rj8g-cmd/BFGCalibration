# 自签与安装

CI 默认产出**未签名**的 `BFGCalibration-unsigned.ipa`。签名有两条路，取决于你有没有付费开发者账号。

---

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
