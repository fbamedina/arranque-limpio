import AppKit
import SwiftUI

/// Un aviso: título y resumen, acción opcional, botón para omitirlo y detalles desplegables.
struct IssueRow: View {
    let issue: Issue
    let color: Color
    let actionLabel: String?
    let expanded: Bool
    let onToggle: () -> Void
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded, let details = issue.details {
                IssueDetailsView(details: details)
                    .padding(.leading, 30)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.callout.weight(.medium))
                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if issue.details != nil {
                    Button(action: onToggle) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .font(.caption2.weight(.semibold))
                            Text(expanded ? "Ocultar detalles" : "Ver detalles")
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 4)
            if let actionLabel {
                Button(actionLabel, action: onAction).controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Omitir este aviso. Volverá a aparecer si el problema se repite.")
        }
    }
}

struct IssueDetailsView: View {
    let details: IssueDetails
    @State private var loaded: LoadedDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = details.note { noteText(note) }
            if details.lazy == nil, !details.rows.isEmpty { DetailRowsView(rows: details.rows) }

            // Primero lo que dicen los informes; después, el estado actual de los procesos.
            if let lazy = details.lazy {
                if let loaded {
                    if let note = loaded.note { noteText(note) }
                    if !loaded.rows.isEmpty { DetailRowsView(rows: loaded.rows) }
                    actions(files: lazy.files, readable: loaded.readableFile)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analizando informe…").font(.caption).foregroundStyle(.secondary)
                    }
                    .task(id: lazy) { loaded = await DetailLoader.load(lazy) }
                }
                if !details.rows.isEmpty {
                    Text("AHORA MISMO").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
                    DetailRowsView(rows: details.rows)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func noteText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func actions(files: [URL], readable: URL?) -> some View {
        HStack(spacing: 12) {
            if let readable {
                Button("Ver informe completo") { NSWorkspace.shared.open(readable) }
            } else if let first = files.first {
                Button(files.count == 1 ? "Abrir en Consola" : "Abrir el último en Consola") {
                    NSWorkspace.shared.open([first], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Button(files.count == 1 ? "Mostrar en Finder" : "Mostrar \(files.count) informes en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}

struct DetailRowsView: View {
    let rows: [DetailRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(row.emphasized ? Color.orange : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.caption.weight(row.emphasized ? .semibold : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                        if !row.value.isEmpty {
                            Text(row.value)
                                .font(.caption2)
                                .foregroundStyle(row.emphasized ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}
