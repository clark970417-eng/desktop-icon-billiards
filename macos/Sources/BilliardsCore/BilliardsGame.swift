// Inspired by the MIT-licensed physics and rules in dib/table.py, by LXG.
import Foundation

public struct Vector: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vector(0, 0)
    public var length: Double { hypot(x, y) }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public static func + (lhs: Vector, rhs: Vector) -> Vector { Vector(lhs.x + rhs.x, lhs.y + rhs.y) }
    public static func - (lhs: Vector, rhs: Vector) -> Vector { Vector(lhs.x - rhs.x, lhs.y - rhs.y) }
    public static func * (lhs: Vector, rhs: Double) -> Vector { Vector(lhs.x * rhs, lhs.y * rhs) }
    public func dot(_ other: Vector) -> Double { x * other.x + y * other.y }
}

public struct Ball: Equatable, Sendable {
    public var id: Int
    public var position: Vector
    public var velocity: Vector
    public var radius: Double
    public var pocketed: Bool
    public var isCue: Bool

    public init(id: Int, position: Vector, velocity: Vector = .zero,
                radius: Double = 22, pocketed: Bool = false, isCue: Bool = false) {
        self.id = id; self.position = position; self.velocity = velocity
        self.radius = radius; self.pocketed = pocketed; self.isCue = isCue
    }
}

/// Coordinates are logical points, with (0, 0) at the lower left of the felt.
/// The model has no file, desktop, rendering, or network access.
public final class BilliardsGame {
    public let width = 1000.0
    public let height = 500.0
    public let pocketRadius = 28.0
    public var balls: [Ball] = []
    public private(set) var shots = 0
    public private(set) var elapsed = 0.0
    public private(set) var needsCuePlacement = false
    private var started = false

    public var pockets: [Vector] {
        [Vector(0, 0), Vector(width / 2, 0), Vector(width, 0),
         Vector(0, height), Vector(width / 2, height), Vector(width, height)]
    }
    public var iconCount: Int { balls.filter { !$0.isCue }.count }
    public var pocketedCount: Int { balls.filter { !$0.isCue && $0.pocketed }.count }
    public var isComplete: Bool { iconCount > 0 && pocketedCount == iconCount }
    public var isMoving: Bool { balls.contains { !$0.pocketed && $0.velocity.length > 0 } }

    public init(iconCount: Int = 15) { reset(iconCount: iconCount) }

    public func reset(iconCount: Int? = nil) {
        let count = max(1, min(45, iconCount ?? max(1, self.iconCount)))
        let columns = Int(ceil((sqrt(Double(8 * count + 1)) - 1) / 2))
        let radius = min(22.0, 180.0 / Double(columns + 1))
        let spacing = radius * 2 + 3
        balls = [Ball(id: 0, position: Vector(width * 0.23, height / 2), radius: radius, isCue: true)]
        var remaining = count
        for column in 0..<columns {
            let depth = min(column + 1, remaining)
            for row in 0..<depth {
                balls.append(Ball(id: balls.count,
                                  position: Vector(width * 0.56 + Double(column) * spacing * 0.88,
                                                   height / 2 + (Double(row) - Double(column) / 2) * spacing),
                                  radius: radius))
            }
            remaining -= depth
        }
        shots = 0; elapsed = 0; started = false; needsCuePlacement = false
    }

    public static func chargePower(seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let phase = max(0, seconds).truncatingRemainder(dividingBy: 3) / 1.5
        return phase <= 1 ? phase : 2 - phase
    }

    @discardableResult
    public func shoot(toward point: Vector, power: Double) -> Bool {
        guard !isMoving, !isComplete, !needsCuePlacement, point.isFinite, power.isFinite,
              let cue = balls.firstIndex(where: { $0.isCue && !$0.pocketed }) else { return false }
        let direction = point - balls[cue].position
        guard direction.length > 0.001 else { return false }
        let clampedPower = max(0, min(1, power))
        let speed = height * (0.12 + 3.05 * clampedPower) * 1.58
        balls[cue].velocity = direction * (speed / direction.length)
        shots += 1; started = true
        return true
    }

    @discardableResult
    public func placeCue(at point: Vector) -> Bool {
        guard !isMoving, !isComplete, point.isFinite,
              let cue = balls.firstIndex(where: { $0.isCue && $0.pocketed }),
              isClear(point, radius: balls[cue].radius) else { return false }
        balls[cue].position = point; balls[cue].velocity = .zero; balls[cue].pocketed = false
        needsCuePlacement = false
        return true
    }

