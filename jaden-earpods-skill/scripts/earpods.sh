#!/bin/bash
set -euo pipefail

readonly LABEL=io.github.jaden-earpods-skill.remote
readonly APP_NAME='Jaden EarPods Remote.app'
readonly OLD_LABEL=local.earpods-typeless
readonly APP_DIR="$HOME/Applications"
readonly APP="$APP_DIR/$APP_NAME"
readonly BINARY="$APP/Contents/MacOS/EarPodsRemote"
readonly AGENT_DIR="$HOME/Library/LaunchAgents"
readonly AGENT="$AGENT_DIR/$LABEL.plist"
readonly LOG="$HOME/Library/Logs/$LABEL.log"
readonly LOCK="$HOME/Library/.$LABEL.lock"
readonly DOMAIN="gui/$(/usr/bin/id -u)"
readonly SERVICE="$DOMAIN/$LABEL"
readonly PERMISSION_SERVICE="$DOMAIN/$LABEL.permission"
readonly MATCH='{"VendorID":1452,"ProductID":4363,"PrimaryUsagePage":12,"PrimaryUsage":1}'
readonly SCRIPT_DIR="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

stage=
locked=false
new_app=false
new_agent=false
bootstrap_attempted=false

fail() { printf '%s\n' "$*" >&2; exit 1; }
exists() { [[ -e "$1" || -L "$1" ]]; }
loaded() { /bin/launchctl print "$1" >/dev/null 2>&1; }
plist_value() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }

require_gui() {
    [[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'This workflow requires macOS.'
    [[ "$(/usr/bin/id -u)" != 0 ]] || fail 'Run as the logged-in user without sudo.'
    [[ "$(/usr/bin/stat -f '%u' /dev/console)" == "$(/usr/bin/id -u)" ]] &&
        /bin/launchctl print "$DOMAIN" >/dev/null 2>&1 ||
        fail 'Run from the active macOS desktop account.'
}

lock_changes() {
    /bin/mkdir "$LOCK" 2>/dev/null ||
        fail "Another operation is running or left a lock at $LOCK. Check for a running installer before removing that empty directory."
    locked=true
}

reject_legacy() {
    if exists "$AGENT_DIR/$OLD_LABEL.plist" || loaded "$DOMAIN/$OLD_LABEL"; then
        fail 'An earlier local.earpods-typeless setup exists. Use its own restore command before installing or removing this version.'
    fi
}

read_mapping() {
    /usr/bin/hidutil property --matching "$MATCH" --get UserKeyMapping
}

preflight() {
    reject_legacy
    if exists "$APP" || exists "$AGENT" || loaded "$SERVICE" || loaded "$PERMISSION_SERVICE"; then
        fail 'An app, launch agent or permission job already occupies the installation identity. Run status to inspect it.'
    fi
    local version snapshot rc=0
    version=$(/usr/bin/sw_vers -productVersion)
    [[ "${version%%.*}" -ge 13 ]] || fail 'macOS 13 or later is required to build this helper.'
    /usr/bin/xcrun --find swiftc >/dev/null 2>&1 ||
        fail 'Install the Apple Command Line Tools with xcode-select --install, then rerun preflight.'
    [[ -f "$SCRIPT_DIR/EarPodsRemote.swift" ]] || fail 'EarPodsRemote.swift is missing next to this script.'
    snapshot=$(read_mapping) || fail 'Could not read the EarPods key mapping.'
    printf '%s\n' "$snapshot" | /usr/bin/awk '
        $2 == "UserKeyMapping" { rows++; if ($3 == "(null)" || $3 == "()") empty++ }
        $1 == "HIDKeyboardModifierMappingSrc" {
            source = tolower($3)
            sub(/[;,]$/, "", source)
            if (source ~ /^[0-9]+$/) { sub(/^0+/, "", source); sources++ }
            else if (source ~ /^0x[[:xdigit:]]+$/) { sub(/^0x0+/, "0x", source); sources++ }
            else malformed = 1
            if (source == "51539607757" || source == "51539607785" ||
                source == "0xc000000cd" || source == "0xc000000e9") conflict = 1
        }
        END {
            if (rows == 0) exit 2
            if (rows != 1) exit 3
            if (conflict) exit 4
            if (malformed || empty + sources == 0) exit 5
        }' || rc=$?
    case "$rc" in
        0) printf '%s\n' 'Preflight passed. One compatible USB-C EarPods device found.' ;;
        2) fail 'Connect one compatible Apple USB-C EarPods headset and try again.' ;;
        3) fail 'More than one matching EarPods service was found. Connect only one headset.' ;;
        4) fail 'An existing remap already uses the center or volume-up button. Remove it through its original tool first.' ;;
        *) fail 'The device returned an unrecognized mapping format. Inspect status before proceeding.' ;;
    esac
}

