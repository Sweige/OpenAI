# OBS → iPhone 自研视频源切换实验

研究与实现日期：2026-10-11。用途：验证自己拥有代码和签名权限的 App 能否接收 OBS 视频、在摄像头与网络画面间切换、重新编码并回传。工程不修改抖音，不注册系统虚拟摄像头，也不使用屏幕共享。

后续实机进展：iPhone 已连接 Windows，LiveContainer 已安装并能进入应用列表。ContainerSmoke 和 OBSiPhoneLab 已通过 GitHub Actions 的 macOS 构建，并通过 USB 复制到 LiveContainer 的文件目录、回读校验通过。**客体 App 启动与媒体运行仍待验证**。见 [GitHub Actions / LiveContainer 测试说明](GITHUB-LIVECONTAINER.md)。

## 实际验证范围

| 部分 | 本次状态 |
|---|---|
| Python 协议解析 5 项测试 | Windows 已运行通过 |
| TCP 发送 → 接收 → FFmpeg 解码 | 720×1280、1080×1920，各 60 帧通过，无 B 帧 |
| TCP 回传接收，逐字节比对 | 两个分辨率通过 |
| TCP 回传 → FFmpeg RTMP → 本机监听器 | 720×1280、60 帧通过，见 validation/relay-results.json |
| OBS 实际发布到 SRS / MediaMTX | 未运行；提供配置，服务器配置需按安装版本验证 |
| Swift / Objective-C 编译与 IPA 打包 | GitHub Actions 已通过；Xcode 26.6 / iPhoneOS SDK 26.5 / arm64 / Release；包含 ProbeKit framework |
| LiveContainer 自研 IPA 导入、签名、iPhone 运行 | 两个 IPA 已通过 USB 复制到手机并回读验证；导入、签名、运行尚未验证 |
| 音频、音画同步、长时间热稳定性 | 尚未实现 / 未验证 |
| 抖音普通直播 | 不在此原型的已实现范围 |

因此这是 Windows 数据面验证通过、iOS 编译打包通过的最小原型，不能称为已在 iOS 27 真机跑通的成品。仍须完成下面的真机实验。

## 结构与数据流

```text
OBSiPhoneLab/
  config/mediamtx.yml            Windows 原生 RTMP 服务配置
  config/srs.conf                SRS 可选配置
  windows/wire.py                OBSC/1 分包、Annex-B、AUD 分帧
  windows/bridge.py              OBS/测试图 → H.264 TCP；回传接收与可选 RTMP 转发
  windows/test_wire.py           拆包/合包/多 slice/异常长度验证
  windows/check_bridge.py        真实 Windows TCP + FFmpeg 端到端回环验证
  ios/project.yml               XcodeGen 工程定义，最低部署版本 iOS 18
  ios/OBSiPhoneLab/
    ViewController.swift        原生 UI 与 AVSampleBufferDisplayLayer
    Pipeline.swift              串行媒体队列、视频源选择、统一输出时钟
    StreamClient.swift          Network.framework TCP 接收与回传
    Wire.swift                  OBSC/1、Annex-B 数据处理
    H264Decoder.swift           SPS/PPS、AVCC、VideoToolbox 硬件解码
    Camera.swift                AVCaptureVideoDataOutput 与设备枚举
    FrameNormalizer.swift       像素池、NV12、竖屏尺寸、CMSampleBuffer
    H264Encoder.swift           VideoToolbox 实时 H.264 硬件编码
  ios/ProbeKit/                 同一开发者签名的 Objective-C 动态 framework
  validation/                  本次 Windows 日志、结果和短码流
```

```text
OBS program output
  → RTMP localhost:1936/live/obs
  → MediaMTX 或 SRS
  → FFmpeg（为可重复分帧重新编码，无 B 帧、AUD、SPS/PPS）
  → Python bridge TCP :9000
  → iPhone H264Decoder → latest CVPixelBuffer ┐
  → iPhone Camera      → latest CVPixelBuffer ├→ source selector
                                             → NV12 / 720×1280 或 1080×1920
                                             → 同一帧分别预览、VT 编码
                                             → TCP :9001 → Windows receiver
                                             → return.h264 / 可选自有 RTMP 服务
```

多一次 FFmpeg 重编码是 PoC 的简化选择，不是推荐的最终性能架构。生产版本应直接使用 OBS 编码包或 WebRTC 原生帧接口，保留真实媒体时间戳。

## 设备与依赖