    /// Clamp long frame gaps after sleep/window dragging; use substeps so the
    /// fastest permitted shot travels less than a fraction of a radius at once.
    public func step(_ frameDelta: Double) {
        guard frameDelta.isFinite, frameDelta > 0, !isComplete else { return }
        let dt = min(frameDelta, 0.05)
        if started { elapsed += dt }
        let active = balls.filter { !$0.pocketed }
        let speed = active.map { $0.velocity.length }.max() ?? 0
        if speed > 0 {
            let radius = active.map(\.radius).min() ?? 20
            let substeps = max(1, Int(ceil(dt * max(240, speed / max(1, radius * 0.3)))))
            let h = dt / Double(substeps)
            for _ in 0..<substeps {
                advance(h)
                if isComplete {
                    for index in balls.indices { balls[index].velocity = .zero }
                    needsCuePlacement = false
                    break
                }
            }
        }
        if !isMoving, !isComplete, balls.contains(where: { $0.isCue && $0.pocketed }) {
            needsCuePlacement = true
            for x in [0.23, 0.35, 0.45, 0.6, 0.75, 0.85] {
                for y in [0.5, 0.3, 0.7, 0.15, 0.85] {
                    if placeCue(at: Vector(width * x, height * y)) { return }
                }
            }
        }
    }

    private func advance(_ dt: Double) {
        for index in balls.indices where !balls[index].pocketed {
            balls[index].position = balls[index].position + balls[index].velocity * dt
            if capture(index) { continue }
            reflect(index)
        }
        if balls.count > 1 {
            for a in 0..<(balls.count - 1) where !balls[a].pocketed {
                for b in (a + 1)..<balls.count where !balls[b].pocketed {
                    collide(a, b)
                }
            }
        }
        for index in balls.indices where !balls[index].pocketed {
            if capture(index) { continue }
            reflect(index)
            let speed = balls[index].velocity.length
            let nextSpeed = max(0, speed - height * 0.45 * dt)
            balls[index].velocity = nextSpeed < 3 ? .zero : balls[index].velocity * (nextSpeed / speed)
        }
    }

    @discardableResult
    private func capture(_ index: Int) -> Bool {
        let ball = balls[index]
        let captureRadius = pocketRadius + ball.radius * 0.55
        if pockets.contains(where: { (ball.position - $0).length <= captureRadius }) {
            balls[index].pocketed = true; balls[index].velocity = .zero
            if ball.isCue { needsCuePlacement = true }
            return true
        }
        return false
    }

    private func reflect(_ index: Int) {
        let radius = balls[index].radius
        if balls[index].position.x < radius {
            balls[index].position.x = radius
            if balls[index].velocity.x < 0 { balls[index].velocity.x *= -0.88 }
        }
        if balls[index].position.x > width - radius {
            balls[index].position.x = width - radius
            if balls[index].velocity.x > 0 { balls[index].velocity.x *= -0.88 }
        }
        if balls[index].position.y < radius {
            balls[index].position.y = radius
            if balls[index].velocity.y < 0 { balls[index].velocity.y *= -0.88 }
        }
        if balls[index].position.y > height - radius {
            balls[index].position.y = height - radius
            if balls[index].velocity.y > 0 { balls[index].velocity.y *= -0.88 }
        }
    }

    private func collide(_ a: Int, _ b: Int) {
        let offset = balls[b].position - balls[a].position
        let distance = offset.length
        let diameter = balls[a].radius + balls[b].radius
        guard distance < diameter else { return }
        let normal = distance > 0.00001 ? offset * (1 / distance) : Vector(1, 0)
        let correction = normal * ((diameter - distance) / 2 + 0.00001)
        balls[a].position = balls[a].position - correction
        balls[b].position = balls[b].position + correction
        let closing = (balls[b].velocity - balls[a].velocity).dot(normal)
        guard closing < 0 else { return }
        let impulse = normal * (-closing * 0.96)
        balls[a].velocity = balls[a].velocity - impulse
        balls[b].velocity = balls[b].velocity + impulse
    }

    private func isClear(_ point: Vector, radius: Double) -> Bool {
        guard point.x >= radius, point.x <= width - radius,
              point.y >= radius, point.y <= height - radius,
              !pockets.contains(where: { (point - $0).length <= pocketRadius + radius }) else { return false }
        return !balls.contains { !$0.pocketed && !$0.isCue && (point - $0.position).length < radius + $0.radius + 2 }
    }
}
