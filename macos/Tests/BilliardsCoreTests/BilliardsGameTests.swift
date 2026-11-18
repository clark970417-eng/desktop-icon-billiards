import XCTest
@testable import BilliardsCore

final class BilliardsGameTests: XCTestCase {
    private func settle(_ game: BilliardsGame) {
        for _ in 0..<2_400 { game.step(1 / 120.0) }
        XCTAssertFalse(game.isMoving)
    }

    func testChargeCycleMatchesHoldAndReleaseRules() {
        XCTAssertEqual(BilliardsGame.chargePower(seconds: 0), 0)
        XCTAssertEqual(BilliardsGame.chargePower(seconds: 0.75), 0.5)
        XCTAssertEqual(BilliardsGame.chargePower(seconds: 1.5), 1)
        XCTAssertEqual(BilliardsGame.chargePower(seconds: 2.25), 0.5)
        XCTAssertEqual(BilliardsGame.chargePower(seconds: 3), 0)
        XCTAssertEqual(BilliardsGame.chargePower(seconds: .nan), 0)
    }

    func testRackFitsForEverySupportedCountAndResetRestoresIt() {
        for count in 1...45 {
            let game = BilliardsGame(iconCount: count)
            let original = game.balls
            XCTAssertEqual(game.iconCount, count)
            for ball in game.balls {
                XCTAssertTrue(ball.position.x >= ball.radius && ball.position.x <= game.width - ball.radius)
                XCTAssertTrue(ball.position.y >= ball.radius && ball.position.y <= game.height - ball.radius)
                for other in game.balls where other.id != ball.id {
                    XCTAssertGreaterThanOrEqual((ball.position - other.position).length, ball.radius + other.radius)
                }
            }
            XCTAssertTrue(game.shoot(toward: Vector(800, 250), power: 1))
            game.step(0.04)
            game.reset()
            XCTAssertEqual(game.balls, original)
            XCTAssertEqual(game.shots, 0)
            XCTAssertEqual(game.elapsed, 0)
        }
    }

    func testBreakTransfersMotionAndReturnsToReady() {
        let game = BilliardsGame()
        XCTAssertTrue(game.shoot(toward: Vector(900, 250), power: 1))
        XCTAssertFalse(game.shoot(toward: Vector(900, 250), power: 1))
        var iconMoved = false
        for _ in 0..<100 {
            game.step(1 / 120)
            iconMoved = iconMoved || game.balls.contains { !$0.isCue && $0.velocity.length > 1 }
        }
        XCTAssertTrue(iconMoved)
        settle(game)
        XCTAssertEqual(game.shots, 1)
        for ball in game.balls where !ball.pocketed {
            XCTAssertTrue(ball.position.isFinite)
            XCTAssertTrue(ball.velocity.isFinite)
            XCTAssertGreaterThanOrEqual(ball.position.x, ball.radius)
            XCTAssertLessThanOrEqual(ball.position.x, game.width - ball.radius)
        }
    }

    func testFastHeadOnCollisionDoesNotTunnel() {
        let game = BilliardsGame(iconCount: 1)
        game.balls[1].position = Vector(500, 250)
        XCTAssertTrue(game.shoot(toward: Vector(900, 250), power: 1))
        for _ in 0..<8 { game.step(1 / 30) }
        XCTAssertGreaterThan(game.balls[1].position.x, 500)
        XCTAssertLessThan(abs(game.balls[1].velocity.y), 0.001)
    }

    func testAllSixPocketsCaptureIconsAndFreezeCompletedTimer() {
        for pocketIndex in 0..<6 {
            let game = BilliardsGame(iconCount: 1)
            let pocket = game.pockets[pocketIndex]
            let inward = Vector(500, 250) - pocket
            let direction = inward * (1 / inward.length)
            game.balls[1].position = pocket + direction * 80
            game.balls[1].velocity = direction * -600
            for _ in 0..<50 { game.step(1 / 120) }
            XCTAssertTrue(game.balls[1].pocketed, "Pocket \(pocketIndex)")
            XCTAssertTrue(game.isComplete)
            XCTAssertEqual(game.pocketedCount, 1)
            let elapsed = game.elapsed
            game.step(0.05)
            XCTAssertEqual(game.elapsed, elapsed)
            XCTAssertFalse(game.shoot(toward: Vector(900, 250), power: 1))
        }
    }

    func testScratchRespotsCueInClearLocation() {
        let game = BilliardsGame(iconCount: 1)
        game.balls[0].position = Vector(500, 65)
        XCTAssertTrue(game.shoot(toward: Vector(500, 0), power: 0.3))
        settle(game)
        let cue = game.balls[0]
        XCTAssertFalse(cue.pocketed)
        XCTAssertFalse(game.needsCuePlacement)
        XCTAssertGreaterThan((cue.position - game.balls[1].position).length, cue.radius + game.balls[1].radius)
        XCTAssertFalse(game.placeCue(at: Vector(500, 250)))
    }

