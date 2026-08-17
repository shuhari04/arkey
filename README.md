<p align="center">
  <img src="assets/arkey-logo.png" alt="Arkey logo" width="152">
</p>

<h1 align="center">Arkey</h1>

<p align="center">
  An unofficial, development-only Codex command surface with AgentGlow lighting for QMK keyboards.
</p>

Arkey 把兼容的 QMK 键盘变成一套可配置的 Agent 控制面：实体任务键、审批与发送、推理旋钮、语音输入，以及随任务状态变化的 AgentGlow RGB 光效。仓库同时提供两条明确隔离的实验链路：默认的 **Codex App Server 模式**，以及仅面向本地互操作研究的 **Codex Micro Lab 模式**。

> [!IMPORTANT]
> Arkey 是独立、非官方的社区项目，与 OpenAI、ChatGPT、Codex、Work Louder、Keychron 或 QMK 没有隶属、合作、赞助或背书关系。“Codex”“ChatGPT”“Codex Micro”“Work Louder”“Keychron”和“QMK”均属于各自权利人。仓库不包含 Work Louder 私有 SDK，也不代表任何权利人认可本实现。

> [!CAUTION]
> 本项目仅用于开发、研究、兼容性验证和自有硬件测试，不用于商用。Arkey 自有客户端、host、配置工具、文档和测试按 PolyForm Noncommercial 1.0.0 提供；QMK/Keychron 派生固件仍受其 GPL/MIT 等文件级许可约束，不能被根目录条款统一改成“不可商用”。源码许可也不授予第三方 USB 身份、商标、服务接入或设备销售权。详见[许可证](#许可证)。

> [!WARNING]
> 可选的 Codex Micro Lab 固件会让自有 Q6 Pro ANSI Knob 或 V1 Max ANSI Knob 在 USB 枚举和 HID 行为上临时呈现当前实验所需的兼容身份。该身份不是分配给 Arkey 或你的键盘的 USB 身份，可能随 ChatGPT Desktop 更新而失效，并可能涉及服务条款、商标、USB 身份、保修及当地法律风险。不要销售、分发或把刷入该固件的键盘表述为官方 Codex Micro。构建脚本要求显式风险确认；安装工具会在用户确认 DFU 与目标固件后才写入，绝不自动刷写。

## 两种模式

| 模式 | Codex 连接 | 键盘连接 | 适用范围 |
| --- | --- | --- | --- |
| App Server（默认） | 本机 `codex app-server --listen stdio://` | Arkey 自定义 32-byte Raw HID bridge | 完整的 15 键布局、Skill、Cancel、AgentGlow 灯效及其他 QMK 移植 |
| Codex Micro Lab（可选） | ChatGPT Desktop 当前版本识别的实验 HID 兼容面 | 64-byte native-facing report + Arkey 自实现配置 report | Q6 Pro ANSI Knob / V1 Max ANSI Knob、自有硬件、USB、本地开发测试；不属于公开或受支持的 Codex API |

App Server 模式使用 OpenAI 文档公开的开发接口，但 App Server 目前仍是实验性开发/调试界面，可能变化。Micro Lab 不通过 App Server 模拟动作；它直接验证当前 ChatGPT Desktop 与实验固件之间的本地 HID 互操作行为。

Micro Lab 由两个不同协议面组成：

1. **native-facing 兼容面**：Report ID `0x06`，用于当前实验观察到的设备状态、任务灯光、按键、旋钮和方向事件；它不是公开、稳定或受支持的 OpenAI API。
2. **Arkey 配置协议**：Report ID `0x07`，由本项目独立设计，用于读取、捕获、写入、清除实体矩阵映射及恢复预置布局。它不会被描述成 Codex Micro 原生协议。当前 Lab 固件在 USB 模式固定接管旋钮旋转；配置接口不支持关闭。

完整的风险确认、构建、配置协议和恢复步骤见 [`docs/CODEX_MICRO_LAB.md`](docs/CODEX_MICRO_LAB.md)。

## 仓库内容

- `apps/ArkeyMac`：macOS 14+ SwiftUI 客户端，包含 Command Surface、Composer、审批、语音、AgentGlow Light Lab，以及隔离的 Micro Lab 配置视图。
- `src`：Node 20+ 本地 daemon/CLI，启动 Codex App Server、管理任务和审批，并驱动标准 Arkey QMK bridge。
- `firmware/qmk/arkey.*` 与 `firmware/keychron-q6-pro.patch`：标准 Arkey/AgentGlow Q6 Pro 示例。
- `firmware/qmk/codex_micro_lab.*` 与 `firmware/codex-micro-lab-*.patch`：可选 Q6 Pro / V1 Max Micro Lab 实验源码；不跟踪预编译二进制。
- `scripts/codex-micro-lab-*.mjs`：自实现配置协议和从 Arkey binding 到 13 个原生目标的同步工具。
- `profiles`：矩阵、LED、几何、传输和效果目录的版本化数据。
- `test` 与 CI：host、profile、协议边界、Swift 客户端、标准固件和 Lab 固件的检查。

当前示例目标是 **Keychron Q6 Pro ANSI Knob** 和 **Keychron V1 Max ANSI Knob**。V1 Max Lab v0.1.9 的自有硬件 USB 路径已由维护者确认；Q6 Pro Lab v0.1.5 保留独立的构建与验收边界。完整控制仅支持 USB；蓝牙保持普通键盘输入，但没有 Raw HID 同步。其他 QMK 键盘必须完成独立适配和真机恢复验证。

## 架构

```text
App Server mode
Arkey macOS app ── local RPC ──► Arkey daemon
                                      ├─ stdio JSONL ──► codex app-server
                                      └─ 32-byte Raw HID ──► Arkey QMK + AgentGlow

Codex Micro Lab mode (optional)
ChatGPT Desktop ── report 0x06 ───────► Q6 Pro / V1 Max Lab firmware
Arkey app / config CLI ── report 0x07 ─► mapping EEPROM
```

两条链路不共享协议，也不能混为一条“官方 Micro API”。标准 Arkey bridge 的 32-byte payload 属于 Arkey；Lab 的 64-byte 配置 report 同样属于 Arkey。详细组件与信任边界见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 默认推荐布局：原 AgentGlow 15 键

全新、未修改的 binding store 会在 daemon 首次启动时从 revision `0` 升到 revision `1`，并自动写入下表的 **15 键默认布局**。Agent Key 会按新运行时的稳定 task slot 0–5 关联本机 task ID，不复制其他机器的标识。已经绑定过或主动清空过的 store 不会被再次覆盖；用户随时可以重绑或清除。

| Arkey 动作 | Q6 Pro 实体控件 | App Server | Micro Lab 原生目标 |
| --- | --- | --- | --- |
| Agent Key 1–6 | 数字小键盘 `1`–`6` | 支持 | `AG00`–`AG05` |
| Approve | `F13` | 支持 | `ACT07` |
| Continue | `F14` | 支持 | `ACT09` |
| Cancel | `F15` | 支持 | **无；仅 App Server** |
| Decline | `F16` | 支持 | `ACT08` |
| Skill | 数字小键盘 `/` | 支持 | **无；仅 App Server** |
| Fast | 数字小键盘 `+` | 支持 | `ACT06` |
| Push to Talk | 数字小键盘 `0` | 支持 | `ACT10`（当前默认语义） |
| Send | 数字小键盘 `Enter` | 支持 | `ACT12` |
| Reasoning | 旋钮按下/旋转 | 支持 | `ENC_PRESS`；USB Lab 中旋转固定接管 |

Micro Lab 只有 **13 个原生目标**：六个 Agent 槽、六个 Command 槽和一个 Encoder 目标。另有四个 joystick 方向事件，但它们不是额外命令槽，也没有被确认等价于 Skill 或 Cancel。同步工具会明确跳过 Skill/Cancel，绝不会把它们猜测性映射到 joystick。方向事件只能由开发者显式配置，并由当前 ChatGPT Desktop 设置决定其实际效果。

## 已验证边界

| 部分 | 发布检查 | 当前边界 |
| --- | --- | --- |
| Node host/daemon | 类型检查与 Node tests | CI 验证；App Server 版本变化仍需本机 schema 检查 |
| macOS 客户端 | Swift tests、release build、ad-hoc codesign | CI 验证；应用仍依赖本机 Node 20+ |
| 标准 Q6 Pro 固件 | 固定 commit 的真实 QMK compile | compile-only；不等于当前机器已刷写验收 |
| Micro Lab 固件 | 显式风险确认、固定 commit compile、配置协议测试 | compile-only；身份、VIA、EEPROM 和 Desktop 兼容性需逐机验证 |
| 其他 QMK 键盘 | profile、firmware、host、CI、恢复与真机证据 | 尚未支持 |

## 快速开始：App Server 模式

前置条件：macOS 14+、Swift 6、Node.js 20+、已安装并可运行的 Codex CLI。实体控制还需要刷入标准 Arkey 固件的兼容 QMK 键盘。

```bash
git clone https://github.com/shuhari04/arkey.git
cd arkey

npm ci
npm run check
./scripts/check-codex-app-server.sh
swift test --package-path apps/ArkeyMac

./scripts/build-macos-app.sh
codesign --verify --deep --strict --verbose=2 build/Arkey.app
open build/Arkey.app
```

`build-macos-app.sh` 会编译并 ad-hoc 签名应用，打包 host、profiles、必要文档和 Lab 配置工具，但不会刷写键盘。发布 DMG 会额外内置 Node、CLI 和 `dfu-util`；首次使用仍可能需要 macOS 的手动安全确认。

## 更新与诊断中心

ARkey 3.0.3 在启动时及之后每 6 小时检查已签名的更新清单。若有新版本，主界面会显示蓝色下载按钮；用户可选任何已发布版本（含降级）。客户端会验证 Ed25519 清单签名、DMG 大小和 SHA-256，随后仅在 Finder 中打开 DMG，**不会**自动替换应用或刷写键盘固件。

“诊断中心”在本机保存脱敏 JSONL（最多 30 天、50 MB），可筛选更新、USB、HID、DFU 和错误事件并导出 ZIP。V1 Max 的配置 ACK 缺失、Report `0x06/0x07` 异常与 DFU 超时会生成独立会话；若用户安装了诊断服务，失败会以随机安装 ID 上传受限、脱敏事件。日志不包含按键内容、工作区、键盘序列号或原始 HID 报文。

发布者可使用 `scripts/build-release-manifest.mjs`、`scripts/seal-release-manifest.mjs` 与 `scripts/publish-arkey-release.sh` 生成并签名不可变版本目录。私钥、SSH 目标、服务器配置和真实诊断日志均不在本仓库；发布脚本要求通过环境变量显式提供这些值。

首次使用：

1. 确认 Codex CLI 已登录，或从客户端启动官方登录流程。
2. 选择工作目录并创建或显式导入 Codex task/thread。
3. daemon 会为全新 store 自动应用上表的 15 键布局；检查后可保留、重绑或清除。被绑定键会被独占，清除后恢复普通输入。
4. 使用 Composer、实体动作和 AgentGlow 灯效；daemon 停止、USB 断开或 watchdog 超时后，标准固件恢复原 RGB 状态。

CLI 可单独使用：

```bash
npm link
arkey start
arkey status
arkey test
arkey restore
arkey stop
```

## Keychron Q6 Pro 标准示例固件

示例锁定 Q6 Pro ANSI Knob、QMK target `keychron/q6_pro/ansi_encoder`、keymap `via`、Keychron commit `618127a725a1773e85f13455602cf6f72ab4de17` 和原始身份 `3434:0660`。

```bash
git clone --filter=blob:none --no-checkout \
  https://github.com/Keychron/qmk_firmware.git qmk_firmware
git -C qmk_firmware checkout 618127a725a1773e85f13455602cf6f72ab4de17
git -C qmk_firmware submodule update --init --recursive
python3 -m pip install -r qmk_firmware/requirements.txt
qmk config user.qmk_home="$PWD/qmk_firmware"

QMK_HOME="$PWD/qmk_firmware" ./scripts/build-q6-pro.sh
shasum -a 256 build/arkey-q6-pro-ansi-v0.1.0.bin
```

脚本只构建并恢复临时补丁，不执行 `qmk flash` 或 `dfu-util -D`。刷写前请阅读 [`docs/FIRMWARE.md`](docs/FIRMWARE.md)，备份 VIA 配置并准备匹配的官方恢复固件。

## Keychron V1 Max ANSI Knob 标准与 Lab 固件

V1 Max 标准 Arkey 示例固定到 Keychron QMK commit `bc1bdeb85f39cccd5e503f4d8f472078a8c1472a`、QMK target `keychron/v1_max/ansi_encoder:keychron`、STM32F401、STM32 DFU 和原身份 `3434:0913`。Lab 固件版本为 `0.1.9-v1max`，使用隔离的开发身份与 64-byte native-facing/config report。

```bash
ARKEY_QMK_HOME="$PWD/qmk-v1" ./scripts/build-v1-max-ansi.sh
QMK_HOME="$PWD/qmk-v1" \
  ./scripts/build-codex-micro-lab-v1-max.sh \
  --acknowledge-device-identity-test
```

V1 Lab 的默认映射为 `PgUp → Agent 1`、`PgDn → Agent 2`、`Home → PTT`、旋钮按下 → `ENC_PRESS`。它支持在应用中发起**已确认**的软件进入 DFU 请求；固件 ACK 后仍必须观察到 `0483:DF11`，用户才能明确开始刷写。无法枚举时应使用 Cable 模式的 Esc 插线或底部 Reset。独立刷写器由 `scripts/make-v1max-firmware-dmg.sh` 构建；它要求发布者显式提供已校验的官方恢复 `.bin`、`dfu-util` 和 `libusb` 路径，源码仓库不跟踪这些二进制。

## Codex Micro Lab 快速入口

只有在理解并接受设备身份测试风险、拥有目标键盘且完成恢复预检后，才构建实验固件：

```bash
QMK_HOME="$PWD/qmk_firmware" \
  ./scripts/build-codex-micro-lab-q6-pro.sh \
  --acknowledge-device-identity-test

QMK_HOME="$PWD/qmk_firmware_v1" \
  ./scripts/build-codex-micro-lab-v1-max.sh \
  --acknowledge-device-identity-test
```

该命令**只构建、不刷写**。刷入后，可通过 Arkey Mac 的 `CODEX MICRO LAB` 面板配置，或使用：

```bash
npm run codex-micro-lab:status
npm run codex-micro-lab:sync
node scripts/codex-micro-lab-config.mjs configure
```

精确同步会清除旧 Lab 映射，再把当前 `.arkey` binding 映射到 13 个原生目标；`--merge` 才会保留未覆盖的手工目标。Skill/Cancel 会被报告为跳过。完整命令、Report ID `0x07` 帧格式、EEPROM 行为、VIA 限制与恢复流程见 [`docs/CODEX_MICRO_LAB.md`](docs/CODEX_MICRO_LAB.md)。

## 适配其他 QMK 键盘

先阅读 [`docs/PORTING_QMK.md`](docs/PORTING_QMK.md)。适配至少需要：准确型号与 PCB revision、固定上游 commit、MCU/bootloader/恢复路径、原 VID/PID、Raw HID、RGB Matrix、矩阵与 LED 映射、profile/layout hash、可逆 patch、build-only 脚本、host/Swift/firmware tests 和真机验收。

默认只移植 App Server + 标准 Arkey bridge。Micro Lab 当前严格限于 Q6 Pro ANSI Knob 与 V1 Max ANSI Knob 示例；不得把第三方身份或兼容行为顺手扩散到普通 board port。

有硬件/QMK 经验但不熟悉代码的开发者，可以让 agent 分四阶段完成。每一阶段先审核输出，再单独授权下一阶段；不要把“实现、编译、刷写”合成一个指令。

### 1. 只读兼容性审计

```text
先只读审计这把键盘的精确型号、PCB revision、QMK target、MCU、bootloader、
原 VID/PID、Raw HID、RGB Matrix、矩阵、LED、旋钮、固件空间和官方恢复路径。
不要修改、编译或刷写。输出证据、缺口、风险和是否允许进入实现阶段。
默认只实现 Arkey App Server 模式；不要加入 Codex Micro Lab 身份或协议。
```

### 2. 在新分支实现完整适配

```text
基于已确认的审计，在 codex/<board>-arkey-port 新分支完成适配。一次提交内包含
profile/layout hash、host registry/runtime、可逆 QMK 集成、固定 commit 的 build-only
脚本、Node/Swift/firmware tests、CI、上游许可与恢复文档。保留未绑定按键的普通输入
和 watchdog/fail-open；不要引入 Micro Lab 身份，不要刷写。最后列出改动、验证结果、
仍未验证的真机边界和回滚方法。
```

### 3. 只构建并审计产物

```text
只在干净且固定 commit 的 QMK tree 中编译，不刷写。先验证型号、target、MCU、
bootloader、原 VID/PID 和 patch guard；完成后报告 binary 路径、字节数、SHA-256、
编译器和 QMK commit，并证明脚本成功、失败或中断后都不会覆盖用户文件，且上游
worktree 恢复干净。任何 guard 不匹配都必须停止。
```

### 4. 人工刷写前预检与真机验收

```text
只做刷写预检，暂不写入设备。逐项确认准确 PCB revision、VIA 备份、型号匹配的
官方恢复固件及校验值、备用输入设备、待刷 binary SHA-256、DFU 设备/alt setting、
内存地址和物理验收表。缺一项就停止；即使全部通过，也必须在实际写入前再次向我
请求明确授权，不能自动进入 DFU 或自动运行 dfu-util/qmk flash。
```

刷写后让 agent 逐项记录普通输入、层、旋钮、VIA、RGB、USB 重连、watchdog、蓝牙降级和官方恢复结果；全部通过前只能写 `compile-only`，不能声称该键盘已受支持。Micro Lab 不是通用移植模板，其他键盘默认只接 App Server + 标准 Arkey bridge。

## 隐私与安全

- Arkey 在 `~/.arkey` 保存设置、实体 binding、task/thread 标识和必要状态；不主动持久化 prompt、回复正文或麦克风音频。
- Codex 登录和 session 仍由本机 Codex CLI 管理；Arkey 不复制 access token。
- App Server 仅通过本地子进程 stdio 使用，不开放网络监听。
- Lab 矩阵映射保存在 QMK user EEPROM；客户端可能缓存不含会话正文的映射快照。native PTT 的音频和转写由当前 ChatGPT Desktop 处理，不经过 Arkey App Server daemon。
- 不要在 issue、日志或测试 fixture 中提交 token、task/thread ID、prompt、回复、真实用户路径或设备序列号。
- 安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告。

## 贡献

欢迎修复、测试、文档改进和新键盘适配。请先阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)。仓库不接受 binary-only 固件、第三方私有 SDK/资源、自动刷写、身份授权误导、研究报告、会话交接文档或把 compile-only 写成 hardware verified 的 PR。

