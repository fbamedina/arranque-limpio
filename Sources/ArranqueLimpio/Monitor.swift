import AppKit
import Foundation
import ServiceManagement
import UserNotifications

enum Severity: Int, Comparable {
    case ok, info, warning, critical
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

enum BootPhase: Equatable {
    case measuring
    case starting
    case settling([String])
    case ready
}

enum IssueAction {
    case quit(groupKey: String)
    case restartService(String)
    case stopBackup
}

struct Issue: Identifiable {
    let id: String
    let severity: Severity
    let symbol: String
    let title: String
    let detail: String
    var action: IssueAction?
    /// Información ampliada que se muestra al desplegar el aviso.
    var details: IssueDetails?
    /// Para avisos basados en informes: cambia cuando aparece un informe nuevo.
    /// Si es nil, el aviso es un estado en vivo y cada episodio (aparece → desaparece) cuenta como uno.
    var evidence: String?
    /// Identifica esta ocurrencia concreta; omitir un aviso oculta solo esta ocurrencia.
    var occurrence = ""
}

struct ProcessGroup: Identifiable {
    let id: String
    let name: String          // nombre del ejecutable o bundle (para reconocer servicios)
    let displayName: String   // nombre que se muestra
    let appPath: String?
    let iconPath: String?     // bundle del que tomar el icono (el propio o el de la app que lo lanzó)
    let pids: [Int32]
    let ownedByUser: Bool
    let cpuRecent: Double   // media ~10 s, % de un núcleo
    let cpu1m: Double
    let cpu5m: Double
    let coverage: TimeInterval
    let rss: UInt64
    let rssGrowth: Int64?   // variación en ~10 min
}

enum ServiceState: Int, Comparable {
    case notRunning, idle, busy, attention, problem
    static func < (a: ServiceState, b: ServiceState) -> Bool { a.rawValue < b.rawValue }
}

struct ServiceStatus: Identifiable {
    let def: ServiceDef
    let state: ServiceState
    let detail: String
    let canRestart: Bool
    var id: String { def.id }
}

enum Settings {
    static let cpuThreshold = "cpuThreshold"
    static let memThresholdGB = "memThresholdGB"
    static let notifications = "notificationsEnabled"
    static let refreshInterval = "refreshInterval"
    static let paused = "monitoringPaused"

    static func register() {
        UserDefaults.standard.register(defaults: [cpuThreshold: 80.0, memThresholdGB: 4.0, notifications: true, refreshInterval: 3.0])
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var phase: BootPhase = .measuring
    /// En pausa no hay temporizador ni muestreo: la app queda en la barra sin consumir CPU.
    @Published private(set) var paused = false
    @Published private(set) var overall: Severity = .ok
    /// Gravedad de los avisos de consumo (umbrales de CPU/memoria de Ajustes): colorea el icono.
    @Published private(set) var resourceLevel: Severity = .ok
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var services: [ServiceStatus] = []
    /// Avisos visibles (sin los omitidos).
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var dismissedCount = 0
    @Published private(set) var reports: [DiagReport] = []
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var cpuTotal: Double = 0      // fracción 0…1 de toda la CPU
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memPressure = 1
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var timeMachine: TimeMachineStatus?
    @Published private(set) var lastUpdate: Date?

    private struct Sample { let t: Date; let cpu: Double; let rss: UInt64 }
    private struct GroupInfo {
        var name: String
        var appPath: String?
        var displayName: String
        var iconPath: String?
        var pids: [Int32] = []
        var owned = false
        var cpu = 0.0
        var rss: UInt64 = 0
    }

    private var interval: TimeInterval { max(1, UserDefaults.standard.double(forKey: Settings.refreshInterval)) }
    private let historyWindow: TimeInterval = 600
    private var history: [String: [Sample]] = [:]
    private var current: [String: GroupInfo] = [:]
    private var totalHistory: [(t: Date, cpu: Double)] = []
    private var lastPids: [String: Set<Int32>] = [:]
    private var restartEvents: [String: [Date]] = [:]
    private var stuckSince: [Int32: Date] = [:]
    private var stuckNames: [Int32: String] = [:]
    private var zombieCount = 0
    private var zombies: [ProcSample] = []
    private var procsByGroup: [String: [ProcSample]] = [:]
    private var procByPid: [Int32: ProcSample] = [:]
    /// Inicio de cada episodio de un aviso en vivo, y última vez que se vio.
    private var episodes: [String: (start: Date, lastSeen: Date)] = [:]
    /// Avisos omitidos: id → ocurrencia omitida.
    private var dismissed: [String: String] = (UserDefaults.standard.dictionary(forKey: "dismissedIssues") as? [String: String]) ?? [:]
    private var allIssues: [Issue] = []
    private var tmLastProgress: (fingerprint: String, since: Date)?
    private var lastTMCheck = Date.distantPast
    private var lastReportsCheck = Date.distantPast
    private var sampling = false
    private var sawBooting = false
    private var notified: [String: Date] = [:]
    private var timer: Timer?
    private let myUID = getuid()

    /// Sin notificaciones (modos de terminal); no modifica los ajustes guardados.
    private let silent: Bool

    /// `terminalMode`: para --report y --snapshot. Siempre mide y nunca notifica.
    init(terminalMode: Bool = false) {
        Settings.register()
        silent = terminalMode
        paused = !terminalMode && UserDefaults.standard.bool(forKey: Settings.paused)
        if !silent, UserDefaults.standard.bool(forKey: Settings.notifications) { requestNotificationPermission() }
        if !paused {
            tick()
            scheduleTimer()
        }
        // Si cambia el tiempo de refresco en Ajustes, se reprograma el temporizador.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused, self.timer?.timeInterval != self.interval else { return }
                self.scheduleTimer()
            }
        }
    }

