import Foundation

// MARK: - Modelo

struct DetailRow: Identifiable, Hashable {
    var id: String { title + "|" + value }
    var title: String
    var value: String = ""
    /// Resaltada: la causa probable o lo más relevante.
    var emphasized = false
}

/// Información ampliada de un aviso: datos en vivo (`rows`) y, si procede, informes de diagnóstico
/// que se analizan solo cuando el usuario despliega el aviso (`lazy`).
struct IssueDetails {
    var note: String?
    var rows: [DetailRow] = []
    var lazy: LazyDetail?
}

enum LazyDetail: Hashable {
    case shutdownStall(URL)
    case reports([URL])

    var files: [URL] {
        switch self {
        case .shutdownStall(let url): return [url]
        case .reports(let urls): return urls
        }
    }
}

struct LoadedDetail {
    var note: String?
    var rows: [DetailRow] = []
    /// Versión legible del informe (p. ej. el volcado de spindump descifrado).
    var readableFile: URL?
}

// MARK: - Lectura de informes

enum DetailLoader {
    private static var cache: [LazyDetail: LoadedDetail] = [:]
    private static let lock = NSLock()

    static func load(_ detail: LazyDetail) async -> LoadedDetail {
        if let cached = lock.withLock({ cache[detail] }) { return cached }
        let result = await Task.detached(priority: .userInitiated) { () -> LoadedDetail in
            switch detail {
            case .shutdownStall(let url): return shutdownStall(url)
            case .reports(let urls): return reports(urls)
            }
        }.value
        lock.withLock { cache[detail] = result }
        return result
    }

    // MARK: Apagado atascado

    /// El informe es un volcado binario de spindump; `spindump -i` lo convierte a texto (no requiere root).
    /// Lista los procesos que seguían vivos mientras launchd esperaba para apagar.
    private static func shutdownStall(_ url: URL) -> LoadedDetail {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".txt")
        if !FileManager.default.fileExists(atPath: out.path) {
            Shell.run("/usr/sbin/spindump", ["-i", url.path, "-o", out.path])
        }
        guard let text = try? String(contentsOf: out, encoding: .utf8) else {
            return LoadedDetail(note: "No se pudo descifrar el informe de apagado.")
        }

