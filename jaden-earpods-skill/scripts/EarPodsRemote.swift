import AppKit
import ApplicationServices
import Carbon
import Foundation
import IOKit

private let deviceIdentity = ["VendorID": 1452, "ProductID": 4363, "PrimaryUsagePage": 12, "PrimaryUsage": 1]
private let codexBundleID = "com.openai.codex"
private let sourceKey = "HIDKeyboardModifierMappingSrc"
private let destinationKey = "HIDKeyboardModifierMappingDst"
private typealias KeyMapping = [String: UInt64]
private let centerMapping: KeyMapping = [sourceKey: 0xC000000CD, destinationKey: 0x7000000E5]
private let sendMapping: KeyMapping = [sourceKey: 0xC000000E9, destinationKey: 0x70000006E]
private let hotKeyID = EventHotKeyID(signature: 0x45505459, id: 1) // EPTY

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(timestamp)] \(message)\n".utf8))
}

private func deviceQuery() throws -> CFMutableDictionary {
    guard let query = IOServiceMatching("IOHIDEventService") else { throw Failure("Cannot match HID services") }
    (query as NSMutableDictionary)[kIOPropertyMatchKey] = deviceIdentity
    return query
}

private func drain(_ iterator: io_iterator_t) -> [io_service_t] {
    var services: [io_service_t] = []
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { return services }
        services.append(service)
    }
}

private func matchingServices() throws -> [io_service_t] {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, try deviceQuery(), &iterator)
    guard result == KERN_SUCCESS else { throw Failure("Cannot enumerate EarPods HID services: \(result)") }
    defer { IOObjectRelease(iterator) }
    return drain(iterator)
}

private func registryID(_ service: io_service_t) throws -> UInt64 {
    var identifier: UInt64 = 0
    let result = IORegistryEntryGetRegistryEntryID(service, &identifier)
    guard result == KERN_SUCCESS else { throw Failure("Cannot identify the EarPods HID service") }
    return identifier
}

private func property(_ service: io_service_t, _ key: String) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue()
}

private func mappings(_ service: io_service_t) throws -> [KeyMapping] {
    let direct = property(service, "UserKeyMapping")
    let properties = property(service, "HIDEventServiceProperties") as? [String: Any]
    guard direct != nil || properties != nil else { throw Failure("HID service properties are not ready") }
    guard let value = direct ?? properties?["UserKeyMapping"], !(value is NSNull) else { return [] }
    guard let entries = value as? [[String: Any]], entries.count <= 100 else {
        throw Failure("Unknown UserKeyMapping format; preserved")
    }
    return try entries.map { entry in
        guard entry.count == 2,
              let source = entry[sourceKey] as? NSNumber,
              let destination = entry[destinationKey] as? NSNumber,
              CFGetTypeID(source) != CFBooleanGetTypeID(), CFGetTypeID(destination) != CFBooleanGetTypeID(),
              source.stringValue == String(source.uint64Value), destination.stringValue == String(destination.uint64Value) else {
            throw Failure("Unknown HID mapping entry; preserved")
        }
        return [sourceKey: source.uint64Value, destinationKey: destination.uint64Value]
    }
}

private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

private func writeMappings(_ updated: [KeyMapping], replacing current: [KeyMapping], on service: io_service_t) throws {
    guard updated != current else { return }
    let found = try matchingServices()
    defer { found.forEach { IOObjectRelease($0) } }
    guard found.count == 1, try registryID(found[0]) == registryID(service), try mappings(found[0]) == current else {
        throw Failure("EarPods or its mappings changed; write cancelled")
    }
    var match = deviceIdentity
    if let location = property(service, "LocationID") as? NSNumber, location.intValue > 0 {
        match["LocationID"] = location.intValue
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    task.arguments = ["property", "--matching", try json(match), "--set", try json(["UserKeyMapping": updated])]
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.standardError
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    try task.run()
    guard finished.wait(timeout: .now() + 3) == .success else {
        if task.isRunning { task.terminate() }
        throw Failure("hidutil timed out; check the current mapping before retrying")
    }
    guard task.terminationStatus == 0 else { throw Failure("hidutil exited with status \(task.terminationStatus)") }
    guard try mappings(service) == updated else { throw Failure("HID mapping readback did not match") }
}

private func removeMappings(_ owned: [KeyMapping]) throws {
    let found = try matchingServices()
    defer { found.forEach { IOObjectRelease($0) } }
    if found.isEmpty { return }
    guard found.count == 1 else { throw Failure("Multiple matching EarPods services; nothing changed") }
    let current = try mappings(found[0])
    try writeMappings(current.filter { !owned.contains($0) }, replacing: current, on: found[0])
}

private func activeConsole() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session[kCGSessionOnConsoleKey as String] as? Bool == true
        && session["CGSSessionScreenIsLocked"] as? Bool != true
}

