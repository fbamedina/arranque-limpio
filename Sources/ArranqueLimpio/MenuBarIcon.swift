import AppKit

/// Icono de la barra de menús: el mismo símbolo que el de la app (botón de encendido con distintivo).
/// Sin incidencias de consumo es una plantilla monocroma (se adapta a la barra clara/oscura);
/// al superar los umbrales de Ajustes se colorea en naranja o, si se duplican, en rojo.
enum MenuBarIcon {
    enum Badge: String { case none, check, busy, alert, paused }

    private static var cache: [String: NSImage] = [:]

    static func image(resourceLevel: Severity, badge: Badge) -> NSImage {
        let color: NSColor? = switch resourceLevel {
        case .critical: .systemRed
        case .warning: .systemOrange
        default: nil
        }
        let key = "\(resourceLevel.rawValue)-\(badge.rawValue)"
        if let cached = cache[key] { return cached }

        let ink = color ?? .black
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // En pausa, el símbolo se atenúa.
            draw("power", pointSize: 13.5, weight: .semibold, color: badge == .paused ? ink.withAlphaComponent(0.45) : ink,
                 center: NSPoint(x: 9, y: 9.5), operation: .sourceOver)
            let glyph: String? = switch badge {
            case .check: "checkmark"
            case .busy: "clock"
            case .alert: "exclamationmark"
            case .paused: "pause.fill"
            case .none: nil
            }
            if let glyph {
                let center = NSPoint(x: 15, y: 5)
                let disc = { (r: CGFloat) in NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)) }
                // Hueco alrededor del distintivo, disco y signo recortado dentro del disco.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                disc(6).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                ink.setFill()
                disc(4.8).fill()
                draw(glyph, pointSize: 6.5, weight: .black, color: .black, center: center, operation: .destinationOut)
            }
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Arranque Limpio"
        cache[key] = image
        return image
    }

    private static func draw(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor,
                             center: NSPoint, operation: NSCompositingOperation) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        symbol.draw(in: NSRect(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height),
                    from: .zero, operation: operation, fraction: 1)
    }
}
