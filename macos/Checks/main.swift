// Command Line Tools installations omit XCTest. This runner validates the
// shipped physics without requiring Xcode or downloading a test framework.
// swiftc Sources/BilliardsCore/BilliardsGame.swift Checks/main.swift -o .build/physics-checks
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}
func settle(_ game: BilliardsGame) {
    for _ in 0..<2_400 { game.step(1 / 120.0) }
}
var passed = 0
var failed = 0
func check(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(error)") }
}

check("charge cycles through 0–100–0 percent") {
    for (time, value) in [(0.0, 0.0), (0.75, 0.5), (1.5, 1.0), (2.25, 0.5), (3.0, 0.0)] {
        try expect(abs(BilliardsGame.chargePower(seconds: time) - value) < 0.00001, "wrong charge at \(time)")
    }
}
check("1–45 ball racks fit and reset exactly") {
    for count in 1...45 {
        let game = BilliardsGame(iconCount: count), original = BilliardsGame(iconCount: count).balls
        try expect(game.iconCount == count, "wrong count")
        for ball in game.balls {
            try expect(ball.position.x >= ball.radius && ball.position.x <= game.width - ball.radius, "rack outside x bounds")
            try expect(ball.position.y >= ball.radius && ball.position.y <= game.height - ball.radius, "rack outside y bounds")
            for other in game.balls where other.id != ball.id {
                try expect((ball.position - other.position).length >= ball.radius + other.radius, "overlapping rack")
            }
        }
        _ = game.shoot(toward: Vector(900, 250), power: 1); game.step(0.04); game.reset()
        try expect(game.balls == original && game.shots == 0 && game.elapsed == 0, "reset differs")
    }
}
check("full power break transfers motion and settles") {
    let game = BilliardsGame()
    try expect(game.shoot(toward: Vector(900, 250), power: 1), "shot rejected")
    try expect(!game.shoot(toward: Vector(900, 250), power: 1), "accepted shot during motion")
    var transferred = false
    for _ in 0..<100 {
        game.step(1 / 120)
        transferred = transferred || game.balls.contains { !$0.isCue && $0.velocity.length > 1 }
    }
    try expect(transferred, "break passed through rack")
    settle(game)
    try expect(!game.isMoving && game.shots == 1, "break never settled")
    for ball in game.balls where !ball.pocketed {
        try expect(ball.position.isFinite && ball.velocity.isFinite, "invalid ball state")
        try expect(ball.position.x >= ball.radius && ball.position.x <= game.width - ball.radius, "escaped rail")
    }
}
check("maximum speed shot cannot tunnel through target") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[1].position = Vector(500, 250)
    _ = game.shoot(toward: Vector(900, 250), power: 1)
    for _ in 0..<8 { game.step(1 / 30) }
    try expect(game.balls[1].position.x > 500 && abs(game.balls[1].velocity.y) < 0.001, "missed head-on collision")
}
check("all six pockets accept incoming icons") {
    for pocketIndex in 0..<6 {
        let game = BilliardsGame(iconCount: 1), pocket = game.pockets[pocketIndex]
        let inward = Vector(500, 250) - pocket, direction = inward * (1 / inward.length)
        game.balls[1].position = pocket + direction * 80
        game.balls[1].velocity = direction * -600
        for _ in 0..<50 { game.step(1 / 120) }
        try expect(game.isComplete && game.pocketedCount == 1, "pocket \(pocketIndex) rejected icon")
    }
}
check("scratch automatically respots into clear space") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(500, 65)
    _ = game.shoot(toward: Vector(500, 0), power: 0.3)
    settle(game)
    try expect(!game.balls[0].pocketed && !game.needsCuePlacement, "cue was not respotted")
    try expect((game.balls[0].position - game.balls[1].position).length > game.balls[0].radius + game.balls[1].radius, "respot overlaps")
}
check("manual placement rejects pockets and overlaps") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].pocketed = true
    try expect(!game.placeCue(at: Vector(0, 0)), "accepted pocket")
    try expect(!game.placeCue(at: game.balls[1].position), "accepted overlap")
    try expect(game.placeCue(at: Vector(250, 100)), "rejected clear placement")
}
check("crowded scratch waits for manual placement") {
    let game = BilliardsGame(iconCount: 1)
    game.balls = [Ball(id: 0, position: Vector(500, 0), pocketed: true, isCue: true)]
    for x in [0.23, 0.35, 0.45, 0.6, 0.75, 0.85] {
        for y in [0.5, 0.3, 0.7, 0.15, 0.85] {
            game.balls.append(Ball(id: game.balls.count, position: Vector(game.width * x, game.height * y)))
        }
    }
    game.step(1 / 60)
    try expect(game.needsCuePlacement, "crowded scratch did not request placement")
    try expect(!game.shoot(toward: Vector(900, 250), power: 1), "shot while cue absent")
    try expect(game.placeCue(at: Vector(80, 100)), "manual fallback failed")
}
check("rail reflection and drag stop the cue") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(100, 150); game.balls[0].velocity = Vector(-500, 0)
    for _ in 0..<40 { game.step(1 / 120) }
    try expect(game.balls[0].velocity.x > 0, "rail did not reflect")
    settle(game)
    try expect(!game.isMoving, "drag did not stop motion")
}
check("invalid numbers and rejected shots preserve state") {
    let game = BilliardsGame()
    game.step(0.05)
    try expect(game.elapsed == 0, "timer started before shot")
    try expect(!game.shoot(toward: game.balls[0].position, power: 1), "zero direction accepted")
    try expect(!game.shoot(toward: Vector(.nan, 0), power: 1), "NaN accepted")
    try expect(!game.shoot(toward: Vector(.greatestFiniteMagnitude, .greatestFiniteMagnitude), power: 1), "overflowing direction accepted")
    try expect(!game.shoot(toward: Vector(900, 250), power: .infinity), "infinity accepted")
    _ = game.shoot(toward: Vector(900, 250), power: 0.4); game.step(0.025)
    let balls = game.balls
    game.step(.nan); game.step(-1)
    try expect(game.balls == balls && abs(game.elapsed - 0.025) < 0.00001 && game.shots == 1, "invalid delta poisoned state")
}
check("separating balls do not gain collision energy") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(400, 250); game.balls[1].position = Vector(430, 250)
    game.balls[0].velocity = Vector(-100, 0); game.balls[1].velocity = Vector(100, 0)
    game.step(1 / 120)
    try expect(game.balls[0].velocity.x < 0 && game.balls[1].velocity.x > 0, "separating impulse reversed motion")
    try expect(game.balls.allSatisfy { $0.velocity.length < 100 }, "separating pair gained energy")
}
check("final pocket freezes timer and stops remaining balls") {
    let game = BilliardsGame(iconCount: 1)
    _ = game.shoot(toward: Vector(900, 250), power: 0.2); game.step(0.02)
    game.balls[1].position = Vector(500, 35); game.balls[1].velocity = Vector(0, -200)
    game.step(0.02)
    try expect(game.isComplete && !game.isMoving && game.elapsed > 0, "completion did not stop motion")
    let finished = game.elapsed
    game.step(0.05)
    try expect(game.elapsed == finished && !game.shoot(toward: Vector(900, 250), power: 1), "completion did not freeze state")
}
check("30 and 120 fps produce similar trajectories") {
    func run(_ fps: Double) -> BilliardsGame {
        let game = BilliardsGame(iconCount: 1)
        game.balls[1].position = Vector(850, 350)
        _ = game.shoot(toward: Vector(900, 250), power: 0.2)
        for _ in 0..<Int(fps * 2) { game.step(1 / fps) }
        return game
    }
    let slow = run(30), fast = run(120)
    try expect((slow.balls[0].position - fast.balls[0].position).length < 5, "trajectory depends on frame rate")
}