owned_app() {
    [[ -d "$APP" && ! -L "$APP" && -x "$BINARY" && ! -L "$BINARY" ]] &&
        [[ "$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)" == "$LABEL" ]] &&
        [[ "$(plist_value "$APP/Contents/Info.plist" CFBundleExecutable 2>/dev/null)" == EarPodsRemote ]] &&
        /usr/bin/codesign --verify --strict "$APP" >/dev/null 2>&1
}

owned_agent() {
    [[ -f "$AGENT" && ! -L "$AGENT" ]] &&
        [[ "$(plist_value "$AGENT" Label 2>/dev/null)" == "$LABEL" ]] &&
        [[ "$(plist_value "$AGENT" ProgramArguments.0 2>/dev/null)" == "$BINARY" ]] &&
        [[ "$(plist_value "$AGENT" ProgramArguments.1 2>/dev/null)" == --watch ]]
}

stop_job() {
    local service="$1" details pid attempt
    if ! details=$(/bin/launchctl print "$service" 2>/dev/null); then return 0; fi
    if ! printf '%s\n' "$details" | /usr/bin/awk -v expected="$BINARY" '
        /^[[:space:]]*program = / { sub(/^[[:space:]]*program = /, ""); if ($0 == expected) match_found = 1 }
        END { exit !match_found }'; then
        printf 'Refusing to stop a service with another executable: %s\n' "$service" >&2
        return 1
    fi
    pid=$(printf '%s\n' "$details" | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
    /bin/launchctl bootout "$service" || return 1
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; then
        for attempt in 1 2 3 4 5 6; do
            kill -0 "$pid" 2>/dev/null || break
            /bin/sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' 'The helper is still exiting. Retry uninstall after it stops.' >&2
            return 1
        fi
    fi
}

cleanup() {
    local rc=$? restored=true
    trap - EXIT
    set +e
    if [[ "$rc" != 0 && "$new_app" == true ]]; then
        if [[ "$bootstrap_attempted" == true ]]; then
            if ! stop_job "$SERVICE" || ! "$BINARY" --remove-once; then restored=false; fi
        fi
        if [[ "$restored" == true ]]; then
            if [[ "$new_agent" == true ]] && owned_agent; then /bin/rm -f "$AGENT"; fi
            if owned_app; then /bin/rm -rf "$APP"; fi
        else
            printf '%s\n' 'Could not finish rollback. The helper was retained for a retry with uninstall.' >&2
        fi
    fi
    if [[ -n "$stage" ]]; then /bin/rm -rf "$stage"; fi
    if [[ "$locked" == true ]]; then /bin/rmdir "$LOCK"; fi
    exit "$rc"
}

make_job_plist() {
    local path="$1" label="$2" mode="$3"
    /usr/bin/plutil -create xml1 "$path"
    /usr/bin/plutil -insert Label -string "$label" "$path"
    /usr/bin/plutil -insert ProgramArguments -array "$path"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$BINARY" "$path"
    /usr/bin/plutil -insert ProgramArguments.1 -string "$mode" "$path"
    /usr/bin/plutil -insert RunAtLoad -bool true "$path"
    if [[ "$mode" == --watch ]]; then
        /usr/bin/plutil -insert KeepAlive -bool true "$path"
        /usr/bin/plutil -insert ThrottleInterval -integer 10 "$path"
        /usr/bin/plutil -insert ProcessType -string Background "$path"
        /usr/bin/plutil -insert StandardErrorPath -string "$LOG" "$path"
    fi
    /usr/bin/plutil -lint "$path" >/dev/null
}

install_remote() {
    lock_changes
    preflight
    stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jaden-earpods.XXXXXXXX")
    local staged_app="$stage/$APP_NAME" staged_agent="$stage/$LABEL.plist" architecture log_start attempt
    architecture=$(/usr/bin/uname -m)
    case "$architecture" in arm64|x86_64) ;; *) fail 'Unsupported Mac architecture.' ;; esac
    /bin/mkdir -p "$staged_app/Contents/MacOS" "$APP_DIR" "$AGENT_DIR" "$HOME/Library/Logs"
    /bin/cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.jaden-earpods-skill.remote</string>
  <key>CFBundleName</key><string>Jaden EarPods Remote</string>
  <key>CFBundleDisplayName</key><string>Jaden EarPods Remote</string>
  <key>CFBundleExecutable</key><string>EarPodsRemote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
    /usr/bin/xcrun swiftc -O -target "$architecture-apple-macos13.0" \
        -framework IOKit -framework AppKit -framework Carbon -framework ApplicationServices \
        "$SCRIPT_DIR/EarPodsRemote.swift" -o "$staged_app/Contents/MacOS/EarPodsRemote"
    /usr/bin/codesign --force --sign - --identifier "$LABEL" "$staged_app"
    /usr/bin/codesign --verify --strict "$staged_app"
    make_job_plist "$staged_agent" "$LABEL" --watch
    preflight
    log_start=1
    if exists "$LOG"; then
        [[ -f "$LOG" && ! -L "$LOG" ]] || fail 'The launch log path is not a regular file.'
        log_start=$(( $(/usr/bin/stat -f '%z' "$LOG") + 1 ))
    fi
    /bin/mv -n "$staged_app" "$APP_DIR/"
    [[ ! -e "$staged_app" ]] || fail 'The app destination was claimed during installation.'
    new_app=true
    /bin/mv -n "$staged_agent" "$AGENT_DIR/"
    [[ ! -e "$staged_agent" ]] || fail 'The launch agent destination was claimed during installation.'
    new_agent=true
    bootstrap_attempted=true
    /bin/launchctl bootstrap "$DOMAIN" "$AGENT"
    for attempt in 1 2 3 4 5; do
        if [[ -f "$LOG" ]] && /usr/bin/tail -c "+$log_start" "$LOG" |
            /usr/bin/awk '/Watching EarPods/ { ready=1 } END { exit !ready }' &&
            /bin/launchctl print "$SERVICE" | /usr/bin/awk '$1=="state" && $3=="running" { ready=1 } END { exit !ready }'; then
            printf '%s\n' 'Jaden EarPods Remote is running. Use permission to request Accessibility for the send button.'
            return 0
        fi
        /bin/sleep 1
    done
    fail "The helper did not confirm startup. Inspect $LOG."
}

