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

print("\(passed) checks passed; \(failed) failed")
if failed > 0 { exit(1) }
