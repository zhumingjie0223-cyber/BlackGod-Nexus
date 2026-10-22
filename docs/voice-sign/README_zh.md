# 语音 / 手语代说（feat/voice-sign）

## 架构

| 文件 | 依赖 | 作用 |
|---|---|---|
| `ios-app/VoiceSignCore.swift` | 仅 Foundation | 纯逻辑：端上强制策略 `OnDeviceASRPolicy`、首字延迟 `FirstTokenLatencyMeter`、代说状态机 `SpeakForMeMachine`、`SignRecognizer` 协议、拒识门限 `SignRejectionGate`、清单 `SignVocabularyManifest` + `ManifestValidator`（纯 Swift SHA-256）、功能开关、`SignToSpeakBridge`、`MockSignRecognizer` |
| `ios-app/VoiceSignLiveCaption.swift` | Speech / AVFoundation / SwiftUI | `LiveCaptionEngine` + `LiveCaptionView`（大字幕、字号滑杆 24–96pt、黑底黄字高对比） |
| `ios-app/VoiceSignSpeakForMe.swift` | AVFoundation / SwiftUI | `SpeakForMeEngine` + `SpeakForMeView`（打字、常用短语、确认后才朗读） |
| `ios-app/VoiceSignInput.swift` | Foundation | `SignInputController`：识别 → 拒识 → 只写入 SpeakForMe 草稿 |
| `tests/ios/VoiceSignCoreTests.swift` | XCTest | 已加入 `tools/intelligence/run-tests.sh` 的 Linux 回归清单（源码 VoiceSignCore + 测试） |
| `data/asl/sign_thresholds_v0.json` | 配置 | 拒识门限（PROVISIONAL），代码不内置数值，由 `SignRejectionThresholds.load` 读取并校验 0–1 范围 |

`ios-app/project.yml` 以 `*.swift` 通配收录源码，新文件自动进入 App target，现有文件只改了 `tools/intelligence/run-tests.sh`（把 VoiceSignCore 与其测试加入 Linux 回归清单，任务要求）。视图尚未挂到任何导航入口（需权哥决定放哪）。

### 关键硬规则
- ASR：`requiresOnDeviceRecognition = true`；`supportsOnDeviceRecognition == false`、语言非 zh-CN/en-US、识别器不存在/不可用 → 状态 `.refused(原因)`，不启动，**绝不回落服务器**。
- 代说：`idle → draft → confirmed → speaking → idle`。`beginSpeaking()` 只在 `confirmed` 通过，否则抛 `notConfirmed` 并写审计 `speak_rejected`。确认时文本须与草稿一致；改草稿即失效；念完需重新确认。
- 手语：门限从 `data/asl/sign_thresholds_v0.json` 读取，**暂定**：置信度 ≥ 0.85、top1−top2 ≥ 0.15、手部检测 ≥ 0.5。手部不足或标签不在词表/字母表 → `rejectNoSpeak`；置信度/差距不足 → “没看清，请再打一次”；均不产生文本。通过者只进 draft。
- 功能开关 `VoiceSignFeatureFlags.signToSpeechDefault = false`，`SignGateStatus` 默认 `NOT_READY`；ASL 门控 PASS 前不得开启。

## 门控对应

| 门控 | 判定 | 代码/证据 |
|---|---|---|
| 语音组：ASR 字错率不退步 | 与基线比较 CER/WER，退步即 FAIL | **未做**：需真机录音评测集 |
| 语音组：代说未确认即 FAIL | 任何未确认朗读 = FAIL | `SpeakForMeMachine` + 单测 `testSpeakWithoutConfirmIsRejectedAndLogged`、`testBridgeDefaultOffAndOnlyDrafts` |
| 语音组：断网实测证明不出手机 | 飞行模式下可识别，且抓包无语音外发 | 代码强制端上；**需真机实测** |
| 手语组：未过门控即 NOT_READY | 无模型/无评测 → NOT_READY，开关关闭 | `SignGateStatus.notReady`、开关默认 false；拒识测试读 `data/asl/mock_recognitions.jsonl`（MOCK 数据） |

## Info.plist 键
- `NSMicrophoneUsageDescription`：已存在。
- `NSSpeechRecognitionUsageDescription`：**缺失**，需加入 `project.yml` 的 info properties 与 `zh-Hans.lproj` / `en.lproj` 的 `InfoPlist.strings`，建议文案：“实时字幕在本机识别语音，不会上传。” / “Live captions recognize speech on this device only.” 缺少此键时调用识别授权会崩溃。

## 真机验证清单
1. Xcode 编译通过（Linux 上只验证了纯逻辑，Apple 框架部分未编译）。
2. zh-CN、en-US 各自 `supportsOnDeviceRecognition` 实际值；不支持时界面显示“已拒绝启动”。
3. 飞行模式下字幕正常；抓包确认无语音外发。
4. 首字延迟显示合理（记录 P50/P90）。
5. 字号滑杆、VoiceOver、动态字体、高对比可读性。
6. 代说：未确认点“朗读”无声并提示拒绝；确认后朗读；朗读中切换/中断音频会话行为。
7. 与现有语音输入同时使用时的 AVAudioSession 冲突。

## 还差权哥的步骤
- 在 Mac/Xcode 上编译并真机跑上面清单（本次未碰 Mac）。
- 补 `NSSpeechRecognitionUsageDescription`（改现有 project.yml 与 InfoPlist.strings，本次刻意未改）。
- 决定 LiveCaption / SpeakForMe 入口位置。
- ASR 评测集录制/下载批准（字错率基线）。
- ASL：模型选型、数据下载与许可确认（`data/asl` 中许可多为“待复核”）、门限标定、门控评测；`data/asl/*.json` 清单尚无 `sha256` 字段，`ManifestValidator` 现只用于新格式清单。
- 审核后自行 push（本分支未 push）。

## 运行测试（box/Linux）

```bash
export PATH=/workspace/.toolchains/swift-6.2.1-RELEASE-ubuntu24.04/usr/bin:$PATH
bash tools/intelligence/run-tests.sh
```
