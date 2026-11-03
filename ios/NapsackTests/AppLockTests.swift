import Foundation
import Testing
@testable import Napsack

/// When napsack locks with Face ID (F24). The check itself is the system's.
@MainActor struct AppLockTests {
    @Test func aMinuteAwayLocksAgain() {
        #expect(!AppLock.locksAgain(away: 59))
        #expect(AppLock.locksAgain(away: 60))
    }

    @Test func onItLocksWhenTheAppOpens() {
        #expect(AppLock(enabled: true).locked)
        #expect(!AppLock(enabled: false).locked)
    }

    @Test func offItNeverLocks() {
        let lock = AppLock(enabled: false)
        let start = Date()
        lock.left(at: start)
        lock.returned(at: start.addingTimeInterval(3600))
        #expect(!lock.locked)
    }

    @Test func signingOutTurnsItOff() {
        let lock = AppLock(enabled: true)
        lock.signedOut()
        #expect(!lock.enabled && !lock.locked)
    }
}
