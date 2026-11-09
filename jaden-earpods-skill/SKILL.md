---
name: jaden-earpods-skill
description: Set up or troubleshoot Apple USB-C EarPods on macOS as a remote for Typeless dictation and Codex desktop submission or steering. Use for installing, testing, and removing the device-specific mapping.
---

# Jaden EarPods Skill

Set up short presses on a supported EarPods remote. The center button toggles Typeless, the upper button submits in the Codex composer, and the lower button lowers volume. Codex's follow-up setting determines whether an in-flight submission steers or queues.

1. Read [the setup guide](references/setup.md) and run `bash scripts/earpods.sh preflight` from this skill directory. Resolve device or ownership conflicts before installation.
2. If the user requests installation, run `bash scripts/earpods.sh install`. Add Right Shift as a Typeless Dictate shortcut and set the preferred microphone with the user. Preserve their other shortcuts and microphone choice unless they ask to change them.
3. Configure Codex to send with Command + Return. Set **Follow-up behavior** to **Steer** when the user wants the upper button to guide the current run. If the tool cannot access a setting, provide the exact manual path.
4. For submission, offer the explicit `permission` command and have the user enable Accessibility for **Jaden EarPods Remote** in System Settings. Use the guide to verify with a short, user-sent test after Typeless has inserted the text.
5. Use `status` for diagnosis and `uninstall` to remove this installation and its mappings on request. Report physical tests separately from build, process, and mapping checks.

Treat the registered F19 as reserved while the Codex submission mapping is active. Avoid claiming support for a connector or device ID other than the one the helper matches.
