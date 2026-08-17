# Codex Micro Lab 操作与协议说明

Codex Micro Lab 是 Arkey 中一条隔离的、非官方的本地互操作实验链路。它只面向开发、研究、兼容性验证和自有硬件测试，不是 OpenAI 或 Work Louder 发布、授权或支持的 Codex Micro 接入方式，也不属于 Codex App Server API。

> [!WARNING]
> 实验固件会让 Keychron Q6 Pro 在 USB 枚举和 HID 行为上临时呈现当前实验所需的兼容身份。该 USB 身份并未分配给 Arkey、Keychron Q6 Pro 或使用者。不要销售或分发刷入该固件的键盘，不要将其表述为官方 Codex Micro，也不要把源码许可理解为第三方身份、商标、服务接入或商业使用授权。使用者必须自行核对适用条款和当地法律。本说明不是法律意见。

## 1. 支持范围

当前实验构建严格锁定：

- Keychron Q6 Pro ANSI Knob；
- QMK target `keychron/q6_pro/ansi_encoder`，keymap `via`；
- Keychron QMK commit `618127a725a1773e85f13455602cf6f72ab4de17`；
- STM32L432、STM32 ROM DFU；
- USB 模式；
- 本机当前 ChatGPT Desktop 版本所接受的实验 HID 行为。

不在这个列表中的键盘、PCB revision、Desktop 版本和操作系统均未声明兼容。构建通过只代表 compile-only，不代表真机或未来版本验证。

Lab 固件不包含 Work Louder 私有 SDK。native-facing 行为由 Arkey/QMK 源码独立实现；配置通道则完全是 Arkey 自定义协议。

## 2. 两个 HID 协议面

```text
ChatGPT Desktop ── Report ID 0x06 ──► native-facing compatibility surface

Arkey Mac / config CLI ── Report ID 0x07 ──► Arkey mapping protocol
                                                  └─ QMK user EEPROM
```

### Report `0x06`：native-facing 兼容面

该 64-byte report 承载当前实验观察到的版本/设备状态、六任务灯光、keys/ambient 灯光、按键、旋钮和方向事件。它依赖未公开、未承诺稳定的 Desktop 行为，可能在任何更新后失效。

这部分不是 Codex App Server，也不能用于证明与官方硬件协议完全一致。

### Report `0x07`：Arkey 自实现配置协议

配置 report 固定 64 bytes：

| Byte | 含义 |
| --- | --- |
| `0` | Report ID `0x07` |
| `1` | Magic `0xA7` |
| `2` | 配置协议版本 `1` |
| `3` | Opcode |
| `4` | 8-bit sequence |
| `5` | Payload length，最大 58 |
| `6..63` | Payload 与零填充 |

macOS HID API 有时会在读取结果中省略 Report ID；客户端只在收到 63 bytes 且首字节为 `0xA7` 时补回 `0x07`，随后仍执行 magic、版本和长度校验。

| Opcode | 名称 | 请求/结果 |
| --- | --- | --- |
| `0x01` | `hello` | 返回 target 数、矩阵、encoder 状态和 LED 数 |
| `0x02` | `mappings` | 返回全部 target 的 `target,row,column` |
| `0x03` | `capture` | 开始捕获一个 target，先 ACK，按键后发送 `captured` |
| `0x04` | `set` | 写入 `target,row,column`；同一实体位置只保留一个 target |
| `0x05` | `clear` | 清除一个 target |
| `0x06` | `encoder` | 兼容旧客户端；当前版本只接受/保持 enabled，不支持关闭 |
| `0x07` | `reset` | 恢复本版本的 Q6 Pro 预置映射 |
| `0x13` | `captured` | 返回捕获的 target、矩阵位置和可用 LED index |
| `0x7F` | `ack` | 返回原 opcode 和状态码 |

映射和校验值保存在 QMK user EEPROM block。实验固件的 EEPROM 布局不同于普通 Arkey/官方固件；刷写前必须导出 VIA 配置，恢复普通固件后可能需要重新导入。

## 3. 13 个原生目标与 joystick 边界

Micro Lab 的默认同步只使用 13 个原生目标：

- `agent-1` … `agent-6`：六个 Agent 槽，对应 `AG00` … `AG05`；
- `command-1` … `command-6`：六个 Command 槽，对应当前观察到的 `ACT06`、`ACT07`、`ACT08`、`ACT09`、`ACT10`、`ACT12`；
- `encoder-press`：Encoder 目标，对应 `ENC_PRESS`。USB Lab 模式同时固定接管旋钮旋转。

固件配置表还保留 `joystick-up/right/down/left` 四个方向 target，用于显式发送方向事件。它们不是额外 Command 槽，也没有确认等价于 Arkey 的 Skill 或 Cancel。

