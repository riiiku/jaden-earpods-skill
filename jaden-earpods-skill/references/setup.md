# Setup and recovery

## Install the helper

Connect Apple USB-C EarPods. Install Typeless and the Codex desktop app separately. The helper builds with the system `xcrun swiftc` and runs in the logged-in user's GUI session.

If you cloned the repository manually, enter its Skill folder.

```bash
git clone https://github.com/riiiku/jaden-earpods-skill.git
cd jaden-earpods-skill/jaden-earpods-skill
```

Run these commands from the Skill folder containing `SKILL.md`.

```bash
bash scripts/earpods.sh preflight
bash scripts/earpods.sh install
```

Preflight checks the exact USB HID interface and looks for an existing mapping. If a conflict is reported, use the existing tool's uninstall instructions before proceeding. Installation compiles and signs a local app bundle under `~/Applications` and starts a user LaunchAgent.

## Configure Typeless and Codex

1. In Typeless **Settings → Keyboard shortcuts → Dictate**, use **Add another** and press **Right Shift**. With the helper running, pressing the EarPods center button produces Right Shift as well. Choose the EarPods microphone in **Audio** if you want to dictate through the headset.
2. In Codex **Settings → General → Composer**, set **Send shortcut** to **Command + Return**. For the single-button steering workflow, set **Follow-up behavior** to **Steer**. Choose **Queue** if you want an in-flight submission to wait for the next turn.
3. Run `bash scripts/earpods.sh permission` when ready to enable submission. In macOS **System Settings → Privacy & Security → Accessibility**, enable **Jaden EarPods Remote**. If needed, add the app from `~/Applications/Jaden EarPods Remote.app`. Return to Codex to refresh the mapping.
4. Return to Codex and focus the composer. Tap center, say a short test phrase, and tap center again. Wait for the complete text to appear, then short-press **+**. To check steering, submit a short correction while a task is still running.

Command + Return goes to the foreground Codex desktop app. Focus the composer before pressing **+**. An actual F19 key can trigger the same shortcut while the helper has registered it. System Accessibility permission lets the helper post the shortcut, and the helper also checks the foreground app, console session and device before it posts.

## 中文设置步骤

1. 插入 Apple USB-C EarPods。在 Skill 目录运行 `bash scripts/earpods.sh preflight`，通过后运行 `bash scripts/earpods.sh install`。
2. Typeless「设置 → 快捷键 → 语音输入」添加「右 Shift」。也可以在录入快捷键时按耳机中间键。在「音频」按需选择 EarPods 麦克风。
3. Codex「设置 → 常规 → 编辑器」将「发送快捷键」设为 Command＋回车。「后续消息处理方式」在下一行，选择「引导」。
4. 运行 `bash scripts/earpods.sh permission`，在 macOS「系统设置 → 隐私与安全性 → 辅助功能」开启 **Jaden EarPods Remote**。回到 Codex 输入框，用中间键说话、结束，等文字出现后按「＋」。
5. 运行 `bash scripts/earpods.sh status` 查映射和进程状态。恢复原线控时运行 `bash scripts/earpods.sh uninstall`，并按需在辅助功能中移除权限条目。

## Diagnose and recover

- Run `bash scripts/earpods.sh status` with the headphones connected. If the device is absent, reconnect it and check again. A read-only status check launched by a terminal may inherit its permission context. Use the LaunchAgent log at `~/Library/Logs/io.github.jaden-earpods-skill.remote.log` and a physical press to verify the watcher's ability to submit.
- If **+** still raises volume, focus the Codex desktop app, check the Accessibility setting and verify that F19 is available. Switch to another app and back to Codex to refresh the mapping.
- If **+** submits but queues a follow-up, check the Codex follow-up preference. A hotkey log confirms shortcut dispatch. Look at the composer and task state to verify delivery and steering.
- To remove the helper, run `bash scripts/earpods.sh uninstall`. The script unloads this LaunchAgent and removes the owned mappings. Typeless and Codex preferences can be changed in their respective settings. Removing the Accessibility entry is optional after removal.

## Verification

The originating setup was used with macOS 26.6.2, Apple silicon, and a matching pair of USB-C EarPods. The user verified start and stop, insertion into the input field, reconnection for dictation, and submitting to Codex.

This package passed the native build, ad hoc signature verification, Skill validation, installer conflict checks, and read-only HID status with EarPods connected and disconnected. Physical presses after a fresh install, reconnecting the public helper, and lock or wake behavior still need testing.

Lightning, 3.5 mm and Bluetooth models use different interfaces. Compatibility with Intel Macs and earlier macOS releases has not been physically verified.

- [Apple's key remapping technical note](https://developer.apple.com/library/archive/technotes/tn2450/)
- [Typeless settings](https://www.typeless.com/help/quickstart/settings)
- [Codex desktop settings](https://learn.chatgpt.com/docs/reference/settings)
