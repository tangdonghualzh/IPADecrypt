# IPA 解密（IPADecrypt）

从 [iPadn 2.3.0](https://github.com/mengangs/ipadn) 里单独拆出的「本机 FairPlay IPA 解密」应用。只做一件事：把一个加密的 App Store IPA 在本机解开、校验并重新打包。

- 产物：
  - `dist/IPADecrypt-1.0-adhoc.ipa`：arm64，iOS 16+，ad-hoc 签名并内嵌 App Group entitlements
  - `dist/IPADecrypt-1.0-unsigned.ipa`：同一份 App，去掉签名，给自签工具做干净重签
- Bundle ID：`com.eason.ipadecrypt`
- App Group：`group.com.eason.ipadecrypt`
- 无网络请求，账号信息不落盘

## 功能

1. 从「文件」导入 IPA，或把 IPA 放进「文件 › 我的 iPhone/iPad › IPA 解密」。
2. 解包到共享容器（无 App Group 时退到 App 包内 `fpstage`），按 `SC_Info/Manifest.plist` 把 SINF 复制到每个加密二进制旁。
3. 对每个 Mach-O 做 `mmap(PROT_READ)` + `mremap_encrypted(cryptid 2)`，由系统 `fairplayd` 用本机已有的 FairPlay 授权解密。
4. 清掉 `LC_ENCRYPTION_INFO(_64)` 的 `cryptid`，重新打包为 `<原名>-decrypted.ipa`。
5. 对产出的 IPA 逐条复核：`cryptid` 必须为 0、原加密区熵值必须塌下来；有残留时文件名带 `-PARTIAL`。

## 解密的前提

这是系统 FairPlay 的限制，不是 App 的逻辑：

- IPA 必须是**加密的 App Store 包**，包内有 `Payload/<App>.app/SC_Info/*.sinf`。已解密的包会提示「无需解密」。
- 这台设备必须用**下载该 App 的 Apple ID** 登录过一次系统 App Store（`设置 › 媒体与购买项目`，或 App Store 头像）。授权会留在这台设备上，之后可离线重复解密。
- `fairplayd` 能读安装包 bundle 与共享容器，但读不到 App 的数据容器（Documents/Library/tmp 都会被拒），所以暂存目录必须是签名带 **App Group** 的共享容器。免费个人账号、不含 App Group 的 AltStore/SideStore 重签都拿不到这项能力，解密会直接报错；TrollStore 安装时可尝试回退到 App 包内暂存。

签名工具允许自定义 entitlements 时，加上：

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.eason.ipadecrypt</string>
</array>
```

并把描述文件里注册的 App Group 换成同一串（或让工具自动写入 profile 中的 group）。App 启动后首页右上角只显示一个状态点（就绪 / 受限），实际拿到的容器和可写状态在右上角 i 的「当前环境」里。

## 自签 / 安装

两个包内容一致，只是签名状态不同。都不是可用于普通未越狱设备直装的苹果证书签名：

- 自签工具（ESign、Sideloadly、Feather、AltStore 等）优先用 `-unsigned.ipa`，让工具用自己的证书与描述文件签名；要用解密功能，重签时仍需带上 App Group。
- 需要直接检查 entitlements、或自己用 `ldid` / `codesign -s -` 处理时，用 `-adhoc.ipa`（已带 `group.com.eason.ipadecrypt`）。

- **TrollStore**：用 `-unsigned.ipa` 最稳（它自己用 ldid 签名安装）；「文件」或隔空投送打开后分享给 TrollStore。
- **自签工具（ESign、Sideloadly、Feather、AltStore 等）**：导入 `-unsigned.ipa`，由工具用你的证书重签；要解密就必须让重签后的 entitlements 带上一个 App Group（见上）；工具保留自带 entitlements 时也可以用 `-adhoc.ipa`。
- ad-hoc 包不能再直接安装到普通未越狱设备；这类设备需要自签工具重新签名。

## 文案

所有界面文案（含按钮、状态、错误提示、说明页，以及 Info.plist 的显示名和文档类型名）都集中在 `src/strings.json`。构建时 `scripts/genstrings.py` 会把它生成 `build/gen/Strings.swift`，并把显示名注入 Info.plist，所以改文字只需要改 JSON 再重新打包。

- `{name}` 是占位符，生成对应函数参数（如 `{count} 个 IPA` → `filesBadge(count:)`）；改占位符名字或数量后，调用处会编译报错，按报错同步改即可。
- 键名是 Swift 引用的一部分，改键名要同步改源码；只想改文字就别动键名。
- 原始技术日志（`[OK]`/`[FAIL]`/`UNPACK` 等）保留在源码里，不属于界面文案。

## 构建

不依赖 Xcode，只用 Command Line Tools 的 clang/swiftc + 独立 iPhoneOS SDK（默认读 `~/Library/Caches/ios-unsigned-ipa/iPhoneOS26.5.sdk`，可用 `SDK=` 覆盖）：

```bash
bash scripts/build.sh
```

脚本会：编译 `FairPlayCore.c` → 编译 ZIPFoundation 0.9.19 静态库 → 编译全部 Swift 源码 → 组装 `.app` → ad-hoc 签名（带 App Group）→ 打 IPA。产物写入 `dist/`。

单独校验产物：

```bash
bash scripts/verify.sh dist/IPADecrypt-1.0-adhoc.ipa
bash scripts/verify.sh dist/IPADecrypt-1.0-unsigned.ipa
```

## 目录

```
src/                  App 源码（SwiftUI 界面、解密驱动、扫描器）
src/strings.json      全部界面文案，构建时生成 Swift 常量
src/FairPlay/         从 iPadn 拆出的解密核心：FairPlayDecryptor / Environment / Verifier
src/Support/          App Group 解析、ZIP 路径安全、取消标记
vendor/FairPlayCore/  纯 C 的 mremap_encrypted 与 SINF 处理
vendor/ZIPFoundation/ ZIPFoundation 0.9.19 源码
assets/               图标母版、圆角预览与 ICC 配置（不参与打包）
scripts/              build.sh / verify.sh / genstrings.py / makeicon.swift
dist/                 产出的 IPA
```

## 来源与许可

- 解密核心、`FairPlayCore`、`FairPlayDecryptor`/`FairPlayVerifier` 均来自 [mengangs/ipadn](https://github.com/mengangs/ipadn)（GPL-2.0-or-later），本工程是其派生作品，按同许可证分发，见 `LICENSE`。
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.19，MIT。
- 仅用于自签安装、自己拥有授权的 App 备份与本地研究；不做账号共享、不绕过付费。
