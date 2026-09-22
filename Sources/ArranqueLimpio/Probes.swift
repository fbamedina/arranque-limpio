import Foundation

// MARK: - Procesos

struct ProcSample {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let cpu: Double        // % de un núcleo (100 = un núcleo entero)
    let rss: UInt64        // bytes
    let state: String
    let exe: String        // nombre del ejecutable
    let groupKey: String   // app contenedora o ejecutable
    let groupName: String
    let appPath: String?
}

enum ProcessProbe {
    /// `ps` puede leer todos los procesos (incluidos los de root) sin privilegios.
    static func sample() -> [ProcSample] {
        guard let result = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,state=,comm="]) else { return [] }
        var samples: [ProcSample] = []
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard fields.count == 7,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")),
                  let rssKB = UInt64(fields[4]) else { continue }
            let path = fields[6].trimmingCharacters(in: .whitespaces)
            let exe = (path as NSString).lastPathComponent
            var appPath: String?
            var groupName = exe
            // Agrupa los procesos auxiliares con su app (p. ej. "Google Chrome Helper" → "Google Chrome").
            if let r = path.range(of: ".app/") {
                let bundle = String(path[..<r.lowerBound]) + ".app"
                appPath = bundle
                groupName = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            samples.append(ProcSample(pid: pid, ppid: ppid, uid: uid, cpu: cpu, rss: rssKB * 1024,
                                      state: String(fields[5]), exe: exe,
                                      groupKey: appPath ?? exe, groupName: groupName, appPath: appPath))
        }
        return samples
    }
}

// MARK: - Metadatos de bundles

/// Nombre visible e icono de un bundle `.app`, leídos de su Info.plist (con caché).
enum BundleInfo {
    private static var cache: [String: (name: String?, hasIcon: Bool, id: String?)] = [:]

    private static let lock = NSLock()

    private static func info(_ path: String) -> (name: String?, hasIcon: Bool, id: String?) {
        if let cached = lock.withLock({ cache[path] }) { return cached }
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] ?? [:]
        let name = [plist["CFBundleDisplayName"], plist["CFBundleName"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
        let hasIcon = ["CFBundleIconFile", "CFBundleIconName", "CFBundleIcons"].contains { plist[$0] != nil }
        let entry = (name, hasIcon, plist["CFBundleIdentifier"] as? String)
        lock.withLock { cache[path] = entry }
        return entry
    }

    static func displayName(_ path: String) -> String? { info(path).name }
    static func hasIcon(_ path: String) -> Bool { info(path).hasIcon }

    /// Mismo fabricante = mismo prefijo de identificador (p. ej. "com.anthropic").
    static func sameVendor(_ a: String, _ b: String) -> Bool {
        func vendor(_ path: String) -> String? {
            guard let id = info(path).id else { return nil }
            let parts = id.split(separator: ".")
            return parts.count >= 2 ? parts.prefix(2).joined(separator: ".").lowercased() : nil
        }
        guard let va = vendor(a) else { return false }
        return va == vendor(b)
    }
}

// MARK: - Servicios del sistema conocidos

struct ServiceDef: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let busyText: String
    let processes: Set<String>
    /// Suele trabajar intensamente justo después de arrancar.
    let bootRelated: Bool
    /// Sus procesos corren con el usuario y launchd los relanza si se cierran.
    let restartable: Bool
}

enum ServiceCatalog {
    static let all: [ServiceDef] = [
        ServiceDef(id: "siri", name: "Siri", symbol: "mic.circle", busyText: "Procesando",
                   processes: ["assistantd", "siriactionsd", "siriknowledged", "SiriNCService", "siriinferenced",
                               "sirittsd", "corespeechd", "Siri", "SiriAUSP", "com.apple.siri.embeddedspeech"],
                   bootRelated: true, restartable: true),
        ServiceDef(id: "timemachine", name: "Time Machine", symbol: "clock.arrow.circlepath", busyText: "Copiando",
                   processes: ["backupd", "backupd-helper"], bootRelated: false, restartable: false),
        ServiceDef(id: "spotlight", name: "Spotlight", symbol: "magnifyingglass", busyText: "Indexando",
                   processes: ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd", "Spotlight", "mdbulkimport"],
                   bootRelated: true, restartable: false),
        ServiceDef(id: "icloud", name: "iCloud", symbol: "icloud", busyText: "Sincronizando",
                   processes: ["cloudd", "bird", "fileproviderd", "cloudphotod", "FileProvider", "CloudKeychainProxy"],
                   bootRelated: true, restartable: true),
        ServiceDef(id: "photos", name: "Análisis de Fotos", symbol: "photo.on.rectangle", busyText: "Analizando biblioteca",
                   processes: ["photoanalysisd", "mediaanalysisd", "photolibraryd", "mediaanalysisd-access"],
                   bootRelated: true, restartable: true),
        ServiceDef(id: "intelligence", name: "Sugerencias e Inteligencia", symbol: "sparkles", busyText: "Procesando",
                   processes: ["suggestd", "knowledgeconstructiond", "duetexpertd", "biomesyncd", "intelligenceplatformd",
                               "generativeexperiencesd", "knowledge-agent", "modelmanagerd", "BiomeAgent"],
                   bootRelated: true, restartable: true),
        ServiceDef(id: "security", name: "Seguridad (XProtect)", symbol: "lock.shield", busyText: "Analizando",
                   processes: ["XprotectService", "XProtect", "XProtectRemediator", "syspolicyd", "trustd", "MRT"],
                   bootRelated: true, restartable: false),
        ServiceDef(id: "updates", name: "Actualizaciones", symbol: "arrow.down.circle", busyText: "Descargando/preparando",
                   processes: ["softwareupdated", "mobileassetd", "nsurlsessiond", "installd"],
                   bootRelated: true, restartable: false),
        ServiceDef(id: "graphics", name: "Gráficos (WindowServer)", symbol: "display", busyText: "Muy activo",
                   processes: ["WindowServer"], bootRelated: false, restartable: false),
        ServiceDef(id: "interface", name: "Dock, Finder y barra de menús", symbol: "menubar.dock.rectangle", busyText: "Muy activo",
                   processes: ["Dock", "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter", "WallpaperAgent"],
                   bootRelated: false, restartable: true),
    ]

