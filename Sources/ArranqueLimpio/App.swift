import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--report") {
            MainActor.assumeIsolated { TextReport.run() }
        } else if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { TextReport.snapshot(to: CommandLine.arguments[i + 1]) }
        } else {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                app.delegate = StatusBarController.shared
                app.run()
            }
        }
    }
}

extension TextReport {
    /// Renderiza el panel a PNG (útil para revisar el diseño sin abrir el menú).
    static func snapshot(to path: String) {
        _ = NSApplication.shared
        let monitor = SystemMonitor(terminalMode: true)
        RunLoop.main.run(until: Date().addingTimeInterval(25))
        let host = NSHostingView(rootView: PanelView(monitor: monitor, sortByMemory: CommandLine.arguments.contains("--memory"),
                                               expanded: Set(CommandLine.arguments.drop { $0 != "--expand" }.dropFirst().prefix(1))).background(.windowBackground))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(4))   // deja que carguen los detalles desplegados
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("Guardado \(path) (\(Int(host.bounds.width))×\(Int(host.bounds.height)))")
    }
}

/// Modo terminal: toma muestras ~35 s e imprime el diagnóstico.
@MainActor
enum TextReport {
    static func run() {
        let monitor = SystemMonitor(terminalMode: true)
        print("Tomando muestras durante 35 s…")
        RunLoop.main.run(until: Date().addingTimeInterval(35))

        print("\n== Estado: \(monitor.phase) · gravedad \(monitor.overall) · encendido hace \(Format.duration(monitor.uptime))")
        print("CPU total \(Int(monitor.cpuTotal * 100)) % · memoria \(Format.bytes(monitor.memUsed)) de \(Format.bytes(SystemInfo.memTotal)) · presión \(monitor.memPressure) · swap \(Format.bytes(monitor.swapUsed))")
        print("\n== Servicios")
        for s in monitor.services { print("  [\(s.state)] \(s.def.name): \(s.detail)") }
        print("\n== Avisos")
        if monitor.issues.isEmpty { print("  (ninguno)") }
        for i in monitor.issues {
            print("  [\(i.severity)] \(i.title) — \(i.detail)")
            guard CommandLine.arguments.contains("--details"), let d = i.details else { continue }
            if let note = d.note { print("      · \(note)") }
            for r in d.rows { print("      \(r.emphasized ? "▶" : "-") \(r.title)\(r.value.isEmpty ? "" : " — \(r.value)")") }
            if let lazy = d.lazy {
                var result: LoadedDetail?
                Task { result = await DetailLoader.load(lazy) }
                while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                if let note = result?.note { print("      · \(note)") }
                for r in result?.rows ?? [] { print("      \(r.emphasized ? "▶" : "-") \(r.title)\(r.value.isEmpty ? "" : " — \(r.value)")") }
                if let f = result?.readableFile { print("      📄 \(f.path)") }
            }
        }
        print("\n== Mayor consumo de CPU")
        for g in monitor.groups.sorted(by: { $0.cpu1m > $1.cpu1m }).prefix(6) {
            print("  \(g.displayName): \(Format.cpu(g.cpu1m)) (\(g.pids.count) procesos)")
        }
        print("\n== Mayor consumo de memoria")
        for g in monitor.groups.sorted(by: { $0.rss > $1.rss }).prefix(6) {
            print("  \(g.displayName): \(Format.bytes(g.rss)) (\(g.pids.count) procesos) · icono: \(g.iconPath.map { ($0 as NSString).lastPathComponent } ?? "genérico")")
        }
    }
}