show_status() {
    if owned_app; then
        "$BINARY" --status
    elif exists "$APP"; then
        fail 'The app path is occupied by a bundle whose identity or signature could not be verified.'
    else
        local snapshot
        printf '%s\n' 'Jaden EarPods Remote is not installed.'
        snapshot=$(read_mapping) || fail 'Could not read the EarPods key mapping.'
        if [[ -n "$snapshot" ]]; then
            printf '%s\n' "$snapshot"
        else
            printf '%s\n' 'No matching USB-C EarPods detected.'
        fi
    fi
    if loaded "$SERVICE"; then
        printf '%s\n' 'Launch agent loaded.'
        if [[ -f "$LOG" && ! -L "$LOG" ]]; then /usr/bin/tail -n 12 "$LOG"; fi
    else
        printf '%s\n' 'Launch agent not loaded.'
    fi
}

request_permission() {
    lock_changes
    owned_app && owned_agent && loaded "$SERVICE" || fail 'Install the helper before requesting permission.'
    stop_job "$PERMISSION_SERVICE" || fail 'Could not clear the previous permission job.'
    stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jaden-earpods.XXXXXXXX")
    local permission_plist="$stage/$LABEL.permission.plist"
    make_job_plist "$permission_plist" "$LABEL.permission" --request-permission
    /bin/launchctl bootstrap "$DOMAIN" "$permission_plist"
    printf '%s\n' 'Open System Settings → Privacy & Security → Accessibility and enable Jaden EarPods Remote. If it is absent, add this app:'
    printf '%s\n' "$APP"
}

uninstall_remote() {
    lock_changes
    if ! exists "$APP" && ! exists "$AGENT" && ! loaded "$SERVICE" && ! loaded "$PERMISSION_SERVICE"; then
        printf '%s\n' 'Jaden EarPods Remote is already uninstalled.'
        return 0
    fi
    reject_legacy
    owned_app || fail 'Could not verify the app identity. Keep the files in place and inspect the installation.'
    if exists "$AGENT"; then owned_agent || fail 'The launch agent file has another identity.'; fi
    stop_job "$PERMISSION_SERVICE" || fail 'Could not stop the permission job.'
    stop_job "$SERVICE" || fail 'Could not stop the helper.'
    "$BINARY" --remove-once || fail 'Could not remove the mappings. Retry uninstall with the headset connected.'
    if exists "$AGENT"; then /bin/rm -f "$AGENT"; fi
    /bin/rm -rf "$APP"
    printf '%s\n' 'Jaden EarPods Remote uninstalled. If its Accessibility entry remains, remove it in System Settings.'
}

case "${1:-help}" in
    help|-h|--help)
        printf '%s\n' 'Usage: bash scripts/earpods.sh {preflight|status|install|permission|uninstall}'
        ;;
    preflight|status|install|permission|uninstall)
        [[ "$#" == 1 ]] || fail 'Pass exactly one subcommand.'
        require_gui
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        case "$1" in
            preflight) preflight ;;
            status) show_status ;;
            install) install_remote ;;
            permission) request_permission ;;
            uninstall) uninstall_remote ;;
        esac
        ;;
    *) fail 'Unknown command. Run earpods.sh help.' ;;
esac
