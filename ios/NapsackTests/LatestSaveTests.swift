import Foundation
import Testing
@testable import Napsack

/// A wheel spun through many dates sends only the one it stopped on.
@MainActor @Test(.timeLimit(.minutes(1))) func onlyTheNewestWaitingIsSaved() async throws {
    let saves = LatestSave()
    var sent: [Int] = []
    var finished = 0
    for value in 1...5 {
        saves.save(after: .milliseconds(50)) { sent.append(value) } done: { _ in finished += 1 }
        try await Task.sleep(for: .milliseconds(5))
    }
    while finished < 1 { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(100))  // nothing else follows
    #expect(sent == [5])
}

/// A change made while the last one is still on its way goes after it, never
/// before: the server ends up with the newest.
@MainActor @Test(.timeLimit(.minutes(1))) func savesGoInOrder() async throws {
    let saves = LatestSave()
    var events: [String] = []
    var finished = 0
    saves.save(after: .zero) {
        events.append("1 start")
        try await Task.sleep(for: .milliseconds(200))  // a slow request
        events.append("1 end")
    } done: { _ in finished += 1 }
    while events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }  // 1 is on its way (waited for, not guessed)
    saves.save(after: .zero) { events.append("2 start") } done: { _ in finished += 1 }
    saves.save(after: .zero) { events.append("3 start") } done: { _ in finished += 1 }  // replaces 2 before it went
    while finished < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(events == ["1 start", "1 end", "3 start"])
}

/// A failure is said, and the next change still saves.
@MainActor @Test(.timeLimit(.minutes(1))) func aFailedSaveIsSaidAndTheNextGoes() async throws {
    struct Refused: Error {}
    let saves = LatestSave()
    var results: [Bool] = []
    saves.save(after: .zero) { throw Refused() } done: { results.append($0 == nil) }
    while results.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
    saves.save(after: .zero) {} done: { results.append($0 == nil) }
    while results.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(results == [false, true])
}

@Test func birthdaysInWords() throws {
    let date = try #require(Calendar.current.date(from: DateComponents(year: 1990, month: 3, day: 4)))
    #expect(SettingsScreen.words(date, withYear: false).contains("March"))
    #expect(!SettingsScreen.words(date, withYear: false).contains("1990"))
    #expect(SettingsScreen.words(date, withYear: true).contains("1990"))
}