private func frontmostCodex() -> NSRunningApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == codexBundleID else { return nil }
    return app
}

private func canPostKeyEvents() -> Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

private func status() throws {
    let found = try matchingServices()
    defer { found.forEach { IOObjectRelease($0) } }
    var result: [String: Any] = [
        "EarPodsPresent": !found.isEmpty, "EarPodsServiceCount": found.count,
        "CodexFrontmost": frontmostCodex() != nil, "AXTrusted": AXIsProcessTrusted(),
        "PostEventAccess": CGPreflightPostEventAccess()
    ]
    if found.count == 1 { result["UserKeyMapping"] = try mappings(found[0]) }
    print(try json(result))
}

private let arrivalCallback: IOServiceMatchingCallback = { context, iterator in
    drain(iterator).forEach { IOObjectRelease($0) }
    if let context { Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().scheduleArrival() }
}

private let removalCallback: IOServiceMatchingCallback = { context, iterator in
    let removed = drain(iterator)
    removed.forEach { IOObjectRelease($0) }
    if !removed.isEmpty, let context {
        Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
    }
}

private let hotKeyCallback: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard result == noErr, identifier.signature == hotKeyID.signature, identifier.id == hotKeyID.id else {
        return OSStatus(eventNotHandledErr)
    }
    let watcher = Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue()
    if GetEventKind(event) == UInt32(kEventHotKeyReleased) { watcher.keyReleased() }
    else { watcher.keyPressed() }
    return noErr
}

private final class Watcher {
    private var port: IONotificationPortRef?
    private var arrival: io_iterator_t = 0
    private var removal: io_iterator_t = 0
    private var pendingArrival: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var keyDown = false
    private var sessionAvailable = false
    private var stopped = false