## 许可证

本仓库采用路径分层许可：

- 自有 macOS 客户端、Node host、脚本、配置协议、profiles、tests、CI 和文档：[`PolyForm-Noncommercial-1.0.0`](LICENSES/PolyForm-Noncommercial-1.0.0.txt)。
- 修改 Keychron/QMK 文件的标准及 Lab patches：适用的 GPL 上游条款，当前 scope map 标为 [`GPL-2.0-only`](LICENSES/GPL-2.0-only.txt)。
- 标准 `firmware/qmk/arkey.*` 等带 MIT SPDX header 的独立模块：[`MIT`](LICENSES/MIT.txt)。
- `firmware/qmk/codex_micro_lab.*`：文件头标注的 `GPL-2.0-or-later`。
- 第三方依赖：保留上游许可，见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
- Arkey 名称和 Logo：不随代码许可授权，见 [`TRADEMARKS.md`](TRADEMARKS.md)。

PolyForm 的非商业限制不符合 [OSI Open Source Definition](https://opensource.org/osd)，因此 Arkey 应准确称为 **public source / source-available**，而不是单一 OSI 开源作品。GPL/MIT firmware 的权利边界与 host 不同；任何源码许可都不授权冒用第三方 USB 身份或商标。本说明不是法律意见，精确许可证文本优先。

## 参考

- [Codex App Server 官方文档](https://developers.openai.com/codex/app-server/)
- [OpenAI Codex repository](https://github.com/openai/codex)
- [QMK Raw HID](https://docs.qmk.fm/features/rawhid/)
- [Keychron QMK firmware](https://github.com/Keychron/qmk_firmware)
- [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)
