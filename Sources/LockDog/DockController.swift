// Copyright (C) 2026 Gwokhou
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import OSLog

final class DockController {
    var onChange: (() -> Void)?
    private(set) var enabled = true
    private(set) var status = "Starting"
    private(set) var targetName = "Waiting for a display"
    private(set) var blockedMoves = 0
    private(set) var lastReason = "Launch"
    var menuOpen = false

    private let logger = Logger(subsystem: "local.g.lockdog", category: "Dock")
    private let eventTag: Int64 = 0x4C6F636B446F67
    private var target: Display?
    private var guardEdges: [CGRect] = []
    private var destination: CGPoint?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var recoveryTimer: Timer?
    private var settleWork: DispatchWorkItem?
    private var deadline: TimeInterval = 0
    private var migrationBegan: TimeInterval = 0
    private var originalCursor: CGPoint?
    private var previousMotionPoint: CGPoint?
    private var lastDockFrame: CGRect?
    private var nextDockCheck: TimeInterval = 0
    private var lastInput = ProcessInfo.processInfo.systemUptime
    private var sleeping = false

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(willSleep), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(didWake), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(applicationLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    }

    func toggle() {
        enabled.toggle()
        refresh(reason: "Locking toggled")
    }

    func refresh(reason: String) {
        settleWork?.cancel()
        finishRecovery()
        stopTap()
        lastReason = reason
        target = nil
        destination = nil
        guardEdges = []

        let displays = Display.connected()
        let external = displays.filter { CGDisplayIsBuiltin($0.id) == 0 }
        targetName = external.first?.name ?? displays.first?.name ?? "No display detected"
        guard enabled else { setStatus("Paused"); return }
        guard !sleeping else { setStatus("Sleeping; waiting to wake"); return }
        guard displays.count > 1 else { setStatus("Single display; no guarding needed"); return }
        guard external.count == 1, let selected = external.first else {
            setStatus("Only one external display is supported")
            return
        }
        target = selected
        guard (CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom") == "bottom" else {
            setStatus("Set the system Dock position to Bottom")
            return
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            setStatus("Enable ‘Displays have separate Spaces’")
            return
        }
        guard let edge = selected.exposedBottomEdges(among: displays).filter({ $0.width >= 8 }).max(by: { $0.width < $1.width }) else {
            setStatus("Offset the displays to expose at least 8 points of the external display’s bottom edge")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            setStatus("Accessibility access required; use Grant Accessibility Access…")
            return
        }
        destination = CGPoint(x: edge.midX, y: selected.frame.maxY - 1)
        guardEdges = displays.filter { $0.id != selected.id }.flatMap { $0.exposedBottomEdges(among: displays) }
        guard startTap() else {
            setStatus("Could not create the event tap; check permissions and retry")
            return
        }
        lastInput = ProcessInfo.processInfo.systemUptime
        deadline = lastInput + 20
        lastDockFrame = nil
        nextDockCheck = 0
        setStatus("Waiting for idle input before moving the Dock")
        startRecoveryTimer(interval: 0.15)
    }

    func stop() {
        settleWork?.cancel()
        finishRecovery()
        stopTap()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if AXIsProcessTrusted() && !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setStatus(_ text: String) {
        status = text
        logger.notice("\(self.lastReason, privacy: .public): \(text, privacy: .public)")
        onChange?()
    }

    private func startRecoveryTimer(interval: TimeInterval) {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.recover()
        }
        recoveryTimer?.tolerance = interval / 10
    }