    // MARK: Pausa

    func setPaused(_ newValue: Bool) {
        guard newValue != paused else { return }
        paused = newValue
        UserDefaults.standard.set(newValue, forKey: Settings.paused)
        if newValue {
            timer?.invalidate()
            timer = nil
            resetState()
        } else {
            lastTMCheck = .distantPast
            lastReportsCheck = .distantPast
            tick()
            scheduleTimer()
        }
    }

    /// Libera todo el historial acumulado; al reanudar se empieza a medir de cero.
    private func resetState() {
        history = [:]
        current = [:]
        totalHistory = []
        lastPids = [:]
        restartEvents = [:]
        stuckSince = [:]
        stuckNames = [:]
        zombieCount = 0
        tmLastProgress = nil
        sawBooting = false
        groups = []
        services = []
        issues = []
        allIssues = []
        episodes = [:]
        procsByGroup = [:]
        procByPid = [:]
        zombies = []
        reports = []
        timeMachine = nil
        overall = .ok
        resourceLevel = .ok
        phase = .measuring
        cpuTotal = 0
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval * 0.1
    }

    // MARK: Muestreo

    private func tick() {
        guard !sampling else { return }
        sampling = true
        let now = Date()
        let checkTM = now.timeIntervalSince(lastTMCheck) >= 20
        let checkReports = now.timeIntervalSince(lastReportsCheck) >= 60
        if checkTM { lastTMCheck = now }
        if checkReports { lastReportsCheck = now }
        let boot = SystemInfo.bootTime

        Task.detached(priority: .utility) {
            let procs = ProcessProbe.sample()
            let tm = checkTM ? TimeMachineProbe.status() : nil
            let reps = checkReports ? ReportsProbe.reports(since: boot) : nil
            let mem = SystemInfo.memoryUsed()
            let pressure = SystemInfo.memoryPressureLevel()
            let swap = SystemInfo.swapUsed()
            await MainActor.run {
                guard !self.paused else { self.sampling = false; return }   // pausado durante la muestra
                if checkTM { self.updateTimeMachine(tm, now: now) }
                if let reps { self.reports = reps }
                self.memUsed = mem
                self.memPressure = pressure
                self.swapUsed = swap
                self.ingest(procs, now: now)
                self.evaluate(now: now)
                self.lastUpdate = now
                self.sampling = false
            }
        }
    }

    private func updateTimeMachine(_ tm: TimeMachineStatus?, now: Date) {
        timeMachine = tm
        guard let tm, tm.running else { tmLastProgress = nil; return }
        if tmLastProgress?.fingerprint != tm.fingerprint { tmLastProgress = (tm.fingerprint, now) }
    }