        struct Proc { let name: String; let pid: String; var path = "" }
        var procs: [Proc] = []
        var seen = Set<String>()
        var pending: Proc?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Process:") {
                let body = line.dropFirst("Process:".count).trimmingCharacters(in: .whitespaces)
                if let open = body.firstIndex(of: "["), let close = body[open...].firstIndex(of: "]") {
                    let pid = String(body[body.index(after: open)..<close])
                    let name = body[..<open].trimmingCharacters(in: .whitespaces)
                    pending = seen.contains(pid) ? nil : Proc(name: name, pid: pid)
                }
            } else if line.hasPrefix("Path:"), var p = pending {
                p.path = line.dropFirst("Path:".count).trimmingCharacters(in: .whitespaces)
                procs.append(p)
                seen.insert(p.pid)
                pending = nil
            }
        }

        let ignored: Set<String> = ["launchd", "kernel_task", "spindump"]
        let relevant = procs.filter { !ignored.contains($0.name) && !$0.path.contains(".dext/") }
        let isSystem = { (path: String) in ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/Library/Developer/"].contains { path.hasPrefix($0) } }
        let thirdParty = relevant.filter { !isSystem($0.path) }
        let system = relevant.filter { isSystem($0.path) }

        // Un mismo servicio puede tener varias instancias (p. ej. DeviceFS ×2).
        func unique(_ list: [Proc], value: String, emphasized: Bool) -> [DetailRow] {
            var counts: [(String, Int)] = []
            for p in list {
                let name = friendlyName(p.name, path: p.path)
                if let i = counts.firstIndex(where: { $0.0 == name }) { counts[i].1 += 1 } else { counts.append((name, 1)) }
            }
            return counts.map { DetailRow(title: $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0, value: value, emphasized: emphasized) }
        }
        var rows = unique(thirdParty, value: "De terceros · probable causa", emphasized: true)
        rows += unique(system, value: "Sistema", emphasized: false)

        var note = "Procesos que seguían activos mientras macOS esperaba para apagar."
        if !thirdParty.isEmpty {
            note += " Los de terceros son los sospechosos habituales: ciérralos antes de apagar o actualízalos si se repite."
        }
        if relevant.contains(where: { $0.path.contains("fskit.exfat") || $0.path.contains("fskit.msdos") }) {
            note += " Había un disco externo montado: expúlsalo antes de apagar."
        }
        if relevant.isEmpty { note = "El informe no muestra procesos pendientes aparte del sistema." }
        return LoadedDetail(note: note, rows: rows, readableFile: out)
    }

    private static func friendlyName(_ name: String, path: String) -> String {
        if path.contains("fskit.exfat") { return "Disco externo exFAT (\(name))" }
        if path.contains("fskit.msdos") { return "Disco externo FAT (\(name))" }
        let known = [
            "DeviceFS": "Dispositivos de Xcode (DeviceFS)",
            "diskarbitrationd": "Gestión de discos (diskarbitrationd)",
            "akd": "Cuenta de Apple (akd)",
            "duetexpertd": "Sugerencias de Siri (duetexpertd)",
            "backupd": "Time Machine (backupd)",
        ]
        if let label = known[name] { return label }
        // Nombre del bundle más interno (.app, .appex o extensión del sistema).
        let components = path.components(separatedBy: "/")
        if let idx = components.lastIndex(where: { $0.hasSuffix(".app") || $0.hasSuffix(".appex") || $0.hasSuffix(".systemextension") }) {
            let bundle = components[...idx].joined(separator: "/")
            if let bundleName = BundleInfo.displayName(bundle), bundleName != name {
                return "\(bundleName) (\(name))"
            }
        }
        return name
    }

    // MARK: Cierres, cuelgues, CPU, Jetsam y pánicos

    private static func reports(_ urls: [URL]) -> LoadedDetail {
        var rows: [DetailRow] = []
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let sorted = urls.sorted { modified($0) > modified($1) }
        for url in sorted.prefix(40) {
            let name = url.lastPathComponent
            if name.hasSuffix(".cpu_resource.diag") { rows += cpuResource(url) }
            else if name.hasSuffix(".hang") || name.hasSuffix(".spin") { rows += hang(url) }
            else if name.hasSuffix(".ips") || name.hasSuffix(".panic") { rows += ips(url) }
            else { rows.append(DetailRow(title: name)) }
        }
        let note = urls.count > 40 ? "Se analizan los 40 informes más recientes de \(urls.count)." : nil
        return LoadedDetail(note: note, rows: collapse(rows))
    }

    /// Ordena por fecha (más reciente primero) y agrupa los fallos idénticos repetidos:
    /// "04:34–04:35 · MiApp ×15".
    private static func collapse(_ rows: [DetailRow]) -> [DetailRow] {
        struct Group { var row: DetailRow; var name: String; var first: String; var last: String; var count: Int }
        var groups: [Group] = []
        for row in rows {
            let parts = row.title.components(separatedBy: " · ")
            let time = parts.count > 1 ? parts[0] : ""
            let name = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : row.title
            if let i = groups.firstIndex(where: { $0.name == name && $0.row.value == row.value && $0.row.emphasized == row.emphasized }) {
                groups[i].count += 1
                groups[i].first = min(groups[i].first, time)
                groups[i].last = max(groups[i].last, time)
            } else {
                groups.append(Group(row: row, name: name, first: time, last: time, count: 1))
            }
        }
        return groups
            .enumerated()
            .sorted { ($0.element.last, -$0.offset) > ($1.element.last, -$1.offset) }
            .map { _, g in
                var row = g.row
                guard g.count > 1 else { return row }
                let range = g.first == g.last ? g.last : "\(g.first) – \(g.last.suffix(5))"
                row.title = "\(range) · \(g.name) ×\(g.count)"
                return row
            }
    }

    private static let timeFormat: Date.FormatStyle = .dateTime.day().month(.abbreviated).hour().minute()

    private static func headerLines(_ url: URL, keys: [String]) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 16_384) else { return [:] }
        try? handle.close()
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            for key in keys where out[key] == nil && line.hasPrefix(key + ":") {
                out[key] = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    private static func cpuResource(_ url: URL) -> [DetailRow] {
        let h = headerLines(url, keys: ["Command", "CPU", "Date/Time", "Duration"])
        let when = h["Date/Time"].map { String($0.prefix(16)) } ?? ""
        return [DetailRow(title: "\(when) · \(h["Command"] ?? url.lastPathComponent)",
                          value: h["CPU"].map(translateCPU) ?? "Consumo excesivo de CPU")]
    }

    /// "90 seconds cpu time over 94 seconds (96% cpu average), exceeding limit of 50% cpu over 180 seconds"
    /// → "96 % de CPU de media durante 94 s (límite: 50 % durante 180 s)"
    private static func translateCPU(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"over (\d+) seconds \((\d+)% cpu average\), exceeding limit of (\d+)% cpu over (\d+) seconds"#)
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return "Consumo excesivo: \(text)" }
        let g = (1...4).map { ns.substring(with: m.range(at: $0)) }
        return "\(g[1]) % de CPU de media durante \(g[0]) s (límite: \(g[2]) % durante \(g[3]) s)"
    }

    private static func hang(_ url: URL) -> [DetailRow] {
        let h = headerLines(url, keys: ["Command", "Process", "Duration", "Date/Time"])
        let when = h["Date/Time"].map { String($0.prefix(16)) } ?? ""
        return [DetailRow(title: "\(when) · \(h["Command"] ?? h["Process"] ?? url.lastPathComponent)",
                          value: "Sin responder durante \(h["Duration"] ?? "un tiempo")")]
    }

    private static func ips(_ url: URL) -> [DetailRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let parts = text.split(separator: "\n", maxSplits: 1)
        guard let headerData = parts.first.map({ Data($0.utf8) }),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { return [] }
        let body = parts.count > 1 ? (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]) ?? [:] : [:]
        let when = (header["timestamp"] as? String).map { String($0.prefix(16)) } ?? ""
        let app = (header["app_name"] as? String) ?? (header["name"] as? String) ?? url.lastPathComponent

        switch header["bug_type"] as? String {
        case "298":   // Jetsam: procesos cerrados por falta de memoria
            let processes = body["processes"] as? [[String: Any]] ?? []
            var rows: [DetailRow] = []
            if let largest = body["largestProcess"] as? String {
                rows.append(DetailRow(title: "\(when) · \(largest)", value: "El proceso que más memoria usaba", emphasized: true))
            }
            for p in processes where p["reason"] != nil {
                let name = p["name"] as? String ?? "?"
                rows.append(DetailRow(title: "\(when) · \(name)", value: "Cerrado: \(jetsamReason(p["reason"] as? String))"))
            }
            return rows
        case "210":   // Kernel panic
            let panic = (body["panicString"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? "Kernel panic"
            return [DetailRow(title: when, value: String(panic.prefix(200)), emphasized: true)]
        default:      // Cierre inesperado
            let exc = body["exception"] as? [String: Any] ?? [:]
            var what = [exc["type"] as? String, (exc["signal"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if let msg = exc["message"] as? String { what += " · \(msg)" }
            if let term = body["termination"] as? [String: Any], let indicator = term["indicator"] as? String, what.isEmpty {
                what = indicator
            }
            if let frame = crashingFrame(body, process: body["procName"] as? String ?? app) { what += " · en \(frame)" }
            return [DetailRow(title: "\(when) · \(app)", value: what.isEmpty ? "Cierre inesperado" : what)]
        }
    }

    /// Primera función del propio programa en el hilo que falló.
    private static func crashingFrame(_ body: [String: Any], process: String) -> String? {
        guard let threads = body["threads"] as? [[String: Any]], let images = body["usedImages"] as? [[String: Any]] else { return nil }
        let index = body["faultingThread"] as? Int ?? 0
        guard threads.indices.contains(index), let frames = threads[index]["frames"] as? [[String: Any]] else { return nil }
        for frame in frames {
            guard let img = frame["imageIndex"] as? Int, images.indices.contains(img),
                  images[img]["name"] as? String == process, let symbol = frame["symbol"] as? String else { continue }
            return symbol
        }
        return nil
    }

    private static func jetsamReason(_ reason: String?) -> String {
        switch reason {
        case "per-process-limit": return "superó su límite de memoria"
        case "vm-pageshortage": return "faltaba memoria en el sistema"
        case "vnode-limit": return "demasiados archivos abiertos"
        case "highwater": return "superó su umbral de memoria"
        case "idle-exit": return "estaba inactivo"
        case "fc-thrashing": return "saturación de la caché de archivos"
        case "zone-map-exhaustion": return "memoria del kernel agotada"
        case "vm-compressor-space-shortage", "vm-compressor-thrashing": return "compresor de memoria saturado"
        case let r?: return r
        case nil: return "motivo desconocido"
        }
    }
}