    /// Procesos que deberían vivir de forma continua: si cambian de PID a menudo, están fallando en bucle.
    static let longLived: Set<String> = [
        "assistantd", "siriactionsd", "siriknowledged", "corespeechd", "WindowServer", "Dock", "Finder",
        "SystemUIServer", "ControlCenter", "NotificationCenter", "cloudd", "bird", "sharingd", "bluetoothd",
        "coreaudiod", "backupd", "loginwindow", "Spotlight", "mds", "photolibraryd", "WallpaperAgent",
        "universalaccessd", "WiFiAgent", "airportd", "fileproviderd", "suggestd", "useractivityd",
    ]
}

// MARK: - Time Machine

struct TimeMachineStatus: Equatable {
    var running = false
    var phase: String?
    var percent: Double?
    var fingerprint = ""

    var phaseDescription: String {
        switch phase {
        case "ThinningPreBackup", "ThinningPostBackup": return "Limpiando copias antiguas"
        case "Copying": return "Copiando"
        case "Finishing": return "Finalizando"
        case "Starting", "Preparing", "PreparingSourceVolumes": return "Preparando"
        case "MountingBackupVol", "MountingDiskImage": return "Montando el disco de copia"
        case "FindingChanges", "FindingBackupVol", "SizingChanges": return "Buscando cambios"
        case "DeletingOldBackups": return "Borrando copias antiguas"
        case let p?: return p
        case nil: return "En curso"
        }
    }
}

enum TimeMachineProbe {
    static func status() -> TimeMachineStatus? {
        guard let result = Shell.run("/usr/bin/tmutil", ["status"]), result.status == 0 else { return nil }
        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \";"))
            if values[key] == nil { values[key] = value }
        }
        var tm = TimeMachineStatus()
        tm.running = values["Running"] == "1"
        tm.phase = values["BackupPhase"]
        if let p = values["Percent"].flatMap(Double.init), p >= 0 { tm.percent = p }
        // Si nada de esto cambia en mucho tiempo, la copia está congelada.
        tm.fingerprint = [values["BackupPhase"], values["Percent"], values["bytes"], values["files"], values["_raw_Percent"]]
            .map { $0 ?? "-" }.joined(separator: "|")
        return tm
    }
}

// MARK: - Informes de diagnóstico

struct DiagReport: Identifiable {
    enum Kind { case crash, hang, cpuResource, jetsam, panic, shutdownStall }
    let process: String
    let kind: Kind
    let date: Date
    let url: URL
    var id: String { url.path }
}

enum ReportsProbe {
    private static let dirs = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
    ]
    private static let nameRegex = try! NSRegularExpression(pattern: #"^(.+?)[-_](\d{4}-\d{2}-\d{2}-\d{6})"#)
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Informes generados desde `since` (los de pánico/apagado atascado se aceptan hasta 2 h antes,
    /// porque explican por qué fue el último reinicio).
    static func reports(since boot: Date) -> [DiagReport] {
        var out: [DiagReport] = []
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files {
                let name = url.lastPathComponent
                let ns = name as NSString
                guard let m = nameRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                      let date = dateFormatter.date(from: ns.substring(with: m.range(at: 2))) else { continue }
                var process = ns.substring(with: m.range(at: 1))
                let kind: DiagReport.Kind
                if name.hasSuffix(".cpu_resource.diag") { kind = .cpuResource }
                else if name.hasSuffix(".hang") || name.hasSuffix(".spin") { kind = .hang }
                else if name.hasSuffix(".shutdownStall") { kind = .shutdownStall }
                else if name.hasSuffix(".panic") || process.hasPrefix("panic") { kind = .panic }
                else if name.hasSuffix(".crash") { kind = .crash }
                else if name.hasSuffix(".ips") {
                    guard let header = ipsHeader(url) else { continue }
                    switch header.bugType {
                    case "309", "109", "385": kind = .crash
                    case "298": kind = .jetsam
                    case "210": kind = .panic
                    default: continue
                    }
                    if let app = header.appName, !app.isEmpty { process = app }
                } else { continue }

                let earliest = (kind == .panic || kind == .shutdownStall) ? boot.addingTimeInterval(-7200) : boot
                guard date >= earliest else { continue }
                out.append(DiagReport(process: process, kind: kind, date: date, url: url))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    private static func ipsHeader(_ url: URL) -> (bugType: String?, appName: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2048),
              let firstLine = data.split(separator: UInt8(ascii: "\n")).first,
              let json = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else { return nil }
        return (json["bug_type"] as? String, (json["app_name"] as? String) ?? (json["name"] as? String))
    }
}
