# External VCAM experiment — own App only

This experiment reuses the existing OBSiPhoneLab v4 host and loads **OBSCaptureHook.dylib separately through LiveContainer**. The dylib is not embedded in either IPA. It activates only for bundle `com.example.OBSiPhoneLab` and the Objective-C runtime delegate class `OBSiPhoneLab.Camera`.

This is an application-local callback replacement experiment. It does not create a system camera, modify an official Douyin installation, authenticate the device-reported OS version, or establish audio/long-term performance.

## Architecture

Real camera → AVCaptureVideoDataOutput → external delegate proxy → original Camera callback → existing preview/normalizer/encoder → PC :9001.

Proxy modes:

- **Off**: pass real camera samples unchanged.
- **Pattern**: NV12 luma bars, moving bright band and binary frame stamp. Preserve camera PTS and duration.
- **OBS**: independent OBSC/1 receiver on PC **9002**, VideoToolbox hardware decode, retain only latest pixel buffer, preserve camera timing in a newly created CMSampleBuffer. Source older than 500 ms is dropped; it does not silently revert to the real camera.

Camera remains physically active and drives callbacks. At present the host normalizer assigns its own 30 Hz encoding timestamps, so preserving callback timestamps is not evidence of network clock / audio synchronization. No audio is transported.

## Build

Run on macOS with Xcode and XcodeGen:

```bash
bash scripts/build-ios.sh
```

Artifacts include the two existing IPAs, independent dylib, compiler logs, Mach-O inspection and hashes. No Apple credentials are used in CI. LiveContainer signs imported tweaks locally with the certificate the user already imported.

## LiveContainer 3.8.10 setup

Source audited at `LiveContainerMirror/LiveContainer` commit `4dbe0f9a626de801184a42c0be8d2cb105058e3d`:

- [Tweak manager](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Views/LCTweaksView.swift): creates folders, imports dylib/framework, adds rpath, supports signing; comments specify signing before App launch.
- [Loader](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/TweakLoader/TweakLoader.m): loads selected `LCTweakFolder` using `dlopen(RTLD_LAZY | RTLD_GLOBAL)`; `.disabled` files are skipped.

1. Exit OBSiPhoneLab completely. In LiveContainer's Tweaks tab create folder **OBSiPhoneLab-VCAM**.
2. Open that folder, use + → Import tweak to select our standalone dylib from Files. Keep it enabled and explicitly tap the **Sign / signature** toolbar button; wait for signing to finish. Do not import into the global root folder. If an earlier copy exists at the global root, disable that copy so its load error does not persist. If no signing button is shown, check LiveContainer's already-imported local certificate; do not export it to the PC or CI.
3. In OBSiPhoneLab's application settings select this folder as its tweak folder. Tweak injection must be enabled. Restart the guest App.
4. An in-window panel titled **VCAM Lab · external dylib** should appear, default **Off**. It can be dragged by its title or collapsed using ±. The panel itself is UI, not encoded video.
5. Host: enter PC IP, choose resolution, tap Connect then **Real camera** / Retry camera. The plugin's **wrapped** count must be ≥1 and callbacks must rise before replacement testing.
6. Keep host in **Real camera**. Select Pattern in plugin. Only the grayscale pattern is expected in host preview. Off returns to real camera. Start host return → verify PC decoded stream.
7. Start the independent PC sender on 9002. In plugin enter PC IP and tap **OBS :9002**; keep host in **Real camera**. NET / replaced and host CAM / TX must rise. Switch an OBS scene and verify return video on PC.

The App's built-in `OBS network` source / `RX decoded` is not used as evidence for this experiment. Existing port9000 receiver may reconnect independently; port9002 prevents conflict. Backgrounding stops reception and resets plugin mode Off.

### Observed signing failure (2026-10-11)