check("rack and cue retain Windows proportions while pockets fit the physical balls") {
    let sparse = BilliardsGame(iconCount: 15), dense = BilliardsGame(iconCount: 45)
    try expect(abs(sparse.balls[0].radius - 25) < 0.00001, "sparse cue radius differs")
    try expect(abs(sparse.balls[1].radius - 36.34) < 0.00001, "sparse icon radius differs")
    try expect(abs(sparse.balls[0].position.x - 200) < 0.00001 && abs(sparse.balls[1].position.x - 520) < 0.00001,
               "rack starts differ from Windows normalized table")
    try expect(abs(sparse.pocketRadius - sparse.balls[1].radius * 1.2) < 0.00001 && dense.balls[1].radius < sparse.balls[1].radius,
               "dense table does not scale its collision circles")
}
check("visible pockets fit every supported rack and remain stable during a round") {
    for count in 15...45 {
        let game = BilliardsGame(iconCount: count)
        let radius = game.pocketRadius
        try expect(game.balls.allSatisfy { radius + 0.000001 >= $0.radius * 1.2 }, "hole smaller than a physical ball")
        game.balls[1].pocketed = true
        try expect(game.pocketRadius == radius, "hole shrank after an icon sank")
    }
}
check("all rack sizes accept minimum and maximum speed through all six pockets") {
    for count in 15...45 {
        for speed in [94.8, 2504.3] {
            for pocketIndex in 0..<6 {
                let game = BilliardsGame(iconCount: count), pocket = game.pockets[pocketIndex]
                let inward = Vector(game.width / 2, game.height / 2) - pocket
                let unit = inward * (1 / inward.length)
                let startDistance = game.pocketRadius - game.balls[1].radius * 0.15 + 5
                game.balls[1].position = pocket + unit * startDistance
                game.balls[1].velocity = unit * -speed
                for _ in 0..<30 { game.step(1 / 120) }
                try expect(game.balls[1].pocketed, "a practical-speed shot bounced off a pocket mouth")
            }
        }
    }
}
check("image balls are not captured while their centres remain outside the visible hole") {
    for count in 15...45 {
        let game = BilliardsGame(iconCount: count)
        game.balls[1].position = Vector(game.width / 2, game.pocketRadius + 0.5)
        game.balls[1].velocity = Vector(0, 1)
        game.step(1 / 120)
        try expect(!game.balls[1].pocketed, "icon disappeared before its centre entered the visible hole")
        game.balls[1].position = Vector(game.width / 2, game.pocketRadius - game.balls[1].radius * 0.15 - 0.5)
        game.balls[1].velocity = Vector(0, -1)
        game.step(1 / 120)
        try expect(game.balls[1].pocketed, "icon centre entered the hole without capture")
    }
}
check("cue balls enter every pocket at minimum and maximum power and respot safely") {
    for count in 15...45 {
        for power in [0.0, 1.0] {
            for pocketIndex in 0..<6 {
                let game = BilliardsGame(iconCount: count), pocket = game.pockets[pocketIndex]
                let inward = Vector(game.width / 2, game.height / 2) - pocket
                let unit = inward * (1 / inward.length)
                let startDistance = game.pocketRadius - game.balls[0].radius * 0.15 + 5
                game.balls[0].position = pocket + unit * startDistance
                try expect(game.shoot(toward: pocket, power: power), "pocket test cue shot rejected")
                for _ in 0..<30 { game.step(1 / 120) }
                try expect(!game.balls[0].pocketed && !game.needsCuePlacement
                    && (game.balls[0].position - Vector(game.width * 0.23, game.height / 2)).length < 0.00001,
                    "cue missed its pocket or respotted unsafely")
            }
        }
    }
}
check("aimed pocket entry agrees with the physical capture circle for every rack") {
    for count in 15...45 {
        for pocketIndex in 0..<6 {
            let game = BilliardsGame(iconCount: count), pocket = game.pockets[pocketIndex]
            let inward = Vector(game.width / 2, game.height / 2) - pocket
            let unit = inward * (1 / inward.length)
            let expectedDistance = game.pocketRadius - game.balls[0].radius * 0.15
            game.balls[0].position = pocket + unit * (expectedDistance + 5)
            let guide = game.aimGuide(toward: pocket)
            try expect(guide.cuePath.count == 2 && guide.targetBallID == nil && guide.collisionCenter == nil,
                       "guide wrongly predicts a pocket-mouth rail bounce")
            try expect(abs((guide.cuePath[1] - pocket).length - expectedDistance) < 0.00001,
                       "guide capture point differs from the physical pocket")
        }
    }
}
check("slow rendering preserves full active wall time") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[1].position = Vector(850, 350)
    _ = game.shoot(toward: Vector(900, 250), power: 0.2)
    game.step(0.4)
    try expect(abs(game.elapsed - 0.4) < 0.000001, "long frame shortened score time")
    try expect(game.balls[0].position.x < 300, "long frame caused unbounded physics catch-up")
}
check("head-on guide uses actual contact circles and outgoing object path") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(200, 250)
    game.balls[1].position = Vector(500, 250)
    let original = game.balls
    let guide = game.aimGuide(toward: Vector(900, 250))
    try expect(guide.targetBallID == game.balls[1].id, "guide missed target identity")
    try expect(abs((guide.collisionCenter?.x ?? 0) - (500 - game.balls[0].radius - game.balls[1].radius)) < 0.0001, "ghost centre does not use both radii")
    try expect(guide.objectPath.count == 2 && guide.objectPath[1].x > guide.objectPath[0].x, "missing outgoing object path")
    try expect(game.balls == original && game.shots == 0 && game.elapsed == 0, "guide changed round state")
}
check("glancing guide separates white and object collision directions") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(200, 200)
    game.balls[1].position = Vector(500, 250)
    let guide = game.aimGuide(toward: Vector(900, 300))
    try expect(guide.cuePath.count == 3 && guide.objectPath.count == 2, "outgoing guide legs missing")
    try expect(guide.cuePath[2].y < guide.cuePath[1].y && guide.objectPath[1].y > guide.objectPath[0].y,
               "glancing directions differ from collision impulse")
}
check("rail guide reflects once and stops at the next contact") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(200, 150)
    game.balls[1].position = Vector(850, 350)
    let guide = game.aimGuide(toward: Vector(200, 900))
    try expect(guide.targetBallID == nil && guide.cuePath.count == 3, "rail guide missing rebound")
    try expect(abs(guide.cuePath[1].y - (game.height - game.balls[0].radius)) < 0.0001 && abs(guide.cuePath[2].y - game.balls[0].radius) < 0.0001,
               "rail contacts use incorrect radius inset")
}
check("object guide ends before another obstructing icon") {
    let game = BilliardsGame(iconCount: 2)
    game.balls[0].position = Vector(200, 250)
    game.balls[1].position = Vector(500, 250)
    game.balls[2].position = Vector(700, 250)
    let guide = game.aimGuide(toward: Vector(900, 250))
    try expect(abs((guide.objectPath.last?.x ?? 0) - (700 - game.balls[1].radius - game.balls[2].radius)) < 0.0001, "outgoing path passed through next icon")
}
check("pocket guide and moving icon agree at steep corner mouths") {
    let game = BilliardsGame(iconCount: 1)
    game.balls[0].position = Vector(100, 450)
    game.balls[1].position = Vector(850, 350)
    let guide = game.aimGuide(toward: Vector(0, 20))
    try expect(guide.cuePath.count == 2 && guide.collisionCenter == nil, "corner mouth incorrectly reflects guide")
    let origin = Vector(100, 450), offset = Vector(0, 20) - origin
    game.balls[0].position = Vector(800, 250)
    game.balls[1].position = origin
    game.balls[1].velocity = offset * (800 / offset.length)
    for _ in 0..<200 { game.step(1 / 120) }
    try expect(game.balls[1].pocketed, "physical ball rebounded from an open corner mouth")
}
check("weak corner-mouth approaches cannot leave a stopped ball outside the rails") {
    for power in stride(from: 0.100, through: 0.115, by: 0.001) {
        for fps in [30.0, 60.0, 120.0] {
            let game = BilliardsGame(iconCount: 1)
            game.balls[0].position = Vector(200, 250)
            game.balls[1].position = Vector(850, 350)
            _ = game.shoot(toward: Vector(0, 20), power: power)
            for _ in 0..<Int(fps * 5) { game.step(1 / fps) }
            try expect(!game.isMoving, "weak shot did not settle")
            for ball in game.balls where !ball.pocketed {
                try expect(ball.position.x >= ball.radius && ball.position.x <= game.width - ball.radius
                    && ball.position.y >= ball.radius && ball.position.y <= game.height - ball.radius,
                    "stopped corner-mouth ball escaped legal centre bounds")
            }
        }
    }
}
check("guides reject invalid or unavailable ready state") {
    let game = BilliardsGame()
    try expect(game.aimGuide(toward: Vector(.nan, 0)).cuePath.isEmpty, "NaN guide accepted")
    try expect(game.aimGuide(toward: Vector(.greatestFiniteMagnitude, .greatestFiniteMagnitude)).cuePath.isEmpty,
               "overflowing guide direction accepted")
    _ = game.shoot(toward: Vector(900, 250), power: 0.2)
    try expect(game.aimGuide(toward: Vector(900, 250)).cuePath.isEmpty, "guide shown during rolling")
}

print("\(passed) checks passed; \(failed) failed")
if failed > 0 { exit(1) }