    private func startTap() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<DockController>.fromOpaque(context).takeUnretainedValue()
            controller.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        // Intercept before the Dock when possible; fall back to the session tap.
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            if let created = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                tap = created
                tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
                CGEvent.tapEnable(tap: created, enable: true)
                return true
            }
        }
        return false
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if AXIsProcessTrusted(), CGPreflightPostEventAccess(), let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.refresh(reason: "Permissions changed") }
            }
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != eventTag else { return }
        if recoveryTimer != nil {
            lastInput = ProcessInfo.processInfo.systemUptime
            // Discard the saved position when input resumes to avoid pulling the cursor back.
            originalCursor = nil
        }
        guard !menuOpen, type == .mouseMoved,
              let edge = guardEdges.first(where: { $0.contains(event.location) }),
              NSEvent.pressedMouseButtons == 0 else { return }
        var point = event.location
        point.y = edge.minY - 1
        event.location = point
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        CGWarpMouseCursorPosition(point)
        blockedMoves += 1
    }

    private func recover() {
        let now = ProcessInfo.processInfo.systemUptime
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { refresh(reason: "Permissions changed"); return }
        guard now < deadline else {
            finishRecovery()
            setStatus("Idle wait timed out; use Move Dock / Retry")
            return
        }
        guard !menuOpen, let destination, let target else { return }
        // Check the Dock less often than cursor motion to keep movement continuous.
        if now >= nextDockCheck {
            lastDockFrame = currentDockFrame()
            nextDockCheck = now + 0.15
        }
        let dockFrame = lastDockFrame
        if let dockFrame, target.frame.contains(CGPoint(x: dockFrame.midX, y: dockFrame.minY + 1)) {
            finishRecovery()
            setStatus("Dock confirmed on external display; guarding")
            return
        }
        if originalCursor == nil {
            if recoveryTimer?.timeInterval != 0.15 { startRecoveryTimer(interval: 0.15) }
            guard now - lastInput > 1, NSEvent.pressedMouseButtons == 0,
                  CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) > 1,
                  let position = CGEvent(source: nil)?.location else { return }
            originalCursor = position
            migrationBegan = now
            previousMotionPoint = nil
            startRecoveryTimer(interval: 0.02)
            setStatus("Moving the Dock; move the mouse to interrupt")
        }
        guard now - migrationBegan < 3 else {
            finishRecovery()
            setStatus(dockFrame == nil ? "Could not read the Dock position; check visually and retry" : "Dock move failed; check display arrangement and retry")
            return
        }
        // Approach from inside the display before pushing against its bottom edge.
        let progress = min(1, (now - migrationBegan) / 0.2)
        let point = CGPoint(x: destination.x, y: destination.y - 64 * (1 - progress))
        let deltaY = progress < 1 ? point.y - (previousMotionPoint?.y ?? point.y) : 8
        previousMotionPoint = point
        postMove(to: point, deltaY: deltaY)
    }

    private func finishRecovery() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        previousMotionPoint = nil
        guard var point = originalCursor else { return }
        originalCursor = nil
        guard !sleeping, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              Display.connected().contains(where: { $0.frame.contains(point) }) else { return }
        // Keep cursor restoration clear of guarded edges to avoid triggering another move.
        if let edge = guardEdges.first(where: { $0.contains(point) }) { point.y = edge.minY - 1 }
        postMove(to: point)
    }

    private func postMove(to point: CGPoint, deltaY: CGFloat = 0) {
        // Share the current session state throughout the approach and edge push.
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.localEventsSuppressionInterval = 0
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY.rounded()))
        event.post(tap: .cghidEventTap)
    }

    private func currentDockFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }
        for element in elements {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole else { continue }
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
                  let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { continue }
            return CGRect(origin: position, size: size)
        }
        return nil
    }

    private func scheduleRefresh(reason: String) {
        stop()
        let work = DispatchWorkItem { [weak self] in self?.refresh(reason: reason) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    @objc private func displayChanged() { scheduleRefresh(reason: "Displays changed") }
    @objc private func willSleep() { sleeping = true; stop(); setStatus("Sleeping; waiting to wake") }
    @objc private func didWake() { sleeping = false; scheduleRefresh(reason: "Wake / unlock") }
    @objc private func applicationLaunched(_ note: Notification) {
        if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" {
            scheduleRefresh(reason: "Dock launched")
        }
    }
}