The user reported `dlopen(.../Documents/Tweaks/OBSCaptureHook.dylib): missing code signature`. This establishes that the root-folder copy exists but cannot be loaded due to its missing signature; it does not establish a callback-replacement failure. CI intentionally supplies an unsigned dylib. The earlier instruction that manual signing was optional was insufficient for this setup.

The audited [LCAppModel.signApp](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Models/LCAppModel.swift) returns before both per-app and global tweak signing when `appInfo.tweakFolder` is nil. Whether that exact guard was reached on this phone is not yet verified. [LCUtils.signTweaks](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift) requires a locally available certificate and signs matching dylibs via ZSign. Bind the per-app folder, explicitly sign there and disable the earlier global copy before retrying. No IPA rebuild is currently indicated.

## PC commands (PowerShell, from the source directory)

Keep the existing loopback MediaMTX server and OBS output running:
`rtmp://127.0.0.1:1936/live`, key `obs`, H.264, 30 FPS, keyframe interval1s. Begin with720×1280; raise to1080×1920 after the external path works.

```powershell
python windows/bridge.py send --input rtmp://127.0.0.1:1936/live/obs --bind 192.168.50.39 --port 9002 --width 720 --height 1280 --bitrate 4M --ffmpeg C:/ffmpeg/bin/ffmpeg.exe
python windows/bridge.py receive --bind 192.168.50.39 --port 9001 --output capture/external-pattern/return.h264 --frames 900
```

These are two separate PC terminals/processes. The phone runs only OBSiPhoneLab. Receive exits after900frames; restart with a new output directory for each mode. Starting return on an already initialized host encoder reconnects its existing uplink.

## Failure boundaries / evidence

No panel: inspect tweak folder assignment, enabled switch, local signing error, dlopen error, bundle ID. Panel but wrapped0: choose Real camera and Retry; investigate runtime delegate class before changing any allowlist. Wrapped/callbacks rise but replaced0: check mode; OBS requires NET decoded and fresh source. Replaced rises but TX0: isolate using Pattern and inspect host encoder; callbacks alone do not prove successful encoding.

For a successful test retain numeric mode/counter observations, capture SHA256, dimensions, full-decode result, PTS/sequence analysis and proof of source content. Raw real-camera/OBS desktop captures remain local and must not be uploaded to the source repository.

Build passed [Actions 38133205057](https://github.com/Sweige/OpenAI/actions/runs/38133205057), commit `843b223ffc258b987b95d0ad6aa7850708a84167`, using Xcode26.6 / SDK26.5, minimumiOS18. The standalone136,848-byte dylib has SHA256 `1f45abd81c351c2169923365cecca46b48221d069e7fdd7a3e536ffaac900d34`; independent inspection against the existing v4 IPA confirmed it is absent. USB copy and readback passed. **The user reports local signing succeeded and the VCAM Lab panel appears after restarting the guest. External code execution is established by that operator observation; the user also confirms host Real camera / plugin Pattern, and the PC received and fully decoded900720×1280 frames at29.99895 FPS. All900 source stamps were distinct and consecutive (538→1437). External OBS mode is still pending. Raw gray levels changed and color fidelity is not passed.**

For a Pattern capture, `python windows/check_hook_pattern.py capture/external-pattern/return.h264 --report capture/pattern-proof.json` checks the seven luma columns and changing binary counter in decoded return frames. Use FFmpeg/FFprobe on PATH or pass their executable paths. Keep the host in Real camera and record external-load/counter observations separately. Content matching alone does not establish how the module was loaded.

A successful self-owned test would establish external application-local camera callback replacement under this LiveContainer setup; applying it to another authorized App requires its own capture/preview/encoder integration assessment.

Pattern checker now reports raw-luma preservation separately from seven-column geometry and all-frame binary-counter progression. The first strict raw-luma report failed and is retained; identity checking is not a color-fidelity claim. Numeric evidence is in `validation/phone-external-pattern-720-v1.json` and `validation/phone-external-pattern-content-v1.json`.
