# 无 Mac：GitHub Actions → LiveContainer 自研测试

当前状态：LiveContainer 已安装并可进入应用列表。**两个自研测试 App 已在 GitHub macOS runner 编译打包成功，并通过 USB 复制到手机、回读校验通过；客体 App 启动与媒体功能尚未测试。**

首次构建：[Sweige/OpenAI Actions run 38121437811](https://github.com/Sweige/OpenAI/actions/runs/38121437811)。独立分支 `codex/ios-livecontainer-poc-20261011`，提交 `15b1c4c46edfa0a1d420ddeb1589afc3c1089d28`；没有合并 main。实际使用 Xcode 26.6（17F113）、iPhoneOS SDK 26.5、XcodeGen 2.46.0，部署目标 iOS 18.0。

手机文件位置：`我的 iPhone → LiveContainer → OBSiPhoneLab-PoC-15b1c4c`。先导入 ContainerSmoke，再导入 OBSiPhoneLab。

两个 App 均已采用 UIScene 生命周期，兼顾新版 SDK 的启动要求。依据：[Apple 生命周期迁移说明](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)。已编译通过，仍待实机运行验证。

## 两个测试 App

| 产物 | 验证目标 | 成功标准 |
|---|---|---|
| `ContainerSmoke-LiveContainer.ipa` | 容器加载我们的 App 及嵌入的 ProbeKit 动态 framework | 显示 `ContainerSmoke ready`、`ProbeKit loaded`，Display ticks 持续增加，运行 60 秒无闪退 |
| `OBSiPhoneLab-LiveContainer.ipa` | 网络 H.264 解码、摄像头/网络帧切换、重新编码回传 | 显示 Windows 测试图，RX decoded 增加；切换摄像头及网络源后，预览和回传同步变化 |

ContainerSmoke 的摄像头按钮只验证权限请求，不采集或替换视频。ProbeKit 是本工程自己的动态 framework；它的加载成功不能代替外部 tweak 注入测试。

## 上传与构建

1. 使用你拥有的测试仓库。解压构建包，把**包内内容放在仓库根目录**。根目录应直接包含 `.github/workflows/build-ios.yml`、`ios/`、`scripts/`，不要再多套一层 `OBSiPhoneLab/`。
2. GitHub 网页可使用 Add file → Upload files，上传解压后的文件和文件夹。确认 `.github` 目录也提交了。若仓库已有同名文件，先审阅差异。
3. 工作流文件必须位于默认分支，才能在 Actions 中正常找到手动运行入口。
4. Actions → `Build iOS LiveContainer PoC` → Run workflow。工作流仅手动触发，使用 `macos-26`，上限 25 分钟。私有仓库运行会占用账号的 Actions 配额。
5. 成功后，在本次运行页面的 Artifacts 下载 `LiveContainer-PoC-编号`。解压得到两个 IPA、SHA256SUMS、IPA 检查结果和构建日志。
6. 若构建失败，先查看 `ContainerSmoke-build.log` 或 `OBSiPhoneLab-build.log` 中第一个 `error:`；工作流尽量保留已生成的日志和第一个 IPA。

依赖为 GitHub 托管 macOS/Xcode、Homebrew XcodeGen、Apple 系统框架。两个官方 Actions 已固定到核查时的版本提交。工作流不使用 Apple ID、证书、密码或配对文件；不需要创建这些 GitHub Secrets。

构建命令核心：

```bash
brew install xcodegen
bash scripts/build-ios.sh
```

这是为 LiveContainer 导入准备的 arm64、未由 Apple 开发者证书签名的自研 IPA。它不能直接通过普通 iOS 安装器安装；能否由当前 LiveContainer 重新签名并运行，需要实机验证。构建本身不启用 JIT，也不要求关闭代码签名验证。

## 手机端：先测 ContainerSmoke

1. 将 `ContainerSmoke-LiveContainer.ipa` 保存到 iPhone 的“文件”App。可使用自己信任的文件传输方式；只传输构建产物。
2. LiveContainer 应用列表 → 右上角 `+` → 选择该 IPA。按当前版本的提示完成导入。
3. 点选 ContainerSmoke 并按界面提示启动。若出现证书、SideStore 或 JIT-less 配置提示，保留准确错误文本；先完成签名配置，再测试运行。
4. 观察 `ContainerSmoke ready`、`ProbeKit loaded` 和递增计数，至少运行 60 秒。可选点击摄像头权限按钮。
5. 如果提示 JIT，不要将所有 iOS 版本套用旧版 JIT 教程。本轮优先验证签名运行方式；先区分“签名未配置”“加载失败”“客体程序崩溃”。

LiveContainer 上游 README 说明 JIT-less 模式下客体代码需要签名，并列出客体权限不会自动应用到宿主、权限共享和应用兼容性限制：[源码及说明](https://github.com/LiveContainerMirror/LiveContainer/blob/main/README.md)。设备上出现的实际提示优先于失效或旧版教程。

## 再测 OBSiPhoneLab

先沿用 [README.md](README.md) 的 Windows 依赖。将下面 IP 改为电脑真实局域网地址：

```powershell
python windows/bridge.py send --test-pattern --bind 192.168.1.20 --width 720 --height 1280 --fps 30
```

导入 `OBSiPhoneLab-LiveContainer.ipa`，输入 PC IP，选择 720×1280 和 `OBS network`，点 `Connect / restart input`。容器宿主需要具备摄像头、局域网权限；客体 Info.plist 中声明权限不等于宿主实际已具备授权。

依次验证测试图 → 真实摄像头 → 测试图 → H.264 回传 → OBS 实际推流。OBS/MediaMTX/FFmpeg 与回传的完整命令见 README。先验证 720×1280，再升级到 1080×1920。

## 失败如何定位

| 现象 | 首先检查 |
|---|---|
| Actions 没有工作流 | `.github` 是否提交，工作流是否在默认分支 |
| Xcode 编译失败 | 第一个 error、build-environment.txt 中 Xcode/SDK/XcodeGen 版本 |
| 导入提示签名、证书或配置缺失 | LiveContainer 的签名配置；SideStore 集成及刷新是否正常 |
| ContainerSmoke 启动即退出 | 容器加载/签名错误、宿主兼容性；不归因于网络或编解码 |
| Smoke 正常而 OBSiPhoneLab 退出 | Swift/framework 加载、媒体初始化错误和权限 |
| RX decoded 为 0 | PC IP、同一局域网、9000 监听、Windows 防火墙、首个 SPS/PPS/IDR |
| 网络视频正常，摄像头失败 | 宿主摄像头授权、AVCaptureSession 配置及错误 |
| 预览正常，回传失败 | PC 的 9001 接收器、编码器创建/属性错误、TX 状态 |

此轮只测试自有代码，未导入抖音，未绕过第三方 App 完整性校验。LiveContainer 内客体测试成功，不代表系统已注册虚拟摄像头，也不代表 App Store 原版抖音会读取该视频源。

参考：[GitHub macOS runner 标签](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax-for-github-actions)、[GitHub 构建产物](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)。
