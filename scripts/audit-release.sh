#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Release audit requires a Git worktree." >&2
  exit 1
}

is_release_path() {
  case "$1" in
    .github/workflows/ci.yml|.gitignore|AGENTS.md|CONTRIBUTING.md|LICENSE|README.md|SECURITY.md|THIRD_PARTY_NOTICES.md|TRADEMARKS.md|package.json|package-lock.json|tsconfig.json) return 0 ;;
    LICENSES/GPL-2.0-only.txt|LICENSES/MIT.txt|LICENSES/PolyForm-Noncommercial-1.0.0.txt) return 0 ;;
    assets/arkey-logo.png) return 0 ;;
    apps/ArkeyMac/Package.swift|apps/ArkeyMac/Package.resolved|apps/ArkeyMac/Launcher/ArkeyLauncher.c) return 0 ;;
    apps/ArkeyMac/Resources/Info.plist|apps/ArkeyMac/Resources/Arkey.icns|apps/ArkeyMac/Resources/Arkey.iconset/*.png) return 0 ;;
    apps/ArkeyMac/Sources/ArkeyMac/*.swift|apps/ArkeyMac/Sources/ArkeyMac/Resources/arkey.png) return 0 ;;
    apps/ArkeyMac/Tests/ArkeyMacTests/*.swift) return 0 ;;
    docs/ARCHITECTURE.md|docs/CODEX_MICRO_LAB.md|docs/FIRMWARE.md|docs/PORTING_QMK.md) return 0 ;;
    firmware/UPSTREAM.md|firmware/keychron-q6-pro.patch|firmware/keychron-v1-max-ansi.patch) return 0 ;;
    firmware/codex-micro-lab-q6-pro.patch|firmware/codex-micro-lab-qmk-hid.patch|firmware/codex-micro-lab-qmk-encoder.patch) return 0 ;;
    firmware/codex-micro-lab-v1-max.patch|firmware/codex-micro-lab-v1-max-hid.patch|firmware/codex-micro-lab-v1-max-encoder.patch) return 0 ;;
    firmware/qmk/arkey.c|firmware/qmk/arkey.h|firmware/qmk/arkey_generated.h|firmware/qmk/arkey_v1max_generated.h|firmware/qmk/rgb_matrix_kb.inc) return 0 ;;
    firmware/qmk/codex_micro_lab.c|firmware/qmk/codex_micro_lab.h) return 0 ;;
    profiles/effects-schema.json|profiles/effects-v1.json|profiles/keychron-q6-pro-ansi.json|profiles/keychron-v1-max-ansi-knob.json|profiles/schema.json) return 0 ;;
    scripts/audit-release.sh|scripts/build-macos-app.sh|scripts/build-q6-pro.sh|scripts/build-v1-max-ansi.sh|scripts/check-codex-app-server.sh|scripts/check-command-surface.sh|scripts/generate-firmware-contract.mjs|scripts/generate-v1-max-profile.mjs) return 0 ;;
    scripts/build-codex-micro-lab-q6-pro.sh|scripts/build-codex-micro-lab-v1-max.sh|scripts/codex-micro-lab-bindings.mjs|scripts/codex-micro-lab-config.mjs|scripts/v1max-hid-probe.swift) return 0 ;;
    scripts/build-release-manifest.mjs|scripts/seal-release-manifest.mjs|scripts/publish-arkey-release.sh|scripts/make-v1max-dmg.sh|scripts/make-v1max-firmware-dmg.sh|scripts/v1max-firmware-utility.command) return 0 ;;
    server/arkey-diagnostics-api.mjs|src/*.ts|test/*.test.ts|test/*.test.mjs) return 0 ;;
    *) return 1 ;;
  esac
}

is_sensitive_path() {
  case "$1" in
    README.md|AGENTS.md|CONTRIBUTING.md|LICENSE|THIRD_PARTY_NOTICES.md|package.json|package-lock.json) return 0 ;;
    docs/ARCHITECTURE.md|docs/CODEX_MICRO_LAB.md|docs/FIRMWARE.md) return 0 ;;
    .github/workflows/ci.yml|scripts/audit-release.sh|scripts/build-macos-app.sh|scripts/make-v1max-dmg.sh|scripts/make-v1max-firmware-dmg.sh|scripts/publish-arkey-release.sh) return 0 ;;
    apps/ArkeyMac/Sources/ArkeyMac/CodexMicroLab*.swift|apps/ArkeyMac/Sources/ArkeyMac/CodexMicroMappingWorkspaceView.swift|apps/ArkeyMac/Sources/ArkeyMac/FirmwareFlashingService.swift) return 0 ;;
    apps/ArkeyMac/Sources/ArkeyMac/CommandSurfaceStore.swift|apps/ArkeyMac/Sources/ArkeyMac/ContentView.swift|apps/ArkeyMac/Sources/ArkeyMac/KeyboardStageView.swift|apps/ArkeyMac/Sources/ArkeyMac/OnboardingFlowView.swift) return 0 ;;
    apps/ArkeyMac/Tests/ArkeyMacTests/*.swift) return 0 ;;
    firmware/codex-micro-lab-*.patch|firmware/qmk/codex_micro_lab.c|firmware/qmk/codex_micro_lab.h) return 0 ;;
    profiles/keychron-v1-max-ansi-knob.json|src/profile.ts|src/runtime.ts|src/transport.ts) return 0 ;;
    scripts/build-codex-micro-lab-q6-pro.sh|scripts/build-codex-micro-lab-v1-max.sh|scripts/codex-micro-lab-bindings.mjs|scripts/codex-micro-lab-config.mjs|scripts/v1max-hid-probe.swift|scripts/v1max-firmware-utility.command) return 0 ;;
    server/arkey-diagnostics-api.mjs|test/codex-micro-lab*.test.ts|test/codex-micro-lab*.test.mjs) return 0 ;;
    *) return 1 ;;
  esac
}

# Audit tracked files plus every untracked, non-ignored release candidate. This
# makes the local check useful before a newly added Lab file is staged.
candidates=$(git ls-files --cached --others --exclude-standard)

unexpected=$(
  printf '%s\n' "$candidates" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_release_path "$path" || printf '%s\n' "$path"
  done
)

if [ -n "$unexpected" ]; then
  echo "Release audit failed: files outside the source-release allowlist:" >&2
  printf '%s\n' "$unexpected" >&2
  exit 1
fi

required_files="
README.md
CONTRIBUTING.md
LICENSE
THIRD_PARTY_NOTICES.md
docs/CODEX_MICRO_LAB.md
apps/ArkeyMac/Sources/ArkeyMac/CodexMicroLabService.swift
apps/ArkeyMac/Sources/ArkeyMac/CodexMicroLabConfiguratorView.swift
firmware/codex-micro-lab-q6-pro.patch
firmware/codex-micro-lab-qmk-hid.patch
firmware/codex-micro-lab-qmk-encoder.patch
firmware/codex-micro-lab-v1-max.patch
firmware/qmk/codex_micro_lab.c
firmware/qmk/codex_micro_lab.h
scripts/build-codex-micro-lab-q6-pro.sh
scripts/build-codex-micro-lab-v1-max.sh
scripts/build-v1-max-ansi.sh
scripts/codex-micro-lab-bindings.mjs
scripts/codex-micro-lab-config.mjs
test/codex-micro-lab.test.ts
test/codex-micro-lab-bindings.test.ts
"

for path in $required_files; do
  [ -f "$path" ] || {
    echo "Release audit failed: required source file is missing: $path" >&2
    exit 1
  }
done

bad_names=$(
  printf '%s\n' "$candidates" | grep -E '(^|/)(node_modules|dist|build|\.build|\.swiftpm|research)(/|$)|(^|/)\.DS_Store$|(^|/).*(RESEARCH|REPORT|STRATEGY|AUDIT|HANDOFF|NOTES).*\.md$|(^|/)(AGENT_HANDOFF|PREFLIGHT-AUDIT)\.md$|\.(bin|hex|uf2|dmg|zip|tar|gz)$' || true
)
if [ -n "$bad_names" ]; then
  echo "Release audit failed: generated, binary, archive, or process-report files are present:" >&2
  printf '%s\n' "$bad_names" >&2
  exit 1
fi

local_paths=$(
  printf '%s\n' "$candidates" | while IFS= read -r path; do
    [ -f "$path" ] || continue
    [ "$path" = "scripts/audit-release.sh" ] && continue
    if LC_ALL=C grep -Iq . "$path" && LC_ALL=C grep -nE '/Users/[^/]+/' "$path" >/dev/null; then
      printf '%s\n' "$path"
    fi
  done
)
if [ -n "$local_paths" ]; then
  echo "Release audit failed: local absolute user paths are present:" >&2
  printf '%s\n' "$local_paths" >&2
  exit 1
fi

# Native-facing identity/protocol material is allowed only in the documented,
# isolated Lab implementation and the files that expose or govern that feature.
sensitive_leaks=$(
  printf '%s\n' "$candidates" | while IFS= read -r path; do
    [ -f "$path" ] || continue
    LC_ALL=C grep -Iq . "$path" || continue
    LC_ALL=C grep -qiE 'codex[_-]?micro|303A.?8360|0x303A|0x8360|v[.]oai[.]|Work[[:space:]_-]*Louder' "$path" || continue
    is_sensitive_path "$path" || printf '%s\n' "$path"
  done
)
if [ -n "$sensitive_leaks" ]; then
  echo "Release audit failed: Codex Micro Lab material escaped its allowlisted boundary:" >&2
  printf '%s\n' "$sensitive_leaks" >&2
  exit 1
fi

grep -q '13 个原生目标' README.md || {
  echo "Release audit failed: README must state the 13-target native Lab boundary." >&2
  exit 1
}
grep -q 'Skill/Cancel' README.md || {
  echo "Release audit failed: README must state that Skill/Cancel are App Server-only." >&2
  exit 1
}
grep -q -- '--acknowledge-device-identity-test' scripts/build-codex-micro-lab-q6-pro.sh || {
  echo "Release audit failed: Lab build lacks the explicit identity-test acknowledgement." >&2
  exit 1
}

node <<'NODE'
const { readFileSync } = require("node:fs");
const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const requiredScripts = [
  "codex-micro-lab:status",
  "codex-micro-lab:configure",
  "codex-micro-lab:sync",
];
for (const name of requiredScripts) {
  if (!pkg.scripts?.[name]) throw new Error(`package.json is missing ${name}`);
}
const packed = new Set(pkg.files ?? []);
for (const path of [
  "assets/arkey-logo.png",
  "apps/ArkeyMac/Package.swift",
  "apps/ArkeyMac/Package.resolved",
  "apps/ArkeyMac/Resources",
  "apps/ArkeyMac/Sources",
  "apps/ArkeyMac/Tests",
  "docs/CODEX_MICRO_LAB.md",
  "scripts/build-codex-micro-lab-q6-pro.sh",
  "scripts/build-codex-micro-lab-v1-max.sh",
  "scripts/build-v1-max-ansi.sh",
  "scripts/codex-micro-lab-bindings.mjs",
  "scripts/codex-micro-lab-config.mjs",
  "test/codex-micro-lab.test.ts",
  "test/codex-micro-lab-bindings.test.ts",
]) {
  if (!packed.has(path)) throw new Error(`npm source package allowlist is missing ${path}`);
}
NODE

echo "Release audit passed."
