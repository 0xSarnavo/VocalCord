import Foundation
import Testing
@testable import VocalCord

@MainActor
struct ReadAlongTests {
    private let times = [WordTime(start: 0.10, end: 0.40), WordTime(start: 0.50, end: 0.90), WordTime(start: 1.20, end: 1.60)]

    @Test func litWordIsTheLastToHaveStarted() {
        #expect(ReadAlong.token(at: 0, in: times) == -1)
        #expect(ReadAlong.token(at: 0.06, in: times) == 0)       // within the lead
        #expect(ReadAlong.token(at: 0.42, in: times) == 0)       // in the gap, the word before stays lit
        #expect(ReadAlong.token(at: 0.70, in: times) == 1)
        #expect(ReadAlong.token(at: 5, in: times) == 2)
        #expect(ReadAlong.token(at: 1, in: []) == -1)
    }
}