`sync-arkey` 的语义映射固定为：

| Arkey action | Lab target |
| --- | --- |
| `task_agent` slot 0–5 | `agent-1` … `agent-6` |
| `fast` | `command-1` / `ACT06` |
| `approve` | `command-2` / `ACT07` |
| `decline` | `command-3` / `ACT08` |
| `continue` | `command-4` / `ACT09` |
| `ptt` | `command-5` / `ACT10` |
| `send` | `command-6` / `ACT12` |
| `reasoning` | `encoder-press` |
| `skill`、`cancel` | 跳过；仅 App Server 模式可用 |

工具不得把 Skill/Cancel 猜测性塞进 joystick。需要方向事件时，开发者必须显式执行 `capture joystick-*` 或 `map joystick-* ...`，并自行验证当前 Desktop 设置中的真实效果。交互捕获由 host 和固件分别执行 30 秒超时；超时后固件会解除捕获，之后的普通按键不会被延迟吞掉或改写映射。

## 4. Q6 Pro 预置布局

首次初始化或执行 `reset` 后，固件使用原 AgentGlow 数字小键盘优先布局：

| Target | 实体控件 |
| --- | --- |
| Agent 1–6 | 数字小键盘 `1`–`6` |
| Fast / `ACT06` | 数字小键盘 `+` |
| Approve / `ACT07` | `F13` |
| Decline / `ACT08` | `F16` |
| Continue / `ACT09` | `F14` |
| PTT / `ACT10` | 数字小键盘 `0` |
| Send / `ACT12` | 数字小键盘 `Enter` |
| Encoder | Q6 Pro 旋钮 |

四个 joystick 方向默认未分配。`F15` 的 Cancel 和数字小键盘 `/` 的 Skill 只属于 App Server 15 键布局，在 Lab 原生映射中保持普通键行为。

被映射的实体键在 USB Lab 模式下由兼容面独占，不再输出其原键值；清除 target 后恢复普通输入。蓝牙不发送 Lab HID 事件，继续走普通键盘处理链。当前 Lab 固件在 USB 下固定接管旋钮旋转，不能通过配置协议恢复音量功能；要恢复普通旋钮行为必须刷回标准 Arkey 或官方固件。

## 5. 构建前预检

准备以下内容后再继续：

1. 确认键盘是 Q6 Pro ANSI Knob 和准确 PCB revision。
2. 导出 VIA keymap、macro、layer、encoder 和 RGB 设置。
3. 保存型号完全匹配的 Keychron 官方恢复固件及其 SHA-256。
4. 准备另一把键盘，确认可以进入 STM32 DFU。
5. 使用干净的 Keychron QMK tree，并 checkout 固定 commit。
6. 阅读根目录 `LICENSE`、`THIRD_PARTY_NOTICES.md` 和本页风险说明。

构建命令必须带显式身份测试确认：

```bash
QMK_HOME="$PWD/qmk_firmware" \
  ./scripts/build-codex-micro-lab-q6-pro.sh \
  --acknowledge-device-identity-test
```

当前产物：

```text
build/arkey-q6-pro-codex-micro-lab-v0.1.5.bin
```

脚本验证目标、MCU、bootloader、原 Keychron VID/PID 和固定 QMK commit；拒绝修改脏的上游文件，并在成功、失败或中断后恢复所有临时 patch。它不会运行 `qmk flash`、进入 DFU 或调用 `dfu-util -D`。

```bash
shasum -a 256 build/arkey-q6-pro-codex-micro-lab-v0.1.5.bin
git -C qmk_firmware status --short
```

只有在 worktree 干净、恢复资料完整并再次获得操作者明确确认后，才能按 [`FIRMWARE.md`](FIRMWARE.md) 的人工流程刷写。不要让 agent 自动越过确认点。

## 6. 配置与同步

刷写完成并使用 USB 连接后，先读取设备状态：

```bash
npm run codex-micro-lab:status
```

### 从当前 Arkey binding 同步

```bash
npm run codex-micro-lab:sync
```

默认是精确同步：先清除 17 项旧映射，再写入 `.arkey/bindings-v1.json` 和 `.arkey/appserver-tasks-v1.json` 可解析出的 13 个原生目标，并保持 encoder enabled。若只想覆盖已出现的目标：

```bash
node scripts/codex-micro-lab-config.mjs sync-arkey --merge
```

Agent Key 根据 task 的稳定 `slotIndex` 0–5 选择目标；工具不会把本机 task ID 注入 ChatGPT Desktop。Skill、Cancel、超出六槽的 task 或缺失矩阵位置的 binding 会被列为 skipped。

### 交互配置

