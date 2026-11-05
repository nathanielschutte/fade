import Foundation

/// The password of the accounts the live tests make: the public one against a
/// local server, staging's own (NAPSACK_TEST_PASSWORD, from scripts/test-ios.sh
/// --staging) against staging, where the public one would let anyone in.
let testPassword = ProcessInfo.processInfo.environment["NAPSACK_TEST_PASSWORD"] ?? "correct horse battery"