    func testManualPlacementRejectsPocketAndOverlap() {
        let game = BilliardsGame(iconCount: 1)
        game.balls[0].pocketed = true
        XCTAssertFalse(game.placeCue(at: Vector(0, 0)))
        XCTAssertFalse(game.placeCue(at: game.balls[1].position))
        XCTAssertTrue(game.placeCue(at: Vector(250, 100)))
        XCTAssertFalse(game.balls[0].pocketed)
    }

    func testCrowdedScratchLeavesBallInHandUntilValidPlacement() {
        let game = BilliardsGame(iconCount: 1)
        game.balls = [Ball(id: 0, position: Vector(500, 0), pocketed: true, isCue: true)]
        for x in [0.23, 0.35, 0.45, 0.6, 0.75, 0.85] {
            for y in [0.5, 0.3, 0.7, 0.15, 0.85] {
                game.balls.append(Ball(id: game.balls.count, position: Vector(game.width * x, game.height * y)))
            }
        }
        game.step(1 / 60)
        XCTAssertTrue(game.needsCuePlacement)
        XCTAssertFalse(game.shoot(toward: Vector(900, 250), power: 1))
        XCTAssertTrue(game.placeCue(at: Vector(80, 100)))
        XCTAssertFalse(game.needsCuePlacement)
    }

    func testOverlappingSeparatingBallsDoNotGainImpulse() {
        let game = BilliardsGame(iconCount: 1)
        game.balls[0].position = Vector(400, 250)
        game.balls[1].position = Vector(430, 250)
        game.balls[0].velocity = Vector(-100, 0)
        game.balls[1].velocity = Vector(100, 0)
        game.step(1 / 120)
        XCTAssertLessThan(game.balls[0].velocity.x, 0)
        XCTAssertGreaterThan(game.balls[1].velocity.x, 0)
        XCTAssertLessThan(game.balls[0].velocity.length, 100)
        XCTAssertLessThan(game.balls[1].velocity.length, 100)
    }

    func testFinalPocketStopsOtherBallsAndFreezesRunningTimer() {
        let game = BilliardsGame(iconCount: 1)
        XCTAssertTrue(game.shoot(toward: Vector(900, 250), power: 0.2))
        game.step(0.02)
        game.balls[1].position = Vector(500, 35)
        game.balls[1].velocity = Vector(0, -200)
        game.step(0.02)
        XCTAssertTrue(game.isComplete)
        XCTAssertFalse(game.isMoving)
        XCTAssertGreaterThan(game.elapsed, 0)
        let finished = game.elapsed
        for _ in 0..<10 { game.step(0.05) }
        XCTAssertEqual(game.elapsed, finished)
    }

    func testRailsReflectAndDragEventuallyStopsBall() {
        let game = BilliardsGame(iconCount: 1)
        game.balls[0].position = Vector(100, 150)
        game.balls[0].velocity = Vector(-500, 0)
        for _ in 0..<40 { game.step(1 / 120) }
        XCTAssertGreaterThan(game.balls[0].velocity.x, 0)
        settle(game)
    }

    func testTimerStartsWithAcceptedShotAndInvalidInputCannotPoisonState() {
        let game = BilliardsGame()
        game.step(0.05)
        XCTAssertEqual(game.elapsed, 0)
        XCTAssertFalse(game.shoot(toward: game.balls[0].position, power: 1))
        XCTAssertFalse(game.shoot(toward: Vector(.nan, 0), power: 1))
        XCTAssertFalse(game.shoot(toward: Vector(900, 250), power: .infinity))
        XCTAssertTrue(game.shoot(toward: Vector(900, 250), power: 0.4))
        game.step(0.025)
        XCTAssertEqual(game.elapsed, 0.025, accuracy: 0.00001)
        let balls = game.balls
        game.step(.nan); game.step(-1)
        XCTAssertEqual(game.balls, balls)
        XCTAssertEqual(game.shots, 1)
    }

    func testThirtyAndOneHundredTwentyFPSProduceSimilarShot() {
        func run(fps: Double) -> BilliardsGame {
            let game = BilliardsGame(iconCount: 1)
            game.balls[1].position = Vector(850, 350)
            XCTAssertTrue(game.shoot(toward: Vector(900, 250), power: 0.2))
            for _ in 0..<Int(fps * 2) { game.step(1 / fps) }
            return game
        }
        let slow = run(fps: 30), fast = run(fps: 120)
        XCTAssertLessThan((slow.balls[0].position - fast.balls[0].position).length, 5)
    }
}
