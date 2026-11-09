# Jaden EarPods Skill

Use the remote on Apple USB-C EarPods to dictate with Typeless and submit to Codex on macOS.

| Button | Action |
| --- | --- |
| Center | Tap to start Typeless. Tap again to finish and insert text. |
| Volume up | Submit the text in the focused Codex composer with Command + Return. With **Steer** enabled, a submission during a run steers that run. |
| Volume down | Lower volume. |

### Get started

Give Codex this prompt to install the Skill from GitHub.

> Use $skill-installer to install the jaden-earpods-skill folder from riiiku/jaden-earpods-skill.

In the next chat, use `$jaden-earpods-skill` to set up your EarPods. For a manual setup, clone the repository and follow the [setup guide](jaden-earpods-skill/references/setup.md).

The helper builds from Swift source with Apple's Command Line Tools. Installation creates a user LaunchAgent. You can enable Accessibility for **Jaden EarPods Remote** to let it send Command + Return in the Codex desktop app. The helper uses a single registered hotkey and device notifications.

### 中文速览

**中间键开始听写 → 中间键结束 → 等文字出现 → 按「＋」提交。** Codex 的「后续消息处理方式」设为「引导」后，执行中的补充指令会交给当前任务。「－」用于调低音量。

在 Codex 中让 `$skill-installer` 安装这个仓库里的 `jaden-earpods-skill`，再调用 `$jaden-earpods-skill` 开始配置。 [安装与恢复说明](jaden-earpods-skill/references/setup.md#中文设置步骤)

### Compatibility

The hardware match is Apple USB-C EarPods with USB vendor ID `0x05AC` and product ID `0x110B`. The build targets macOS 13 or later. The original workflow was exercised on an Apple silicon Mac running macOS 26.6.2. See the [verification notes](jaden-earpods-skill/references/setup.md#verification) for the checks on this package.

[MIT License](LICENSE)