- Windows 11、FFmpeg（需 libx264，`ffmpeg -encoders` 检查）、Python 3.10+；Python 无第三方依赖。
- OBS Studio；SRS 或 [MediaMTX](https://github.com/bluenviron/mediamtx/releases) 二选一。
- Mac、支持目标设备的 Xcode；iOS 27 首选 Xcode 27 / 对应设备支持包。Apple 当前列出 Xcode 27 要求 macOS Tahoe 26.6 及以上，安装前核对 [Apple 发布表](https://support.apple.com/en-is/100100)。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)，通过 `brew install xcodegen` 安装。
- iPhone 15/16/17，iOS 18+，开发者账号、配对数据线，以及同一无客户端隔离的局域网。

先使用 720×1280，完整打通后升级 1080×1920。模拟器不能替代硬件编解码与真机摄像头验收。

## 1. 先验证 Windows

下面命令以在工程根目录打开 PowerShell 为前提。把 FFmpeg 加入 PATH：

```powershell
$env:Path = 'C:\ffmpeg\bin;' + $env:Path
python --version
ffmpeg -version
python -m unittest discover -s windows -p test_wire.py -v
python windows/check_bridge.py --output validation-recheck
```

成功：两种尺寸各收到 60 帧，FFmpeg 解码无错误，回传文件完全一致；结果明确保留 `iOS_build: not_run`。此次实测结果保存在 `validation/results.json`。这一步不需要 iPhone 或 OBS。

可选复现 RTMP 回环测试：`python windows/check_relay.py`。它使用 `validation/720x1280.h264` 的已交付短码流，在回环地址启动 FFmpeg 监听器和转发器，验证收到 60 帧；不调用手机。

## 2. 构建与安装 iOS App

将整个工程复制到 Mac。以下是 macOS shell 命令：

```bash
cd OBSiPhoneLab/ios
xcodebuild -version
xcodegen generate
xcodebuild -project OBSiPhoneLab.xcodeproj -scheme OBSiPhoneLab \
  -sdk iphoneos -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
open OBSiPhoneLab.xcodeproj
```

最后一条用于 Xcode 设置 Signing & Capabilities。App 和 ProbeKit 都选择自己的 Team；把 `com.example.OBSiPhoneLab` 改为自己可注册的唯一 Bundle ID。不要使用抖音标识。连接设备并信任电脑，按 Apple 文档开启 [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)，选择真机后 Run。摄像头、局域网弹窗都允许。

自动签名的命令行构建示例，替换 `YOUR_TEAM_ID` 和 `YOUR_DEVICE_ID`：

```bash
xcodebuild -project OBSiPhoneLab.xcodeproj -scheme OBSiPhoneLab \
  -configuration Debug -destination 'id=YOUR_DEVICE_ID' \
  -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  build/Build/Products/Debug-iphoneos/OBSiPhoneLab.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID com.example.OBSiPhoneLab
```

若改变 Bundle ID，最后一个参数也随之改变。设备 ID 从 Xcode Devices and Simulators 或 `xcrun devicectl list devices` 获取。免费 Personal Team 的有效期和权限受 Apple 当期政策限制，不把短期开发安装视为永久分发方案。

## 3. 不依赖 OBS 的第一条链路

假设 PC 的实际局域网 IPv4 为 `192.168.1.20`，请全程替换为真实地址：

```powershell
python windows/bridge.py send --test-pattern --bind 192.168.1.20 --width 720 --height 1280 --fps 30
```

iPhone 输入 PC IP，选 720×1280、OBS network，点 `Connect / restart input`。测试图应不断移动，RX decoded 持续增加。切 `Real camera` 后应显示真实摄像头，切回 OBS 后应恢复测试图。

仅当 Windows 防火墙阻断时，可在管理员 PowerShell 添加局域网限定规则：

```powershell
New-NetFirewallRule -DisplayName 'OBSiPhoneLab TCP LAN' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 9000,9001 -RemoteAddress LocalSubnet -Profile Private
```

原型默认只绑定 127.0.0.1；真机测试必须显式传 `--bind PC局域网IP`。手机不能连接电脑的 127.0.0.1。PoC 是可信局域网中的明文单客户端实验协议；不提供公网认证、TLS 或 NAT 穿透。

## 4. 配置 OBS 与 RTMP 服务

### 方案一：Windows 原生 MediaMTX

从官方 Releases 取得 Windows 版本，在工程根目录运行：

```powershell
.\mediamtx.exe config/mediamtx.yml
```

可执行文件也可位于其他目录，替换路径即可。配置明确将 **RTMP** 监听设为 1936，不是沿用 MediaMTX 默认 RTMPS 1936。服务器启动日志必须确认协议和端口。它和 SRS 不要同时占用同一端口。

### 方案二：SRS

如已安装 Docker Desktop / WSL2，可从工程根目录运行：

```powershell
$srsConfig = (Resolve-Path -LiteralPath config/srs.conf).Path
docker run --rm -it --name obs-iphone-srs -p 127.0.0.1:1936:1936 --mount "type=bind,source=$srsConfig,target=/usr/local/srs/conf/obs-iphone.conf,readonly" ossrs/srs:6 ./objs/srs -c conf/obs-iphone.conf
```

SRS 6 配置来自公开语法，当前环境没有运行 Docker/SRS；若版本拒绝配置，查看启动日志并按其文档校正。正式复现固定下载版本或镜像 digest。

### OBS 设置

1. 设置 → 视频：基础画布 `1080×1920`、输出 `720×1280`、30 FPS。升级试验时输出改为 `1080×1920`。
2. 场景中加入摄像头、媒体、文字和计时器；切换场景会改变 program output。
3. 设置 → 输出 → 高级 → 推流：H.264 硬件编码（或 x264），CBR，720p 起始 4 Mbps / 1080p 起始 6 Mbps，关键帧间隔 1 秒，B 帧 0。关闭引入额外缓存的 look-ahead。若编码器不接受该组合，先用 x264 veryfast + zerolatency 做基准。
4. 设置 → 推流：自定义；服务器 `rtmp://127.0.0.1:1936/live`，串流密钥 `obs`。
5. 点开始推流。这里将 OBS 发布到自己的局域网服务，未使用电脑端抖音直播伴侣。
6. 可先检查服务器：

```powershell
ffplay -fflags nobuffer -flags low_delay -framedrop rtmp://127.0.0.1:1936/live/obs
```

7. 启动桥接：

```powershell
python windows/bridge.py send --input rtmp://127.0.0.1:1936/live/obs --bind 192.168.1.20 --width 720 --height 1280 --fps 30 --bitrate 4M
```

8. 手机连接 PC；切换 OBS 场景并观察手机。目标尺寸测试两端都改为 1080×1920，桥接参数 `--width 1080 --height 1920 --bitrate 6M`。

OBS 音频可先配置 48 kHz，但当前桥接显式 `-an`，不会把音频发送到 iPhone。不要把可见视频测试当成音画同步验证。

## 5. 验证手机重新编码与网络推流

先在另一个 PowerShell 窗口运行回传接收器：

```powershell
python windows/bridge.py receive --bind 192.168.1.20 --output capture/return.h264
```

手机连接输入后点 `Start H.264 return to PC :9001`；在 Real camera 与 OBS network 间来回切换。receiver 应持续增长。停止后查看：

```powershell
ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=codec_name,width,height,nb_read_frames,has_b_frames -of json capture/return.h264
ffplay -framerate 30 capture/return.h264
ffmpeg -r 30 -i capture/return.h264 -c:v copy capture/return.mp4
```

若希望同时 RTMP 推到自己的 MediaMTX / SRS：

```powershell
python windows/bridge.py receive --bind 192.168.1.20 --output capture/return.h264 --rtmp rtmp://127.0.0.1:1936/live/return
ffplay -fflags nobuffer -flags low_delay -framedrop rtmp://127.0.0.1:1936/live/return
```

分别在独立终端运行 receiver 与 ffplay。手机上传编码 H.264，Windows 只封装转发，不再编码。RTMP 的恒定帧率时间戳由 FFmpeg 重新生成；原型录下的真实 PTS 位于同名 CSV。它验证“切换后的视频进入编码器并被网络接收”，没有实现原始 PTS 的音视频复用。

在当前 Windows 环境，回传脚本和 RTMP 封装已用实际码流做回环验证；真实手机编码器仍待实验。生产版本可将 RTMP muxer 或获授权直播 SDK 放在手机端，或保留独立网络出口，两者都不能据此获得抖音原版内部输入权限。

## 6. 动态 framework 与签名实验

ProbeKit 是单独的 Objective-C 动态 framework，由 Xcode 嵌入 App 并使用相同 Team 签名。启动日志应出现 ProbeKit constructor，界面显示 `ProbeKitIdentity()` 返回值。这验证普通 iOS 应用可以加载随包合法签名的自定义动态代码，不验证任意进程注入。

在 Mac 上检查自己构建的产物：

```bash
APP=build/Build/Products/Debug-iphoneos/OBSiPhoneLab.app
otool -L "$APP/OBSiPhoneLab"
codesign -dvvv "$APP"
codesign -dvvv "$APP/Frameworks/ProbeKit.framework"
codesign -d --entitlements :- "$APP"
codesign --verify --strict --verbose=4 "$APP"
```

依次确认 `@rpath/ProbeKit.framework/ProbeKit`、一致 Team、包含在 provisioning profile 中的 entitlement、签名有效。另建自己的空测试 App 比较嵌入前后即可；不需要修改商用 App 或触发 CoreTrust 绕过。企业签名不能绕过这些代码与权限约束。

## 模块关键行为和失败边界

- 每个 TCP 包是完整 H.264 Access Unit，不能把 NAL 当成完整帧；Python 用 AUD 分界，支持多个 slice。
- `H264Decoder` 收到 SPS/PPS 后创建 format description；将 Annex-B 改为 AVCC 长度前缀；CMBlockBuffer 自有分配并拷贝，避免悬空 Swift Data 指针。
- 解码明确要求硬件；失败输出 OSStatus，不默默退回软件而宣称硬解。重建解码器后等待 IDR，generation token 丢弃过期回调。
- 输出 NV12 video-range (`420v`)，Core Image 复用 context 与像素池，最多 6 个在途池分配；尺寸、像素格式、色彩和方向在编码前统一。
- Pipeline 使用本机单调时钟；切源不重置 PTS；预览和编码器取自同一个选择器输出。此处尚未实现多端时钟对齐和音频主时钟。
- UI 的 source age 是“距最近解码/相机帧交付本机的时间”，不是源采集到现在的时间，也不是端到端网络延迟。网络旧帧刚解码时 age 同样很小；必须用画面计时器或同步时钟测真实延迟。
- 输出队列最多保留少量应用层发送中的包；NWConnection 的 contentProcessed 不是远端确认，不能据此认为系统 TCP 缓冲也被限定。丢过编码参考帧后等待下一个 IDR。生产还需按年龄/确认反馈限制总积压，超时重连，不任意扔掉中间 P 帧再继续解码。
- 断流超过约 500 ms 停止产生新编码帧；UI 保留最后预览并显示 age。输入重连需要点击 Connect；没有生产级自动恢复状态机。
- 固定 30 FPS 定时调度，可能重复最新输入帧。严格逐帧同步、自动旋转、60 FPS、HEVC、HDR、前后镜头多路切换暂未实现。
- 为方便切换，摄像头和网络接收同时运行，能耗高；生产版本应按状态启停设备并保留输出时钟。
- App 进入后台主动停止，不使用后台权限伪装持续相机采集。

## 排障与验收

| 现象 | 定位顺序 |
|---|---|
| iPhone 无法连接 | PC 实际 IP → 绑定地址 → Windows Private 防火墙 → 局域网权限 → AP 客户端隔离；先在电脑看 Listening / Phone connected |
| RX 有数据但黑屏 | SPS/PPS/首个 IDR → Annex-B/AVCC → H.264 profile → 解码 OSStatus → NV12 pool / display layer status |
| 相机黑屏 | 摄像头授权 → capture session 启动日志 → activeFormat → 输出连接旋转；检查设备枚举日志 |
| 切源后跳时间 | 只以 Pipeline 输出时钟生成 PTS；不能直接拼接两个源各自从 0 开始的 PTS |
| 预览正常、回传不同 | 比较选择器后帧 ID 与编码后码流；验收必须解码 return 流，不能仅看预览 |
| 出现紫/绿、亮度异常 | NV12 plane stride、420v/420f、BT.709、是否误将 BGRA 当 YUV、是否读写未锁定的 CPU 内存 |
| 延迟逐渐增长 | TCP backlog、FFmpeg probe、OBS B 帧/look-ahead、服务器 GOP cache、消费队列；记录 age 与 CSV，受控断开后从 IDR 恢复 |
| 1080p 不稳定 | 先回到 720p；分离解码、Core Image、编码耗时；用 Instruments 看 thermalState / 内存 / CPU / GPU |
| signed framework 无法加载 | Team、profile、Bundle ID、arm64 架构、最低系统、rpath、嵌套签名；以设备 dyld 日志为准 |
| RTMP 转发阻塞 | 先确认服务在线和路径正确；转发子进程报错或网络阻塞会影响接收，生产需分离有界 mux 队列和故障状态 |

建议验收：先 5 分钟功能测试，再 30 分钟压力测试，最后 2 小时热稳定性测试。使用同时出现在 OBS 和接收端的毫秒计时器或闪屏，测 P50/P95 延迟；当前未提供任何实测 iPhone 延迟数字。加入音频后用同源闪屏+点击声校验，目标音画偏差绝对值不超过 80 ms，可按产品需求收紧。

在 `Camera.swift` 的真机日志中能看到 `.external` 发现结果；空列表只说明该设备/系统/附件组合没有暴露输入。发现外部设备仍须另测第三方 App 是否枚举和选择它，不能直接推导抖音支持。

更多签名、协议、商家证据和抖音失败边界见工程包之外的《技术研究报告》。
