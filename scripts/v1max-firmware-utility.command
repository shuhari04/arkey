#!/bin/bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TOOLS="$ROOT/Tools"
DFU="$TOOLS/dfu-util"
PROBE="$TOOLS/arkey-v1max-hid-probe"
export DYLD_LIBRARY_PATH="$TOOLS${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
ARKKEY="$ROOT/Firmware/arkey-v1-max-ansi-knob-v0.1.0.bin"
LAB="$ROOT/Firmware/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
OFFICIAL="$ROOT/Firmware/keychron-v1-max-ansi-knob-v1.1.1.bin"
[[ -x "$DFU" && -x "$PROBE" && -f "$ARKKEY" && -f "$LAB" && -f "$OFFICIAL" ]] || { echo "安装包不完整。"; read -r; exit 1; }

diagnose() {
  local log="${TMPDIR:-/tmp}/ARkey-V1-Max-Diagnostic-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "ARkey V1 Max diagnostic"
    echo "timestamp: $(date -Iseconds)"
    echo "macOS: $(sw_vers -productVersion 2>/dev/null || true)"
    echo
    echo "=== expected identities ==="
    echo "Stock / ARkey V1 Max: 3434:0913, Raw HID FF60:0061"
    echo "Codex Micro Lab:       303A:8360, Raw HID FF00, reports 06/07"
    echo "STM32 DFU bootloader:  0483:DF11"
    echo
    echo "=== USB devices ==="
    system_profiler SPUSBDataType 2>&1 | grep -E -A8 -B3 'Keychron|Work Louder|3434|0913|303A|8360|0483|DFU|STM32' || echo "No matching USB device reported."
    echo
    echo "=== HID interfaces ==="
    ioreg -r -c IOHIDDevice -l -w 0 2>&1 \
      | grep -E '"(Product|VendorID|ProductID|PrimaryUsagePage|PrimaryUsage|MaxInputReportSize|MaxOutputReportSize|DebugState)" =' \
      | grep -E -i 'ARkey V1 Max|12346|33632|65280|SetReportCount|GetReportCount|InputReportCount' \
      || echo "No matching HID interface summary reported."
    echo
    echo "=== Codex Micro config protocol (read-only) ==="
    "$PROBE" 2>&1 || true
    echo
    echo "=== DFU probe ==="
    "$DFU" -l 2>&1 || true
    echo
    echo "=== packaged firmware ==="
    shasum -a 256 "$ARKKEY" "$LAB" "$OFFICIAL"
  } | tee "$log"
  echo
  echo "诊断日志已保存：$log"
}

roundtrip_diagnose() {
  local log="${TMPDIR:-/tmp}/ARkey-V1-Max-Custom-Mapping-Test-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "ARkey V1 Max custom mapping round-trip test"
    echo "timestamp: $(date -Iseconds)"
    echo "This writes one existing mapping back unchanged, requires firmware ACK, then reads it back."
    "$PROBE" --roundtrip
  } 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  echo
  echo "往返测试日志已保存：$log"
  return "$status"
}

software_dfu() {
  local log="${TMPDIR:-/tmp}/ARkey-V1-Max-Software-DFU-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "ARkey V1 Max software DFU request"
    echo "timestamp: $(date -Iseconds)"
    "$PROBE" --enter-dfu
    echo "Waiting for STM32 DFU (0483:DF11)..."
    for _ in $(seq 1 20); do
      if "$DFU" -l 2>&1 | grep -qi '0483:df11'; then
        echo "DFU_DETECTED=YES"
        exit 0
      fi
      sleep 0.25
    done
    echo "DFU_DETECTED=NO"
    exit 11
  } 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  echo
  echo "软件 DFU 日志已保存：$log"
  return "$status"
}

echo "仅适用于 Keychron V1 Max ANSI/US Knob。"
echo "ARkey 独立刷写器 3.0.3（64 字节 HID 报告修正版）。"
echo "普通/ARkey：3434:0913；Codex Micro Lab：303A:8360；DFU：0483:DF11。"
echo "切至 Cable，按住 Esc（或空格下方 Reset）后插入 USB。"
while :; do
  echo "1) 刷入 ARkey V1 Max"
  echo "2) 刷入 V1 Max Codex Micro Lab"
  echo "3) 刷回 Keychron 官方 V1.1.1"
  echo "4) 检查连接状态并保存诊断日志"
  echo "5) 验证自定义键位写入、固件确认和读回（同值写回，不改变现有映射）"
  echo "6) 请求已刷入的 V1 Max Lab v0.1.9 从软件进入 DFU"
  echo "7) 退出"
  read -r -p "请选择：" choice
  case "$choice" in
    1) firmware="$ARKKEY"; expected="cdd0cd45c833c27d3ce027ab4d63f108317b7d250ffbaecba2dcfa06cbb37dc2"; label="ARkey V1 Max"; break ;;
    2) firmware="$LAB"; expected="6bd2aa35918c754de07f9752ffcd54aef05f5cc0f3ce08e8085821f9cf1f68b3"; label="V1 Max Codex Micro Lab v0.1.9（支持软件进入 DFU，保留 Esc/Reset 恢复）"; break ;;
    3) firmware="$OFFICIAL"; expected="0727fdce9af4dfeaaa099e6a8a0c44d30da113ce770ac4bcc15c9e502c444498"; label="Keychron 官方 V1.1.1"; break ;;
    4) diagnose; read -r -p "按回车返回菜单…" ;;
    5) read -r -p "将把一个现有映射原值写回并读回验证。输入 TEST 确认：" test_confirmation
       if [[ "$test_confirmation" == "TEST" ]]; then roundtrip_diagnose || true; fi
       read -r -p "按回车返回菜单…" ;;
    6) read -r -p "仅对 V1 Max Codex Micro Lab v0.1.9 有效；键盘会断连。输入 DFU 确认：" dfu_confirmation
       if [[ "$dfu_confirmation" == "DFU" ]]; then software_dfu || true; fi
       read -r -p "按回车返回菜单…" ;;
    7) exit 0 ;;
    *) echo "请输入 1、2、3、4、5、6 或 7。" ;;
  esac
done
[[ "$(shasum -a 256 "$firmware" | awk '{print $1}')" == "$expected" ]] || { echo "固件 SHA-256 不匹配，已拒绝刷写。"; read -r; exit 1; }
"$DFU" -l | grep -q '0483:df11' || { echo "未检测到 STM32 DFU。"; read -r; exit 1; }
read -r -p "将写入 ${label}。输入 FLASH 确认：" confirmation
[[ "$confirmation" == "FLASH" ]] || exit 0
"$DFU" -d 0483:DF11 -a 0 -s 0x08000000:leave -D "$firmware"
echo "完成。请重新插拔键盘并验证普通打字、旋钮与灯光。"
read -r