    private func ingest(_ procs: [ProcSample], now: Date) {
        guard !procs.isEmpty else { return }
        var groupsNow: [String: GroupInfo] = [:]
        var pidsByExe: [String: Set<Int32>] = [:]
        var total = 0.0
        var zombies = 0
        var stuck: [Int32: Date] = [:]
        var byGroup: [String: [ProcSample]] = [:]
        var zombieList: [ProcSample] = []
        let launchers = launchingApps(procs)

        for p in procs {
            var key = p.groupKey, name = p.groupName, appPath = p.appPath
            // Un bundle sin icono lanzado por una app del mismo fabricante forma parte de ella
            // (p. ej. Claude Code dentro de Claude).
            if let app = appPath, let launcher = launchers[app], BundleInfo.sameVendor(app, launcher) {
                key = launcher
                appPath = launcher
                name = ((launcher as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            var g = groupsNow[key] ?? GroupInfo(name: name, appPath: appPath,
                                                displayName: appPath.flatMap(BundleInfo.displayName) ?? name)
            g.pids.append(p.pid)
            g.cpu += p.cpu
            g.rss += p.rss
            if p.uid == myUID { g.owned = true }
            groupsNow[key] = g
            byGroup[key, default: []].append(p)
            total += p.cpu
            if ServiceCatalog.longLived.contains(p.exe) { pidsByExe[p.exe, default: []].insert(p.pid) }
            if p.state.hasPrefix("Z") { zombies += 1; zombieList.append(p) }
            if p.state.hasPrefix("U") { stuck[p.pid] = stuckSince[p.pid] ?? now; stuckNames[p.pid] = p.exe }
        }
        for (key, g) in groupsNow {
            guard let app = g.appPath else { continue }
            // Icono propio o, si no tiene, el de la app que lo lanzó.
            groupsNow[key]?.iconPath = BundleInfo.hasIcon(app) ? app : launchers[app]
        }
        current = groupsNow
        procsByGroup = byGroup
        procByPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        zombieCount = zombies
        self.zombies = zombieList
        stuckSince = stuck
        stuckNames = stuckNames.filter { stuck[$0.key] != nil }

        for (key, g) in groupsNow { history[key, default: []].append(Sample(t: now, cpu: g.cpu, rss: g.rss)) }
        let cutoff = now.addingTimeInterval(-historyWindow)
        history = history.compactMapValues { samples in
            let kept = samples.filter { $0.t >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        totalHistory.append((now, total))
        totalHistory.removeAll { $0.t < cutoff }

        // Un proceso "de larga duración" que aparece con PIDs totalmente nuevos = se ha reiniciado.
        for (exe, pids) in pidsByExe {
            if let prev = lastPids[exe], !prev.isEmpty, prev.isDisjoint(with: pids) {
                restartEvents[exe, default: []].append(now)
            }
            lastPids[exe] = pids
        }
        restartEvents = restartEvents.compactMapValues { events in
            let kept = events.filter { $0 >= cutoff }
            return kept.isEmpty ? nil : kept
        }
    }

    /// Para cada bundle sin icono, la primera app con icono entre sus procesos antecesores.
    private func launchingApps(_ procs: [ProcSample]) -> [String: String] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: String] = [:]
        for p in procs {
            guard let app = p.appPath, !BundleInfo.hasIcon(app), result[app] == nil else { continue }
            var next = p.ppid
            for _ in 0..<12 {
                guard next > 1, let parent = byPid[next] else { break }
                if let parentApp = parent.appPath, parentApp != app, BundleInfo.hasIcon(parentApp) {
                    result[app] = parentApp
                    break
                }
                next = parent.ppid
            }
        }
        return result
    }

    private func average(_ samples: [Sample], window: TimeInterval, now: Date) -> (cpu: Double, coverage: TimeInterval) {
        let inWindow = samples.filter { now.timeIntervalSince($0.t) <= window }
        guard let first = inWindow.first else { return (0, 0) }
        return (inWindow.reduce(0) { $0 + $1.cpu } / Double(inWindow.count), now.timeIntervalSince(first.t))
    }

    // MARK: Evaluación

    private func evaluate(now: Date) {
        let defaults = UserDefaults.standard
        let cpuThr = defaults.double(forKey: Settings.cpuThreshold)
        let memThr = UInt64(defaults.double(forKey: Settings.memThresholdGB) * 1_073_741_824)
        let up = now.timeIntervalSince(SystemInfo.bootTime)
        uptime = up

        // Grupos de procesos con sus medias.
        var gs: [ProcessGroup] = []
        for (key, info) in current {
            let h = history[key] ?? []
            let recent = average(h, window: 10, now: now)
            let m1 = average(h, window: 60, now: now)
            let m5 = average(h, window: 300, now: now)
            var growth: Int64?
            if let first = h.first, now.timeIntervalSince(first.t) >= 480 {
                growth = Int64(info.rss) - Int64(first.rss)
            }
            gs.append(ProcessGroup(id: key, name: info.name, displayName: info.displayName, appPath: info.appPath,
                                   iconPath: info.iconPath, pids: info.pids,
                                   ownedByUser: info.owned, cpuRecent: recent.cpu, cpu1m: m1.cpu, cpu5m: m5.cpu,
                                   coverage: m5.coverage, rss: info.rss, rssGrowth: growth))
        }
        groups = gs

        let totalRecent = totalHistory.filter { now.timeIntervalSince($0.t) <= 10 }
        cpuTotal = totalRecent.isEmpty ? 0 : totalRecent.reduce(0) { $0 + $1.cpu } / Double(totalRecent.count) / Double(SystemInfo.cpuCount * 100)
        let total1m = totalHistory.filter { now.timeIntervalSince($0.t) <= 60 }
        let totalLoad1m = total1m.isEmpty ? 0 : total1m.reduce(0) { $0 + $1.cpu } / Double(total1m.count) / Double(SystemInfo.cpuCount * 100)
        let dataCoverage = totalHistory.first.map { now.timeIntervalSince($0.t) } ?? 0

        var newIssues: [Issue] = []
        var serviceProcesses = Set<String>()

        // Servicios del sistema.
        var svc: [ServiceStatus] = []
        for def in ServiceCatalog.all {
            serviceProcesses.formUnion(def.processes)
            let members = gs.filter { def.processes.contains($0.name) }
            let cpu1 = members.reduce(0) { $0 + $1.cpu1m }
            let cpu5 = members.reduce(0) { $0 + $1.cpu5m }
            let cover = members.map(\.coverage).max() ?? 0
            let restartTimes = def.processes.flatMap { name in (restartEvents[name] ?? []).map { (name, $0) } }
            let failures = reports.filter { def.processes.contains($0.process) && ($0.kind == .crash || $0.kind == .hang) }
            let cpuReports = reports.filter { def.processes.contains($0.process) && $0.kind == .cpuResource }

            var state: ServiceState = members.isEmpty ? .notRunning : .idle
            var detail = members.isEmpty ? "No se está ejecutando" : "En reposo"
            var live = true   // el estado más grave viene de datos en vivo (no de informes)
            func escalate(_ s: ServiceState, _ d: String, live l: Bool = true) {
                if s > state { state = s; detail = d; live = l }
            }

            if cpu1 > 15 { escalate(.busy, "\(def.busyText) · \(Format.cpu(cpu1)) CPU") }
            if !cpuReports.isEmpty {
                escalate(.attention, "macOS registró uso excesivo de CPU \(cpuReports.count) \(cpuReports.count == 1 ? "vez" : "veces") desde el arranque", live: false)
            }
            if !failures.isEmpty {
                escalate(failures.count >= 3 ? .problem : .attention,
                         "Ha fallado o se ha colgado \(failures.count) \(failures.count == 1 ? "vez" : "veces") desde el arranque", live: false)
            }
            if restartTimes.count >= 3 {
                escalate(.problem, "Se ha reiniciado \(restartTimes.count) veces en 10 min (fallo en bucle)")
            }
            if cpu5 > cpuThr, cover >= 240, up > 20 * 60 || !def.bootRelated {
                escalate(.problem, "Lleva más de 5 min usando \(Format.cpu(cpu5)) de CPU")
            }
            var tmRows: [DetailRow] = []
            if def.id == "timemachine", let tm = timeMachine, tm.running {
                let pct = tm.percent.map { " · \(Int($0 * 100)) %" } ?? ""
                escalate(.busy, "\(tm.phaseDescription)\(pct)")
                tmRows.append(DetailRow(title: "Fase", value: tm.phaseDescription))
                if let p = tm.percent { tmRows.append(DetailRow(title: "Progreso", value: "\(Int(p * 100)) %")) }
                if let since = tmLastProgress?.since {
                    tmRows.append(DetailRow(title: "Último avance", value: "hace \(Format.duration(now.timeIntervalSince(since)))",
                                            emphasized: now.timeIntervalSince(since) > 15 * 60))
                    if now.timeIntervalSince(since) > 15 * 60 {
                        escalate(.problem, "Sin progreso desde hace \(Format.duration(now.timeIntervalSince(since))) (\(tm.phaseDescription.lowercased()))")
                    }
                }
            }

            let canRestart = def.restartable && members.contains { $0.ownedByUser }
            svc.append(ServiceStatus(def: def, state: state, detail: detail, canRestart: canRestart))

            if state >= .attention {
                let action: IssueAction? = def.id == "timemachine" ? .stopBackup : (canRestart ? .restartService(def.id) : nil)
                var rows = tmRows
                rows += members.sorted { $0.cpu1m > $1.cpu1m }.prefix(4).map {
                    DetailRow(title: $0.displayName, value: "\(Format.cpu($0.cpu1m)) CPU · \(Format.bytes($0.rss))")
                }
                rows += restartTimes.sorted { $0.1 > $1.1 }.map {
                    DetailRow(title: "\($0.0) reiniciado", value: $0.1.formatted(date: .omitted, time: .standard), emphasized: true)
                }
                let serviceReports = (failures + cpuReports).map(\.url)
                newIssues.append(Issue(id: "svc-\(def.id)", severity: state == .problem ? .warning : .info,
                                       symbol: def.symbol, title: def.id == "timemachine" && state == .problem ? "Time Machine parece congelado" : def.name,
                                       detail: detail, action: action,
                                       details: IssueDetails(note: members.isEmpty ? "Ahora mismo no hay procesos de \(def.name) en ejecución." : nil,
                                                             rows: rows, lazy: serviceReports.isEmpty ? nil : .reports(serviceReports)),
                                       evidence: live ? nil : "\(state.rawValue)|" + signature(failures + cpuReports)))
            }
        }
        services = svc

        // Fase de arranque.
        let busyBoot = svc.filter { $0.def.bootRelated && $0.state == .busy }.map(\.def.name)
        let newPhase: BootPhase
        if up < 120 { newPhase = .starting }
        else if dataCoverage < 20 { newPhase = .measuring }
        else if up < 30 * 60 && (!busyBoot.isEmpty || totalLoad1m > 0.35) {
            newPhase = .settling(busyBoot.isEmpty ? ["Carga general del sistema alta"] : busyBoot)
        } else { newPhase = .ready }

        // Procesos con consumo exagerado.
        let topByMemory = gs.sorted { $0.rss > $1.rss }.prefix(6).map {
            DetailRow(title: $0.displayName, value: "\(Format.bytes($0.rss)) · \($0.pids.count) \($0.pids.count == 1 ? "proceso" : "procesos")")
        }
        for g in gs {
            let expectedBootWork = up < 30 * 60 && svc.contains { $0.def.bootRelated && $0.def.processes.contains(g.name) }
            if g.cpu1m > cpuThr, g.coverage >= 30, !expectedBootWork {
                if g.name == "kernel_task" {
                    let hottest = gs.filter { $0.name != "kernel_task" }.sorted { $0.cpu5m > $1.cpu5m }.prefix(5).map {
                        DetailRow(title: $0.displayName, value: "\(Format.cpu($0.cpu5m)) CPU de media en 5 min")
                    }
                    newIssues.append(Issue(id: "cpu-kernel_task", severity: .warning, symbol: "thermometer.high",
                                           title: "El Mac está limitando la CPU por temperatura",
                                           detail: "kernel_task ocupa \(Format.cpu(g.cpu1m)) para enfriar el equipo. Revisa qué app lo calienta.",
                                           details: IssueDetails(note: "Apps que más CPU han usado en los últimos 5 minutos (las que más calientan):", rows: hottest)))
                } else {
                    newIssues.append(Issue(id: "cpu-\(g.id)", severity: g.cpu1m > cpuThr * 2 ? .critical : .warning, symbol: "cpu",
                                           title: "\(g.displayName) usa mucha CPU",
                                           detail: "\(Format.cpu(g.cpu1m)) de media durante el último minuto (100 % = un núcleo)",
                                           action: g.ownedByUser ? .quit(groupKey: g.id) : nil,
                                           details: groupDetails(g, sortByCPU: true)))
                }
            }
            if g.rss > memThr {
                newIssues.append(Issue(id: "mem-\(g.id)", severity: g.rss > memThr * 2 ? .critical : .warning, symbol: "memorychip",
                                       title: "\(g.displayName) usa mucha memoria",
                                       detail: "\(Format.bytes(g.rss)) en \(g.pids.count) \(g.pids.count == 1 ? "proceso" : "procesos")",
                                       action: g.ownedByUser ? .quit(groupKey: g.id) : nil,
                                       details: groupDetails(g, sortByCPU: false)))
            }
            if let growth = g.rssGrowth, growth > 1_500_000_000 {
                var d = groupDetails(g, sortByCPU: false)
                d.note = "Ha pasado de \(Format.bytes(UInt64(max(0, Int64(g.rss) - growth)))) a \(Format.bytes(g.rss)) en unos 10 minutos. " + (d.note ?? "")
                newIssues.append(Issue(id: "leak-\(g.id)", severity: .warning, symbol: "chart.line.uptrend.xyaxis",
                                       title: "\(g.displayName) no para de crecer en memoria",
                                       detail: "+\(Format.bytes(UInt64(growth))) en los últimos 10 min (posible fuga de memoria)",
                                       action: g.ownedByUser ? .quit(groupKey: g.id) : nil, details: d))
            }
        }

        // Memoria global.
        let memoryDetails = IssueDetails(note: "Memoria usada: \(Format.bytes(memUsed)) de \(Format.bytes(SystemInfo.memTotal)) · swap: \(Format.bytes(swapUsed)). Lo que más memoria ocupa:",
                                         rows: topByMemory)
        if memPressure >= 4 {
            newIssues.append(Issue(id: "pressure-4", severity: .critical, symbol: "gauge.with.dots.needle.100percent",
                                   title: "Presión de memoria crítica", detail: "El Mac se ha quedado sin memoria libre. Cierra apps pesadas.",
                                   details: memoryDetails))
        } else if memPressure == 2 {
            newIssues.append(Issue(id: "pressure-2", severity: .warning, symbol: "gauge.with.dots.needle.67percent",
                                   title: "Presión de memoria alta", detail: "macOS está comprimiendo y usando disco como memoria.",
                                   details: memoryDetails))
        }
        if swapUsed > 4 * 1_073_741_824 {
            newIssues.append(Issue(id: "swap", severity: .info, symbol: "externaldrive",
                                   title: "Uso de swap elevado", detail: "\(Format.bytes(swapUsed)) de memoria volcada a disco",
                                   details: memoryDetails))
        }

        // Informes de diagnóstico desde el arranque.
        let jetsams = reports.filter { $0.kind == .jetsam }
        if !jetsams.isEmpty {
            newIssues.append(Issue(id: "jetsam", severity: .warning, symbol: "memorychip.fill",
                                   title: "macOS cerró procesos por falta de memoria",
                                   detail: "\(jetsams.count) \(jetsams.count == 1 ? "vez" : "veces") desde el arranque",
                                   details: IssueDetails(note: "Cuando falta memoria, macOS cierra procesos en segundo plano (Jetsam).",
                                                         lazy: .reports(jetsams.map(\.url))),
                                   evidence: signature(jetsams)))
        }
        if let panic = reports.first(where: { $0.kind == .panic }) {
            newIssues.append(Issue(id: "panic", severity: .warning, symbol: "bolt.trianglebadge.exclamationmark",
                                   title: panic.date < SystemInfo.bootTime ? "El último reinicio fue por un error grave (kernel panic)" : "Error grave del sistema (kernel panic)",
                                   detail: "Informe del \(panic.date.formatted(date: .abbreviated, time: .shortened))",
                                   details: IssueDetails(lazy: .reports([panic.url])),
                                   evidence: panic.url.path))
        }
        if let stall = reports.first(where: { $0.kind == .shutdownStall }) {
            newIssues.append(Issue(id: "stall", severity: .info, symbol: "power",
                                   title: "El último apagado se quedó atascado",
                                   detail: "Alguna app no se cerró a tiempo (\(stall.date.formatted(date: .omitted, time: .shortened))). Despliega para ver cuáles.",
                                   details: IssueDetails(lazy: .shutdownStall(stall.url)),
                                   evidence: stall.url.path))
        }
        let appFailures = Dictionary(grouping: reports.filter { ($0.kind == .crash || $0.kind == .hang) && !serviceProcesses.contains($0.process) },
                                     by: \.process)
        var minorCrashes: [DiagReport] = []
        for (process, list) in appFailures.sorted(by: { $0.value.count > $1.value.count }) {
            let hangs = list.filter { $0.kind == .hang }.count
            if hangs > 0 {
                newIssues.append(Issue(id: "hang-\(process)", severity: .warning, symbol: "hourglass.badge.exclamationmark",
                                       title: "\(process) se ha quedado colgada",
                                       detail: "\(hangs) \(hangs == 1 ? "bloqueo" : "bloqueos") desde el arranque",
                                       details: IssueDetails(lazy: .reports(list.map(\.url))), evidence: signature(list)))
            } else if list.count >= 3 {
                newIssues.append(Issue(id: "crash-\(process)", severity: .warning, symbol: "exclamationmark.bubble",
                                       title: "\(process) falla repetidamente",
                                       detail: "\(list.count) cierres inesperados desde el arranque",
                                       details: IssueDetails(lazy: .reports(list.map(\.url))), evidence: signature(list)))
            } else {
                minorCrashes += list
            }
        }
        if !minorCrashes.isEmpty {
            let names = Array(Set(minorCrashes.map(\.process))).sorted()
            newIssues.append(Issue(id: "crashes-minor", severity: .info, symbol: "exclamationmark.bubble",
                                   title: "Cierres inesperados desde el arranque",
                                   detail: names.prefix(6).joined(separator: ", ") + (names.count > 6 ? "…" : ""),
                                   details: IssueDetails(lazy: .reports(minorCrashes.map(\.url))), evidence: signature(minorCrashes)))
        }

        // Procesos bloqueados o zombis.
        for (pid, since) in stuckSince where now.timeIntervalSince(since) >= 15 {
            let exe = stuckNames[pid] ?? "PID \(pid)"
            let parent = procByPid[pid].flatMap { procByPid[$0.ppid] }
            newIssues.append(Issue(id: "stuck-\(pid)", severity: .warning, symbol: "lock.trianglebadge.exclamationmark",
                                   title: "\(exe) está bloqueado",
                                   detail: "Lleva \(Format.duration(now.timeIntervalSince(since))) esperando al disco o a la red (PID \(pid))",
                                   details: IssueDetails(note: "Estado «U»: espera ininterrumpible de disco o red. Suele deberse a un disco externo o una carpeta de red que no responde.",
                                                         rows: [DetailRow(title: "Proceso", value: "\(exe) (PID \(pid))"),
                                                                DetailRow(title: "Lanzado por", value: parent.map { "\($0.exe) (PID \($0.pid))" } ?? "—")])))
        }
        if zombieCount >= 5 {
            let rows = Dictionary(grouping: zombies, by: \.ppid).sorted { $0.value.count > $1.value.count }.prefix(8).map { ppid, list in
                DetailRow(title: procByPid[ppid].map { "\($0.groupName) (PID \(ppid))" } ?? "PID \(ppid)",
                          value: "\(list.count) \(list.count == 1 ? "zombi" : "zombis")")
            }
            newIssues.append(Issue(id: "zombies", severity: .info, symbol: "figure.walk",
                                   title: "\(zombieCount) procesos zombi",
                                   detail: "Procesos terminados que su padre no ha recogido. Suelen ser inofensivos.",
                                   details: IssueDetails(note: "Procesos padre que no los han recogido (reiniciarlos los elimina):", rows: rows)))
        }

        applyDismissals(newIssues, now: now)
        updatePhase(newPhase)
        notifyNewIssues(issues)
    }

    // MARK: Omitir avisos

    private func signature(_ list: [DiagReport]) -> String {
        "\(list.count)|\(list.map(\.url.lastPathComponent).max() ?? "")"
    }

    private func groupDetails(_ g: ProcessGroup, sortByCPU: Bool) -> IssueDetails {
        let procs = (procsByGroup[g.id] ?? []).sorted { sortByCPU ? $0.cpu > $1.cpu : $0.rss > $1.rss }
        let rows = procs.prefix(8).map {
            DetailRow(title: "\($0.exe) (PID \($0.pid))", value: "\(Format.cpu($0.cpu)) CPU · \(Format.bytes($0.rss))")
        }
        var note = procs.count > 8 ? "Los 8 procesos que más consumen de \(procs.count)." : nil
        if let path = g.appPath { note = [note, "Ubicación: \(path)"].compactMap { $0 }.joined(separator: " ") }
        return IssueDetails(note: note, rows: rows)
    }

    /// Calcula la ocurrencia de cada aviso, filtra los omitidos y actualiza el estado global.
    private func applyDismissals(_ raw: [Issue], now: Date) {
        var all: [Issue] = []
        for var issue in raw {
            if let evidence = issue.evidence {
                issue.occurrence = evidence
            } else {
                // Un aviso en vivo que desaparece menos de 60 s sigue siendo el mismo episodio.
                let start = episodes[issue.id]?.start ?? now
                episodes[issue.id] = (start, now)
                issue.occurrence = "episodio-\(Int(start.timeIntervalSince1970))"
            }
            all.append(issue)
        }
        episodes = episodes.filter { now.timeIntervalSince($0.value.lastSeen) < 60 }

        // Olvida omisiones de avisos que ya no existen (si vuelven, serán una ocurrencia nueva).
        let activeIDs = Set(all.map(\.id)).union(episodes.keys)
        let pruned = dismissed.filter { activeIDs.contains($0.key) }
        if pruned.count != dismissed.count { dismissed = pruned; saveDismissed() }

        all.sort { $0.severity > $1.severity }
        allIssues = all
        let visible = all.filter { dismissed[$0.id] != $0.occurrence }
        issues = visible
        dismissedCount = all.count - visible.count
        overall = visible.map(\.severity).max() ?? .ok
        let resourcePrefixes = ["cpu-", "mem-", "leak-", "pressure-"]
        resourceLevel = visible.filter { i in resourcePrefixes.contains { i.id.hasPrefix($0) } }.map(\.severity).max() ?? .ok
    }

    func dismiss(_ issue: Issue) {
        dismissed[issue.id] = issue.occurrence
        saveDismissed()
        applyDismissals(allIssues, now: Date())
    }

    func restoreDismissed() {
        dismissed = [:]
        saveDismissed()
        applyDismissals(allIssues, now: Date())
    }

    private func saveDismissed() {
        UserDefaults.standard.set(dismissed, forKey: "dismissedIssues")
    }

    private func updatePhase(_ newPhase: BootPhase) {
        switch newPhase {
        case .starting, .settling: sawBooting = true
        case .ready where sawBooting:
            sawBooting = false
            let pending = issues.filter { $0.severity >= .warning }.count
            notify(id: "boot-done", title: "El Mac ha terminado de arrancar",
                   body: pending == 0 ? "Todo en orden: ya puedes trabajar con normalidad." : "Arranque completado, pero hay \(pending) \(pending == 1 ? "aviso" : "avisos").")
        default: break
        }
        phase = newPhase
    }

    // MARK: Menú de barra

    var menuImage: NSImage {
        if paused { return MenuBarIcon.image(resourceLevel: .ok, badge: .paused) }
        let badge: MenuBarIcon.Badge
        if overall >= .warning { badge = .alert }
        else if phase == .ready { badge = .check }
        else { badge = .busy }
        return MenuBarIcon.image(resourceLevel: resourceLevel, badge: badge)
    }

    // MARK: Acciones

    func perform(_ action: IssueAction) {
        switch action {
        case .quit(let key): if let g = groups.first(where: { $0.id == key }) { quit(g, force: false) }
        case .restartService(let id): restartService(id)
        case .stopBackup: Task.detached { Shell.run("/usr/bin/tmutil", ["stopbackup"]) }
        }
    }

    func quit(_ group: ProcessGroup, force: Bool) {
        if let path = group.appPath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            _ = force ? app.forceTerminate() : app.terminate()
            return
        }
        signal(pids: group.pids, force: force)
    }

    func restartService(_ id: String) {
        guard let def = ServiceCatalog.all.first(where: { $0.id == id }) else { return }
        let pids = groups.filter { def.processes.contains($0.name) && $0.ownedByUser }.flatMap(\.pids)
        signal(pids: pids, force: false)   // launchd los vuelve a lanzar
    }

    private func signal(pids: [Int32], force: Bool) {
        for pid in pids { kill(pid, force ? SIGKILL : SIGTERM) }   // solo tiene efecto sobre procesos propios
    }

    // MARK: Notificaciones

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyNewIssues(_ list: [Issue]) {
        guard phase != .measuring else { return }
        for issue in list where issue.severity >= .warning {
            notify(id: issue.id, title: issue.title, body: issue.detail)
        }
    }

    private func notify(id: String, title: String, body: String) {
        guard !silent, UserDefaults.standard.bool(forKey: Settings.notifications) else { return }
        if let last = notified[id], Date().timeIntervalSince(last) < 3600 { return }
        notified[id] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
