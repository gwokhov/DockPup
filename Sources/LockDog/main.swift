// Copyright (C) 2026 Gwokhou
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DockController()
    private var item: NSStatusItem!
    private let status = NSMenuItem()
    private let target = NSMenuItem()
    private let counters = NSMenuItem()
    private let enabled = NSMenuItem(title: "Enable Locking", action: #selector(toggle), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "LockDog")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for label in [status, target, counters] { label.isEnabled = false; menu.addItem(label) }
        menu.addItem(.separator())
        enabled.target = self
        menu.addItem(enabled)
        for (title, action) in [("Move Dock / Retry", #selector(retry)), ("Grant Accessibility Access…", #selector(authorize)), ("Quit LockDog", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        controller.onChange = { [weak self] in self?.updateMenu() }
        controller.refresh(reason: "Launch")
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.menuOpen = true
        updateMenu()
    }

    func menuDidClose(_ menu: NSMenu) { controller.menuOpen = false }
    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    private func updateMenu() {
        status.title = "Status: \(controller.status)"
        target.title = "Target: \(controller.targetName)"
        counters.title = "Blocked moves: \(controller.blockedMoves) · Last event: \(controller.lastReason)"
        enabled.state = controller.enabled ? .on : .off
        item.button?.toolTip = "LockDog: \(controller.status)"
    }

    @objc private func toggle() { controller.toggle() }
    @objc private func retry() { controller.refresh(reason: "Manual retry") }
    @objc private func authorize() { controller.requestPermission() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