```bash
node scripts/codex-micro-lab-config.mjs configure
node scripts/codex-micro-lab-config.mjs capture agent-1
node scripts/codex-micro-lab-config.mjs map agent-1 r4c17
node scripts/codex-micro-lab-config.mjs clear agent-1
node scripts/codex-micro-lab-config.mjs reset
```

`map` 使用 profile control ID，不使用键帽文字猜测矩阵。也可以在 Arkey Mac 客户端的 `CODEX MICRO LAB` 面板选择 target 后点击实体键。ChatGPT Desktop 占用 HID 时，配置写入可能暂时只能显示“待读回验证”；稍后刷新并成功读取 EEPROM 后才可视为 verified。

当前版本中的：

```bash
node scripts/codex-micro-lab-config.mjs encoder on
```

只是兼容命令。`encoder off` 会被拒绝，固件收到旧 disable 请求也会保持 enabled。

## 7. PTT 与灯光

当前 Desktop 默认把 `ACT10` 用作 native PTT，因此工具提供 `ptt` 和 `voice-ptt` 别名，二者都只解析到 `command-5`。实际行为以当前 ChatGPT Desktop 的 Codex Micro 设置为准；如果用户修改了 ACT10 动作，Arkey 不能继续宣称它仍是 PTT。

native PTT 的麦克风、音频和转写由 ChatGPT Desktop 处理，不经过 Arkey 的 App Server daemon 或本地 `SpeechCoordinator`。任务灯光和 keys/ambient 光效由 report `0x06` 投射到当前映射的 LED；Q6 没有官方设备相同的灯光几何，因此 ambient 只能作为全键盘背景近似。

Lab `0.1.5` 直接使用 Desktop 下发的 packed RGB、brightness、effect 和 speed，不经过 App Server 模式的 `profiles/effects-v1.json`，也不再对 ambient 额外降亮。当前验证基线 `26.715.61943` 的日常状态语义如下：

| 状态 | 颜色 | Agent 键 |
| --- | --- | --- |
| Working | `#304FFE` | 普通槽 solid；selected/pulsing 槽 breath，speed `0.4` |
| Unread | `#00FF4C` | 普通槽 solid；selected/pulsing 槽 breath，speed `0.4` |
| Idle | `#FFFFFF` | 普通槽 solid；selected/pulsing 槽 breath，speed `0.4` |
| Awaiting approval/response | `#FF6D00` | 普通槽 solid；selected/pulsing 槽 breath，speed `0.4` |
| Error | `#FF0033` | 普通槽 solid；selected/pulsing 槽 breath，speed `0.4` |
| Off | `#000000` | off，brightness `0` |

选择任务后的 4 秒强调窗口会让 Command 键以当前 ambient 颜色 solid 点亮；选中 Working 时 ambient 使用蓝色 snake。语音优先覆盖 ambient：recording 为 `#2E8B57` snake、processing 为白色 snake、completed 为白色 solid。两种 snake 的 speed 都是 `0.4`。

固件识别 Micro 的 `off / solid / snake / rainbow / breath / gradient / shallowBreath` 完整编号。当前 Desktop 日常链路实际使用的 `off / solid / snake / breath` 会保留下发颜色、亮度和 speed 语义；在 Arkey 的 Q6 渲染器中，`speed=0` 保持静止，普通 breath 可降到 0，shallowBreath 保留 50% 下限。当前服务恒发 `magic=0`、`sk=0`、`sa=0`；固件会解析并保留这些字段，但不猜测尚未观察到的同步行为。

`rainbow / gradient / shallowBreath` 当前不会由日常 Desktop 状态链下发，其 Q6 渲染属于实验适配，不代表已复刻原设备逐帧算法。Q6 的 LED 数量、排列、透光材料和电气校准也与原设备不同，因此这里的“对齐”指当前 Desktop 日常状态、packed RGB、亮度、效果类型和速度控制语义对齐；snake 路径、呼吸周期/曲线及肉眼色差仍需原设备 A/B 测量，不能描述为物理像素级一致。

## 8. 恢复与验收

恢复普通 Arkey 模式时，重新刷入 `scripts/build-q6-pro.sh` 构建的标准固件；恢复出厂状态时使用型号完全匹配的 Keychron 官方固件。恢复后重新导入 VIA 备份。

首次真机验收至少检查：

- 普通输入和未映射键；
- 13 个预置目标的 press/release；
- Skill/Cancel 未被错误映射到 joystick；
- encoder press、顺逆时针方向和 USB 独占；
- 任务灯、keys/ambient、PTT 状态灯；
- USB 重连、Desktop 重启、EEPROM 读回；
- 蓝牙普通输入降级；
- 进入 DFU、刷回标准/官方固件和恢复 VIA 配置。

只有完成并记录这些步骤后，才能描述为“在该设备/版本上验证”；否则必须写成 compile-only 或待验证。
