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

/// Geometric contacts, independent of charge or the eventual stopping distance.
/// The cue path contains the incoming leg and, when present, one outgoing leg.
/// The object path begins at the contacted object's centre.
public struct AimGuide: Equatable, Sendable {
    public let cuePath: [Vector]
    public let objectPath: [Vector]
    public let collisionCenter: Vector?
    public let targetBallID: Int?

    public init(cuePath: [Vector], objectPath: [Vector] = [], collisionCenter: Vector? = nil,
                targetBallID: Int? = nil) {
        self.cuePath = cuePath; self.objectPath = objectPath
        self.collisionCenter = collisionCenter; self.targetBallID = targetBallID
    }
}

/// Coordinates are logical points, with (0, 0) at the lower left of the felt.
/// The model has no file, desktop, rendering, or network access.
public final class BilliardsGame {
    public let width = 1000.0
    public let height = 500.0
    /// A visible hole fits the largest physical ball with a 20% radius margin.
    /// Cached from rack geometry so pocket size remains stable after balls sink.
    public var pocketRadius: Double { maximumRackRadius * 1.20 }
    public var balls: [Ball] = []
    public private(set) var shots = 0
    public private(set) var elapsed = 0.0
    public private(set) var needsCuePlacement = false
    private var started = false
    private var maximumRackRadius = 22.0

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
        // Same logical dimensions as Windows: icons keep their collision circle
        // slightly larger than artwork, and the cue stays smaller on sparse racks.
        let pitch = min(94, width * 0.45 / (Double(columns) + 0.5), height * 0.79 / Double(columns))
        let radius = pitch * 0.46
        let cueRadius = min(25, radius * 0.9)
        maximumRackRadius = max(radius, cueRadius)
        balls = [Ball(id: 0, position: Vector(width * 0.20, height / 2), radius: cueRadius, isCue: true)]
        var remaining = count
        for column in 0..<columns {
            let depth = min(column + 1, remaining)
            for row in 0..<depth {
                balls.append(Ball(id: balls.count,
                                  position: Vector(width * 0.52 + Double(column) * pitch * 0.84,
                                                   height / 2 + (Double(row) - Double(column) / 2) * pitch * 0.95),
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

    /// Match Windows' incoming/white/target guide: first contact and one
    /// subsequent contact, with the same collision circles and open pocket mouths.
    public func aimGuide(toward point: Vector) -> AimGuide {
        guard point.isFinite, !isMoving, !isComplete, !needsCuePlacement,
              let cueIndex = balls.firstIndex(where: { $0.isCue && !$0.pocketed }) else {
            return AimGuide(cuePath: [])
        }
        let cue = balls[cueIndex]
        let incoming = point - cue.position
        guard incoming.isFinite, incoming.length.isFinite, incoming.length > 0.001 else { return AimGuide(cuePath: []) }
        let direction = incoming * (1 / incoming.length)
        let hit = trace(origin: cue.position, direction: direction, radius: cue.radius, excluding: [cueIndex])
        var cuePath = [cue.position, hit.point]
        switch hit.kind {
        case .pocket:
            return AimGuide(cuePath: cuePath)
        case .rail(let reflectX, let reflectY):
            let rebound = Vector(reflectX ? -direction.x * 0.88 : direction.x,
                                 reflectY ? -direction.y * 0.88 : direction.y)
            if rebound.length > 0.000001 {
                cuePath.append(trace(origin: hit.point, direction: rebound * (1 / rebound.length),
                                     radius: cue.radius, excluding: [cueIndex]).point)
            }
            return AimGuide(cuePath: cuePath, collisionCenter: hit.point)
        case .ball(let index):
            let target = balls[index]
            let separation = target.position - hit.point
            guard separation.length > 0.000001 else { return AimGuide(cuePath: cuePath) }
            let normal = separation * (1 / separation.length)
            let impulse = normal * (direction.dot(normal) * 0.96)
            let whiteMotion = direction - impulse
            let excluded: Set<Int> = [cueIndex, index]
            if whiteMotion.length > 0.000001 {
                cuePath.append(trace(origin: hit.point, direction: whiteMotion * (1 / whiteMotion.length),
                                     radius: cue.radius, excluding: excluded).point)
            }
            let objectEnd = trace(origin: target.position, direction: impulse * (1 / impulse.length),
                                  radius: target.radius, excluding: excluded).point
            return AimGuide(cuePath: cuePath, objectPath: [target.position, objectEnd],
                            collisionCenter: hit.point, targetBallID: target.id)
        }
    }

    @discardableResult
    public func shoot(toward point: Vector, power: Double) -> Bool {
        guard !isMoving, !isComplete, !needsCuePlacement, point.isFinite, power.isFinite,
              let cue = balls.firstIndex(where: { $0.isCue && !$0.pocketed }) else { return false }
        let direction = point - balls[cue].position
        guard direction.isFinite, direction.length.isFinite, direction.length > 0.001 else { return false }
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

    /// The active round clock uses the full monotonic frame delta, while
    /// simulation catch-up is bounded just as on Windows. App-level pause must
    /// omit calls while hidden/asleep; slow rendering must not shorten a score.
    /// Substeps keep a full-power shot below a fraction of one radius per step.
    public func step(_ frameDelta: Double) {
        guard frameDelta.isFinite, frameDelta > 0, !isComplete else { return }
        let dt = min(frameDelta, 0.05)
        if started { elapsed += frameDelta }
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
            let speed = balls[index].velocity.length
            if speed > 0 {
                let direction = balls[index].velocity * (1 / speed)
                let boundary = boundaryEvent(origin: balls[index].position, direction: direction, radius: balls[index].radius)
                if case .pocket = boundary.kind, boundary.distance <= speed * dt {
                    balls[index].position = boundary.point
                    balls[index].pocketed = true
                    balls[index].velocity = .zero
                    if balls[index].isCue { needsCuePlacement = true }
                    continue
                }
            }
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
            if nextSpeed < height * 0.008 {
                balls[index].velocity = .zero
                // An open-mouth approach may temporarily cross the inset rail.
                // Once friction stops it before capture, finish inside the legal
                // centre rectangle even if this was the frame's final substep.
                reflect(index)
            } else {
                balls[index].velocity = balls[index].velocity * (nextSpeed / speed)
            }
        }
    }

    @discardableResult
    private func capture(_ index: Int) -> Bool {
        let ball = balls[index]
        let captureRadius = captureRadius(for: ball.radius)
        if pockets.contains(where: { (ball.position - $0).length <= captureRadius }) {
            balls[index].pocketed = true; balls[index].velocity = .zero
            if ball.isCue { needsCuePlacement = true }
            return true
        }
        return false
    }

    private func reflect(_ index: Int) {
        let speed = balls[index].velocity.length
        if speed > 0 {
            let boundary = boundaryEvent(origin: balls[index].position,
                                         direction: balls[index].velocity * (1 / speed), radius: balls[index].radius)
            // Corner mouths are open, as in the Windows boundary model. A
            // trajectory through the visible hole must not rebound prematurely
            // at the inset ball-centre rectangle on its way into that hole.
            if case .pocket = boundary.kind { return }
        }
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

    /// Capture begins once the ball centre is visibly inside the hole. The
    /// same circle is used by direct capture, swept motion, and aim prediction.
    private func captureRadius(for radius: Double) -> Double {
        max(1, pocketRadius - radius * 0.15)
    }

    private enum ContactKind {
        case rail(reflectX: Bool, reflectY: Bool)
        case pocket
        case ball(Int)
    }
    private struct RayContact {
        let distance: Double
        let point: Vector
        let kind: ContactKind
    }

    private func trace(origin: Vector, direction: Vector, radius: Double, excluding: Set<Int>) -> RayContact {
        var hit = boundaryEvent(origin: origin, direction: direction, radius: radius)
        for index in balls.indices where !balls[index].pocketed && !excluding.contains(index) {
            if let distance = rayCircle(origin: origin, direction: direction, center: balls[index].position,
                                        radius: radius + balls[index].radius), distance < hit.distance {
                hit = RayContact(distance: distance, point: origin + direction * distance, kind: .ball(index))
            }
        }
        return hit
    }

    private func boundaryEvent(origin: Vector, direction: Vector, radius: Double) -> RayContact {
        let railX = abs(direction.x) > 0.000001
            ? ((direction.x > 0 ? width - radius : radius) - origin.x) / direction.x : Double.infinity
        let railY = abs(direction.y) > 0.000001
            ? ((direction.y > 0 ? height - radius : radius) - origin.y) / direction.y : Double.infinity
        let rail = max(0, min(railX, railY))
        var distance = rail
        var kind = ContactKind.rail(reflectX: railX <= rail + 0.000001, reflectY: railY <= rail + 0.000001)
        let edgeX = abs(direction.x) > 0.000001
            ? ((direction.x > 0 ? width : 0) - origin.x) / direction.x : Double.infinity
        let edgeY = abs(direction.y) > 0.000001
            ? ((direction.y > 0 ? height : 0) - origin.y) / direction.y : Double.infinity
        let edge = min(edgeX, edgeY)
        for pocket in pockets {
            guard let entry = rayCircle(origin: origin, direction: direction, center: pocket,
                                        radius: captureRadius(for: radius)) else { continue }
            let cornerMouth = (pocket.x == 0 || pocket.x == width) && edge.isFinite && edge >= 0
                && (origin + direction * edge - pocket).length <= pocketRadius
            if entry <= distance || (cornerMouth && { if case .rail = kind { return true }; return false }()) {
                distance = entry
                kind = .pocket
            }
        }
        return RayContact(distance: distance, point: origin + direction * distance, kind: kind)
    }

    private func rayCircle(origin: Vector, direction: Vector, center: Vector, radius: Double) -> Double? {
        let offset = center - origin
        let forward = offset.dot(direction)
        let across = offset.x * direction.y - offset.y * direction.x
        let clearance = radius * radius - across * across
        guard forward > 0, clearance > 0 else { return nil }
        return max(0, forward - sqrt(clearance))
    }
}
