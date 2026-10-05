# Contributing · 贡献指南

Thanks for your interest in improving the Blue Whale Pet! / 感谢你愿意改进蓝鲸小深！

## How to set up / 环境准备

```bat
git clone https://github.com/Hai-mian-33/DeepSeek-Harness-Pet.git
cd deepseek-pet
node tests\run-tests.mjs
```

No `npm install` is needed — the bridge uses only Node built-ins. / 无需 `npm install`——bridge 只使用 Node 内置模块。

Windows 10/11 + Node.js ≥ 18 + Windows PowerShell 5.1 (built in). / Windows 10/11 + Node.js ≥ 18 + 系统自带的 Windows PowerShell 5.1。

## Ground rules / 基本约定

1. **Stay dependency-free.** / **保持零依赖。** The bridge and core import Node built-ins only; the shell uses WPF via PowerShell. If a feature seems to need a package, reconsider. / bridge 与 core 只允许 Node 内置模块，shell 通过 PowerShell 使用 WPF。如果一个功能看起来需要引包，请先换个思路。
2. **Every UI string goes through the catalogues.** / **界面文案一律走词典。** Data-side strings live in `src/core/i18n.mjs`, shell-side strings in `src/shell/PetStrings.ps1`. Never hard-code Chinese or English text in the renderer or reducer. Both catalogues must keep the same key set — `tests/i18n.test.mjs` enforces it. / 数据侧文案放 `src/core/i18n.mjs`，界面侧放 `src/shell/PetStrings.ps1`，不要在渲染层或 reducer 里写死中英文；两张词典键集必须一致（`tests/i18n.test.mjs` 会强制检查）。
3. **Pure core.** / **核心保持纯净。** `src/core/*.mjs` must not touch the filesystem, the clock or globals. New behaviour belongs in a pure function with a unit test; the bridge wires it to I/O. / `src/core/*.mjs` 不得接触文件系统、时钟或全局状态；新行为写成带单元测试的纯函数，由 bridge 负责接线 I/O。
4. **Test the module that owns the decision.** / **测试拥有决策权的模块。** If a behaviour spans two modules (e.g. retention policy), the test goes where the policy lives, not where the data passes through. / 如果行为跨两个模块（例如保留策略），测试要放在策略所在处，而不是数据途经处。

## Windows-specific traps / Windows 相关的坑

* Edit `.ps1` files only in a UTF-8-with-BOM editor; run `tools/Validate-Shell.ps1` afterwards. / 编辑 `.ps1` 必须保持 UTF-8 带 BOM，改完运行 `tools/Validate-Shell.ps1`。
* `scripts/start-pet.cmd` must stay CRLF and ASCII-only. / `scripts/start-pet.cmd` 必须保持 CRLF 行尾且纯 ASCII。
* Restart the bridge after changing anything in `src/core/` — Node caches modules. / 改动 `src/core/` 后要重启 bridge——Node 会缓存模块。

## Before opening a PR / 提交 PR 之前

```powershell
node tests\run-tests.mjs                                          # all green / 全绿
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Validate-Shell.ps1
```

* One topic per PR, with a short description of the behaviour change and how you verified it. / 每个 PR 只做一件事，并简述行为变化与验证方式。
* Screenshots or GIFs are appreciated for anything visual. / 涉及界面的改动欢迎附截图或 GIF。
* New live-desktop checks belong in `tools/Test-*.ps1`, following the existing naming. / 新的实机校验放 `tools/Test-*.ps1`，沿用现有命名。

## Reporting issues / 报告问题

Include: Windows version, whether Harness runs in tray mode, the exact steps, and — if you can — `state/bridge-status.json` and the shell's `build/shell-diag.log`. Please do **not** paste session log contents; the whole point of this pet is a privacy boundary. / 请附上：Windows 版本、Harness 是否开启了托盘驻留、复现步骤，以及（如可能）`state/bridge-status.json` 与 shell 的 `build/shell-diag.log`。请**不要**粘贴会话日志内容——隐私边界正是这个项目的核心价值。