    func scheduleArrival() {
        pendingArrival?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        pendingArrival = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func deviceRemoved() {
        disableHotKey()
        reconcile()
    }

    private func reconcile() {
        guard !stopped else { return }
        let eligible = sessionAvailable && activeConsole() && frontmostCodex() != nil && canPostKeyEvents()
        if !eligible { disableHotKey() }
        do {
            let found = try matchingServices()
            defer { found.forEach { IOObjectRelease($0) } }
            guard found.count == 1 else {
                disableHotKey()
                if !found.isEmpty { log("Multiple matching EarPods services; mappings preserved") }
                return
            }
            let service = found[0]
            let current = try mappings(service)
            var updated = current
            if !current.contains(where: { $0[sourceKey] == centerMapping[sourceKey] }) {
                updated.append(centerMapping)
            }
            let foreignSendMapping = current.contains { $0[sourceKey] == sendMapping[sourceKey] && $0 != sendMapping }
            let enableSend = eligible && !foreignSendMapping && enableHotKey()
            if enableSend {
                if !updated.contains(sendMapping) { updated.append(sendMapping) }
            } else {
                disableHotKey()
                updated.removeAll { $0 == sendMapping }
            }
            try writeMappings(updated, replacing: current, on: service)
            if updated != current { log("EarPods mapping updated; Codex send enabled=\(enableSend)") }
        } catch {
            disableHotKey()
            log("EarPods mapping unavailable: \(error)")
            do { try removeMappings([sendMapping]) }
            catch { log("Send mapping cleanup failed: \(error)") }
        }
    }

    private func enableHotKey() -> Bool {
        if hotKey != nil { return true }
        guard handler != nil else { return false }
        let result = RegisterEventHotKey(UInt32(kVK_F19), 0, hotKeyID,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if result != noErr {
            hotKey = nil
            log("F19 hotkey unavailable (\(result)); volume up remains available")
        }
        return hotKey != nil
    }

    private func disableHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        keyDown = false
    }

    func keyReleased() { keyDown = false }

    func keyPressed() {
        guard hotKey != nil, !keyDown else { return }
        keyDown = true
        guard !stopped, sessionAvailable, activeConsole(), canPostKeyEvents(), let app = frontmostCodex() else {
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
            return
        }
        do {
            let found = try matchingServices()
            defer { found.forEach { IOObjectRelease($0) } }
            guard found.count == 1, try mappings(found[0]).filter({ $0[sourceKey] == sendMapping[sourceKey] }) == [sendMapping] else {
                DispatchQueue.main.async { [weak self] in self?.reconcile() }
                return
            }
        } catch {
            log("F19 ignored: cannot verify the EarPods mapping")
            return
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard activeConsole(), canPostKeyEvents(), !app.isTerminated,
              frontmostCodex()?.processIdentifier == app.processIdentifier else { return }
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        log("Posted Command-Return to Codex")
    }

    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Read the actual frontmost app after the notification, regardless of event ordering.
                DispatchQueue.main.async { [weak self] in self?.reconcile() }
            })
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionAvailable = false
                self?.reconcile()
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionAvailable = true
                self?.scheduleArrival()
            })
        }
        // Supplement workspace session events with macOS lock/unlock notifications.
        for (name, unlocked) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name),
                object: nil, queue: .main) { [weak self] _ in
                    self?.sessionAvailable = unlocked
                    if unlocked {
                        // The session dictionary can lag the unlock notification.
                        self?.scheduleArrival()
                    } else {
                        self?.reconcile()
                    }
                })
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    func start() throws {
        sessionAvailable = activeConsole()
        let context = Unmanaged.passUnretained(self).toOpaque()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, types.count, &types, context, &handler)
        if handlerResult != noErr { handler = nil; log("F19 handler unavailable (\(handlerResult)); sending disabled") }
        observeSession()
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop(); exit(0) }
            source.resume()
            signals.append(source)
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { throw Failure("Cannot create IOKit notification port") }
        self.port = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw Failure("Cannot create IOKit notification source")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let added = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, try deviceQuery(), arrivalCallback, context, &arrival)
        guard added == KERN_SUCCESS else { throw Failure("Cannot subscribe to EarPods connection: \(added)") }
        let removed = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, try deviceQuery(), removalCallback, context, &removal)
        guard removed == KERN_SUCCESS else { throw Failure("Cannot subscribe to EarPods removal: \(removed)") }
        drain(removal).forEach { IOObjectRelease($0) }
        arrivalCallback(context, arrival)
        log("Watching EarPods and Codex focus; AXTrusted=\(AXIsProcessTrusted()); PostEventAccess=\(CGPreflightPostEventAccess())")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pendingArrival?.cancel()
        disableHotKey()
        if let handler { RemoveEventHandler(handler) }
        do { try removeMappings([sendMapping]) }
        catch { log("Send mapping cleanup failed: \(error)") }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if arrival != 0 { IOObjectRelease(arrival) }
        if removal != 0 { IOObjectRelease(removal) }
        if let port { IONotificationPortDestroy(port) }
    }
}

do {
    guard getuid() != 0, geteuid() != 0 else { throw Failure("Run as the logged-in macOS user, without sudo") }
    switch CommandLine.arguments.dropFirst().first ?? "--watch" {
    case "--watch":
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let watcher = Watcher()
        defer { watcher.stop() }
        try watcher.start()
        app.run()
    case "--status": try status()
    case "--remove-once": try removeMappings([centerMapping, sendMapping])
    case "--request-permission":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("AXTrusted=\(trusted). The macOS permission prompt is asynchronous.")
    default:
        print("Usage: EarPodsRemote [--watch | --status | --remove-once | --request-permission]")
        exit(2)
    }
} catch {
    log("ERROR: \(error)")
    exit(1)
}
