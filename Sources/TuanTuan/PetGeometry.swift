import Foundation
import CoreGraphics

/// Phase-one desktop geometry. No network, background polling, or persistent memory.
enum PetGeometry {
    static let minimumSize: CGFloat = 100
    static let maximumSize: CGFloat = 220
    static let defaultSize: CGFloat = 160

    static func boundedSize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultSize }
        return min(maximumSize, max(minimumSize, value))
    }

    static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func recovered(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        let intersecting = screens.max { first, second in
            area(frame.intersection(first)) < area(frame.intersection(second))
        }!
        let destination: CGRect
        if area(frame.intersection(intersecting)) > 0 {
            destination = intersecting
        } else {
            destination = screens.min {
                distanceSquared(frame.center, $0.center) < distanceSquared(frame.center, $1.center)
            }!
        }
        return clamped(frame, to: destination)
    }

    static func initialFrame(size: CGFloat, screen: CGRect) -> CGRect {
        let edge = boundedSize(size)
        return clamped(CGRect(x: screen.maxX - edge - 32,
                              y: screen.minY + 24,
                              width: edge, height: edge), to: screen)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isInfinite ? 0 : max(0, rect.width) * max(0, rect.height)
    }

    private static func distanceSquared(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        pow(first.x - second.x, 2) + pow(first.y - second.y, 2)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

struct PetDragGesture {
    private let pointerStart: CGPoint
    private let originStart: CGPoint
    private(set) var hasDragged = false

    init(pointer: CGPoint, origin: CGPoint) {
        pointerStart = pointer
        originStart = origin
    }

    mutating func moved(to pointer: CGPoint) -> CGPoint {
        let dx = pointer.x - pointerStart.x
        let dy = pointer.y - pointerStart.y
        if dx * dx + dy * dy >= 16 { hasDragged = true }
        return CGPoint(x: originStart.x + dx, y: originStart.y + dy)
    }
}

struct AlphaMask {
    let width: Int
    let height: Int
    let pixels: Data

    init?(width: Int, height: Int, pixels: Data) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Mask rows use the PNG's top-to-bottom order, matching the flipped pet view.
    func contains(_ point: CGPoint, in imageRect: CGRect, threshold: UInt8 = 32) -> Bool {
        guard imageRect.width > 0, imageRect.height > 0,
              point.x >= imageRect.minX, point.y >= imageRect.minY,
              point.x < imageRect.maxX, point.y < imageRect.maxY else { return false }
        let x = min(width - 1, Int((point.x - imageRect.minX) / imageRect.width * CGFloat(width)))
        let y = min(height - 1, Int((point.y - imageRect.minY) / imageRect.height * CGFloat(height)))
        return pixels[y * width + x] >= threshold
    }
}

/// Local pointer interaction, unrelated to the companion/work-agent intent router.
enum PetTouchZone: String, CaseIterable, Sendable {
    case head, cheek, belly, tail

    var title: String {
        switch self {
        case .head: "头顶"
        case .cheek: "脸颊"
        case .belly: "肚子"
        case .tail: "尾巴"
        }
    }

    var response: String {
        switch self {
        case .head: "嗯，头顶这里好舒服。"
        case .cheek: "蹭蹭你的手。"
        case .belly: "软软的肚子，轻轻摸。"
        case .tail: "尾巴摇一摇。"
        }
    }

    var animationKey: String { "touch-\(rawValue)" }
}

enum PetTouchLayout {
    static func normalized(_ point: CGPoint, in imageRect: CGRect) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0,
              point.x >= imageRect.minX, point.x < imageRect.maxX,
              point.y >= imageRect.minY, point.y < imageRect.maxY else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width,
                       y: (point.y - imageRect.minY) / imageRect.height)
    }

    /// Call only after alpha hit-testing. Transparent pixels never count as petting.
    static func zone(at point: CGPoint, in imageRect: CGRect) -> PetTouchZone? {
        guard let point = normalized(point, in: imageRect) else { return nil }
        if point.x >= 0.755 && point.y >= 0.57 { return .tail }
        if point.y < 0.335 { return .head }
        if point.y < 0.625 { return .cheek }
        return .belly
    }

    static func samplePoint(for zone: PetTouchZone, in rect: CGRect) -> CGPoint {
        let point: CGPoint = switch zone {
        case .head: CGPoint(x: 0.40, y: 0.20)
        case .cheek: CGPoint(x: 0.25, y: 0.46)
        case .belly: CGPoint(x: 0.43, y: 0.80)
        case .tail: CGPoint(x: 0.88, y: 0.76)
        }
        return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}
