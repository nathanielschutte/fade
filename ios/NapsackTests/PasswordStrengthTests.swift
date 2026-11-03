import Testing
@testable import Napsack

/// The strength hint on a new password (F23), the same rules as the web app's.
struct PasswordStrengthTests {
    @Test func lengthCountsMost() {
        #expect(PasswordStrength.of("short") == .short)
        #expect(PasswordStrength.of("password") == .weak("Easy to guess. A few unrelated words make a strong one."))
        #expect(PasswordStrength.of("aaaaaaaaaaaa") == .weak("Easy to guess. A few unrelated words make a strong one."))
        #expect(PasswordStrength.of("lowercase") == .weak("Weak. Longer is stronger: try a few unrelated words."))
        #expect(PasswordStrength.of("Mixed1case") == .good)
        #expect(PasswordStrength.of("longer lowercase") == .strong)
        #expect(PasswordStrength.of("Tree-Lamp-42") == .strong)
    }

    @Test func theKeepsakeSaysWhatTheKeyIsFor() {
        let text = RecoveryKeyScreen.keepsake("7XKQ-2M4P")
        #expect(text.contains("7XKQ-2M4P") && text.contains("Forgot your password?"))
    }
}
