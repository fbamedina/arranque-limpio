import AppKit
import Combine
import SwiftUI

/// Icono de la barra de menús: clic izquierdo abre el panel, clic derecho (o ctrl+clic) el menú contextual.
@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: SystemMonitor!
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = SystemMonitor()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = monitor.menuImage
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let host = NSHostingController(rootView: PanelView(monitor: monitor))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        // Actualiza el icono cada vez que cambia el estado del monitor.
        observation = monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
    }

    private func refreshIcon() {
        statusItem.button?.image = monitor.menuImage
        statusItem.button?.toolTip = monitor.paused ? "Arranque Limpio · en pausa" : "Arranque Limpio"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: monitor.paused ? "Monitorización en pausa" : "Monitorización activa", action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: monitor.paused ? "pause.circle" : "waveform.path.ecg", accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if monitor.paused {
            addItem(to: menu, "Reanudar monitorización", symbol: "play.fill", action: #selector(resume))
        } else {
            let pause = addItem(to: menu, "Pausar monitorización", symbol: "pause.fill", action: #selector(pause))
            pause.toolTip = "La app sigue en la barra de menús, pero deja de medir y no consume recursos."
        }
        addItem(to: menu, "Abrir panel", symbol: "rectangle.on.rectangle", action: #selector(openPanel))
        menu.addItem(.separator())
        addItem(to: menu, "Salir de Arranque Limpio", symbol: "power", action: #selector(quit), key: "q")

        // Se asigna el menú solo mientras se muestra, para que el clic izquierdo siga abriendo el panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    @objc private func pause() { monitor.setPaused(true) }
    @objc private func resume() { monitor.setPaused(false) }
    @objc private func openPanel() { DispatchQueue.main.async { self.togglePopover() } }
    @objc private func quit() { NSApp.terminate(nil) }
}
