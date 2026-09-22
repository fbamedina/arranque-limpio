import AppKit
import ServiceManagement
import SwiftUI

struct PanelView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var sortByMemory = false
    @State private var showSettings = false
    @State private var expandedIssues = Set<String>()

    init(monitor: SystemMonitor, sortByMemory: Bool = false, expanded: Set<String> = []) {
        self.monitor = monitor
        _sortByMemory = State(initialValue: sortByMemory)
        _expandedIssues = State(initialValue: expanded)
    }

    var body: some View {
        if monitor.paused { pausedBody } else { activeBody }
    }

    private var pausedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Monitorización en pausa").font(.headline)
                    Text("Arranque Limpio no está midiendo nada y no consume recursos.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                monitor.setPaused(false)
            } label: {
                Label("Reanudar monitorización", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            footer
        }
        .padding(16)
        .frame(width: 420)
    }

    private var activeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !monitor.issues.isEmpty || monitor.dismissedCount > 0 { issuesSection }
                    servicesSection
                    consumersSection
                    if showSettings { SettingsSection(monitor: monitor) }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 160))
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(16)
        .frame(width: 420)
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(headerColor)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).font(.headline)
                Text(headerSubtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("Encendido hace \(Format.duration(monitor.uptime))", systemImage: "power")
                    Label("CPU \(Int((monitor.cpuTotal * 100).rounded())) %", systemImage: "cpu")
                    Label("\(Format.bytes(monitor.memUsed)) / \(Format.bytes(SystemInfo.memTotal))", systemImage: "memorychip")
                        .foregroundStyle(monitor.memPressure >= 4 ? .red : monitor.memPressure == 2 ? .orange : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    private var headerSymbol: String {
        switch monitor.overall {
        case .critical: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        default:
            switch monitor.phase {
            case .ready: return "checkmark.seal.fill"
            default: return "hourglass.circle.fill"
            }
        }
    }

    private var headerColor: Color {
        switch monitor.overall {
        case .critical: return .red
        case .warning: return .orange
        default: return monitor.phase == .ready ? .green : .blue
        }
    }

    private var headerTitle: String {
        switch monitor.phase {
        case .measuring: return "Analizando el sistema…"
        case .starting: return "El Mac se está iniciando"
        case .settling: return "Terminando de arrancar"
        case .ready:
            switch monitor.overall {
            case .critical: return "Arranque terminado · hay problemas serios"
            case .warning: return "Arranque terminado · hay avisos"
            default: return "Arranque terminado · todo en orden"
            }
        }
    }

    private var headerSubtitle: String {
        switch monitor.phase {
        case .measuring: return "Tomando muestras durante unos segundos."
        case .starting: return "Espera un par de minutos antes de abrir apps pesadas."
        case .settling(let tasks): return "Aún trabajando en segundo plano: " + tasks.joined(separator: ", ") + "."
        case .ready:
            let n = monitor.issues.filter { $0.severity >= .warning }.count
            return n == 0 ? "Ningún servicio ni proceso está dando problemas." : "\(n) \(n == 1 ? "cosa necesita" : "cosas necesitan") tu atención."
        }
    }

    // MARK: Avisos

    private var issuesSection: some View {
        SectionBox(title: "Avisos") {
            if monitor.issues.isEmpty {
                Text("No hay avisos pendientes.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(monitor.issues) { issue in
                IssueRow(issue: issue,
                         color: color(for: issue.severity),
                         actionLabel: issue.action.map(actionLabel),
                         expanded: expandedIssues.contains(issue.id),
                         onToggle: {
                             withAnimation(.easeInOut(duration: 0.15)) {
                                 if expandedIssues.contains(issue.id) { expandedIssues.remove(issue.id) } else { expandedIssues.insert(issue.id) }
                             }
                         },
                         onAction: { if let a = issue.action { monitor.perform(a) } },
                         onDismiss: { withAnimation { monitor.dismiss(issue) } })
                if issue.id != monitor.issues.last?.id { Divider() }
            }
            if monitor.dismissedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                    Text("\(monitor.dismissedCount) \(monitor.dismissedCount == 1 ? "aviso omitido" : "avisos omitidos")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Mostrar de nuevo") { withAnimation { monitor.restoreDismissed() } }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }

    private func actionLabel(_ action: IssueAction) -> String {
        switch action {
        case .quit: return "Cerrar"
        case .restartService: return "Reiniciar"
        case .stopBackup: return "Detener"
        }
    }

    // MARK: Servicios

    private var servicesSection: some View {
        SectionBox(title: "Servicios del sistema") {
            ForEach(monitor.services) { s in
                HStack(spacing: 10) {
                    Circle().fill(color(for: s.state)).frame(width: 8, height: 8)
                    Image(systemName: s.def.symbol).frame(width: 18).foregroundStyle(.secondary)
                    Text(s.def.name).font(.callout)
                    Spacer(minLength: 8)
                    Text(s.detail)
                        .font(.caption)
                        .foregroundStyle(s.state >= .attention ? color(for: s.state) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(s.detail)
                    if s.canRestart && s.state >= .attention {
                        Button { monitor.restartService(s.def.id) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Reiniciar \(s.def.name)")
                    }
                }
            }
        }
    }

    // MARK: Consumo

    private var topGroups: [ProcessGroup] {
        let sorted = sortByMemory ? monitor.groups.sorted { $0.rss > $1.rss }
                                  : monitor.groups.sorted { $0.cpuRecent > $1.cpuRecent }
        return Array(sorted.prefix(7))
    }

    private var consumersSection: some View {
        let cpuThr = UserDefaults.standard.double(forKey: Settings.cpuThreshold)
        let memThr = UInt64(UserDefaults.standard.double(forKey: Settings.memThresholdGB) * 1_073_741_824)
        let maxValue = max(1, sortByMemory ? Double(topGroups.first?.rss ?? 1) : (topGroups.first?.cpuRecent ?? 1))
        return SectionBox(title: "Mayor consumo", accessory: AnyView(
            Picker("", selection: $sortByMemory) {
                Text("CPU").tag(false)
                Text("Memoria").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        )) {
            ForEach(topGroups) { g in
                let value = sortByMemory ? Double(g.rss) : g.cpuRecent
                let excessive = sortByMemory ? g.rss > memThr : g.cpu1m > cpuThr
                HStack(spacing: 8) {
                    AppIcon(group: g)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(g.displayName).font(.callout).lineLimit(1)
                            if !g.ownedByUser { Text("sistema").font(.caption2).foregroundStyle(.tertiary) }
                            if g.pids.count > 1 { Text("×\(g.pids.count)").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        ProgressView(value: min(value / maxValue, 1))
                            .progressViewStyle(.linear)
                            .tint(excessive ? .red : .accentColor)
                            .controlSize(.mini)
                    }
                    Text(sortByMemory ? Format.bytes(g.rss) : Format.cpu(g.cpuRecent))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(excessive ? .red : .primary)
                        .frame(width: 72, alignment: .trailing)
                    Menu {
                        if g.ownedByUser {
                            Button("Salir") { monitor.quit(g, force: false) }
                            Button("Forzar salida") { monitor.quit(g, force: true) }
                        } else {
                            Text("Proceso del sistema (root)")
                            Button("Copiar «sudo killall \(g.name)»") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("sudo killall \"\(g.name)\"", forType: .string)
                            }
                        }
                        Divider()
                        Text("PID: " + g.pids.prefix(8).map(String.init).joined(separator: ", "))
                        Text("CPU media 1 min: \(Format.cpu(g.cpu1m)) · 5 min: \(Format.cpu(g.cpu5m))")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Pie

    private var footer: some View {
        HStack {
            if !monitor.paused {
                Button {
                    withAnimation { showSettings.toggle() }
                } label: { Label("Ajustes", systemImage: "gearshape") }
                Button {
                    monitor.setPaused(true)
                } label: { Label("Pausar", systemImage: "pause.fill") }
            }
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: { Label("Monitor de Actividad", systemImage: "waveform.path.ecg") }
            Spacer()
            Button("Salir") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: Colores

    private func color(for severity: Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        case .ok: return .green
        }
    }

    private func color(for state: ServiceState) -> Color {
        switch state {
        case .notRunning: return .gray.opacity(0.5)
        case .idle: return .green
        case .busy: return .blue
        case .attention: return .orange
        case .problem: return .red
        }
    }
}

// MARK: - Componentes

struct SectionBox<Content: View>: View {
    let title: String
    var accessory: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

struct AppIcon: View {
    let group: ProcessGroup
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let path = group.iconPath {
                Image(nsImage: Self.icon(for: path)).resizable()
            } else {
                FallbackIcon(group: group)
            }
        }
        .frame(width: 22, height: 22)
    }

    private static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

/// Icono para apps y procesos sin icono propio: una baldosa con estilo de icono de macOS.
///  - app sin icono → inicial del nombre sobre un color propio de esa app
///  - proceso del sistema → engranaje sobre gris
///  - proceso tuyo sin app (herramientas de terminal…) → símbolo de terminal
struct FallbackIcon: View {
    let group: ProcessGroup

    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan, .mint, .brown]

    private var tint: Color {
        if group.appPath != nil {
            let hash = group.displayName.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
            return Self.palette[abs(hash) % Self.palette.count]
        }
        return group.ownedByUser ? Color(white: 0.28) : .gray
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .overlay {
                if group.appPath != nil {
                    Text(String(group.displayName.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: group.ownedByUser ? "terminal.fill" : "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .padding(1)
    }
}

struct SettingsSection: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage(Settings.cpuThreshold) private var cpuThreshold = 80.0
    @AppStorage(Settings.memThresholdGB) private var memThresholdGB = 4.0
    @AppStorage(Settings.notifications) private var notifications = true
    @AppStorage(Settings.refreshInterval) private var refreshInterval = 3.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SectionBox(title: "Ajustes") {
            HStack {
                Text("Avisar si un proceso supera")
                Spacer()
                Stepper("\(Int(cpuThreshold)) % CPU", value: $cpuThreshold, in: 30...400, step: 10)
            }
            HStack {
                Text("Avisar si una app supera")
                Spacer()
                Stepper(String(format: "%.1f GB", memThresholdGB), value: $memThresholdGB, in: 0.5...32, step: 0.5)
            }
            Text("100 % de CPU equivale a un núcleo completo. Este Mac tiene \(SystemInfo.cpuCount) núcleos.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Actualizar cada")
                Spacer()
                Picker("", selection: $refreshInterval) {
                    ForEach([1.0, 2, 3, 5, 10, 30, 60], id: \.self) { s in
                        Text(s < 60 ? "\(Int(s)) s" : "1 min").tag(s)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Enviar notificaciones", isOn: $notifications)
                .onChange(of: notifications) { _, on in if on { monitor.requestNotificationPermission() } }
            Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.callout)
    }
}
