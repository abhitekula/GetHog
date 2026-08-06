import Testing

@testable import GetHog

@Suite("Mac replay keyboard transport")
struct MacReplayKeyboardTests {
    @Test("space maps to play/pause")
    func spaceTogglesPlayback() {
        #expect(
            MacReplayKeyboard.command(
                for: .space, shift: false, currentTime: 12, upperBound: 100, speed: 2
            ) == .togglePlayPause
        )
    }

    @Test("plain arrows step by the transport bar's ten seconds")
    func arrowsStepTenSeconds() {
        #expect(
            MacReplayKeyboard.command(
                for: .rightArrow, shift: false, currentTime: 20, upperBound: 100, speed: 1
            ) == .seek(to: 30)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .leftArrow, shift: false, currentTime: 20, upperBound: 100, speed: 1
            ) == .seek(to: 10)
        )
    }

    @Test("shifted arrows take the larger jump")
    func shiftedArrowsJumpFurther() {
        #expect(
            MacReplayKeyboard.command(
                for: .rightArrow, shift: true, currentTime: 20, upperBound: 100, speed: 1
            ) == .seek(to: 50)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .leftArrow, shift: true, currentTime: 40, upperBound: 100, speed: 1
            ) == .seek(to: 10)
        )
    }

    @Test("seeks clamp to the playable range")
    func seeksClamp() {
        #expect(
            MacReplayKeyboard.command(
                for: .leftArrow, shift: true, currentTime: 5, upperBound: 100, speed: 1
            ) == .seek(to: 0)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .rightArrow, shift: false, currentTime: 95, upperBound: 100, speed: 1
            ) == .seek(to: 100)
        )
    }

    @Test("brackets walk the transport bar's speed ladder")
    func bracketsStepSpeed() {
        #expect(MacReplayKeyboard.speeds == [1, 2, 4])
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 1
            ) == .setSpeed(2)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 2
            ) == .setSpeed(4)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .openBracket, shift: false, currentTime: 0, upperBound: 100, speed: 4
            ) == .setSpeed(2)
        )
    }

    @Test("the ladder's ends are dead keys, not JavaScript round trips")
    func speedEndsAreNoOps() {
        #expect(
            MacReplayKeyboard.command(
                for: .openBracket, shift: false, currentTime: 0, upperBound: 100, speed: 1
            ) == nil
        )
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 4
            ) == nil
        )
    }

    @Test("an off-ladder speed still steps to a real rung")
    func offLadderSpeedRecovers() {
        #expect(
            MacReplayKeyboard.command(
                for: .closeBracket, shift: false, currentTime: 0, upperBound: 100, speed: 3
            ) == .setSpeed(4)
        )
        #expect(
            MacReplayKeyboard.command(
                for: .openBracket, shift: false, currentTime: 0, upperBound: 100, speed: 3
            ) == .setSpeed(2)
        )
    }
}
