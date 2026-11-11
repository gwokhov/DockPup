// Copyright (C) 2026 Gwokhou
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement

private func localized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DockController()
    private var item: NSStatusItem!
    private let status = NSMenuItem()
    private let target = NSMenuItem()
    private let counters = NSMenuItem()
    private let enabled = NSMenuItem(title: localized("Enable Locking"), action: #selector(toggle), keyEquivalent: "")
    private let launchAtLogin = NSMenuItem(title: localized("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "DockPup")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for label in [status, target, counters] { label.isEnabled = false; menu.addItem(label) }
        menu.addItem(.separator())
        enabled.target = self
        menu.addItem(enabled)
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        for (title, action) in [(localized("Move Dock / Retry"), #selector(retry)), (localized("Grant Accessibility Access…"), #selector(authorize)), (localized("Quit DockPup"), #selector(quit))] {
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
        updateLaunchAtLogin()
    }

    func menuDidClose(_ menu: NSMenu) { controller.menuOpen = false }
    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    private func updateMenu() {
        let text = localized(controller.status)
        status.title = text
        target.title = String(format: localized("Target: %@"), localized(controller.targetName))
        counters.title = String(format: localized("Blocked: %ld · Last event: %@"), controller.blockedMoves, localized(controller.lastReason))
        enabled.state = controller.enabled ? .on : .off
        item.button?.toolTip = String(format: localized("DockPup: %@"), text)
    }

    private func updateLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin.state = status == .enabled ? .on : .off
        launchAtLogin.title = localized(status == .requiresApproval ? "Launch at Login (Approval Required…)" : "Launch at Login")
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else if service.status != .requiresApproval {
                try service.register()
            }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = localized("Could Not Update Launch at Login")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateLaunchAtLogin()
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
