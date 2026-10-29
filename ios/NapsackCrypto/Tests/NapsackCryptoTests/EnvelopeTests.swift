import Foundation
import Testing
@testable import NapsackCrypto

/// The envelopes' JSON, byte for byte as JavaScript writes and reads it, beyond
/// what the vectors happen to contain. Each expected value is what
/// shared/crypto/crypto.js gives for the same input (run in Node).
@Suite struct EnvelopeTests {
    @Test func textsEscapeExactlyAsJavaScriptDoes() {
        let tricky = "a\"b\\c\n\r\t\u{08}\u{0C}\u{01}\u{1F}\u{7F}/é😀\u{2028}end"
        let javaScript = "{\"t\":\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\u{7F}/é😀\u{2028}end\",\"re\":7}"
        #expect(E2E.packText(tricky, replyTo: 7) == javaScript)
        #expect(E2E.packText("hi") == #"{"t":"hi"}"#)
    }

    @Test func captionPlacesRoundLikeJavaScript() throws {
        func header(_ y: Double?) throws -> String {
            let body = try E2E.packMedia(Data(), type: "video/mp4", caption: "c", y: y)
            return String(decoding: body.dropFirst(2), as: UTF8.self)
        }
        let base = #"{"type":"video/mp4","c":"c""#
        #expect(try header(0.62) == base + #","y":0.62}"#)
        #expect(try header(1) == base + #","y":1}"#)
        #expect(try header(0) == base + #","y":0}"#)
        #expect(try header(0.12345) == base + #","y":0.123}"#)
        #expect(try header(0.6205) == base + #","y":0.621}"#)
        #expect(try header(-3) == base + #","y":0}"#)
        #expect(try header(7) == base + #","y":1}"#)
        #expect(try header(nil) == base + "}")
    }

    @Test func repliesAreWholeNumbersOnly() throws {
        #expect(try E2E.unpackText(#"{"t":"x","re":7.0}"#).replyTo == 7)
        #expect(try E2E.unpackText(#"{"t":"x","re":"7"}"#).replyTo == nil)
        #expect(try E2E.unpackText(#"{"t":"x","re":7.5}"#).replyTo == nil)
        #expect(try E2E.unpackText(#"{"t":"x","re":true}"#).replyTo == nil)
        #expect(throws: E2E.Failure.self) { try E2E.unpackText("[1]") }
        #expect(throws: E2E.Failure.self) { try E2E.unpackText("null") }
    }

    @Test func mediaTypesAsJavaScriptAllows() throws {
        #expect(throws: E2E.Failure.self) { try E2E.packMedia(Data([1]), type: "IMAGE/JPEG", caption: "") }
        let params = try E2E.packMedia(Data(), type: #"video/mp4;codecs="avc1.42E01E, mp4a.40.2""#, caption: "")
        #expect(String(decoding: params.dropFirst(2), as: UTF8.self) == #"{"type":"video/mp4;codecs=\"avc1.42E01E, mp4a.40.2\"","c":""}"#)
        let upper = try E2E.packMedia(Data(), type: "Video/MP4", caption: "")
        #expect(String(decoding: upper.dropFirst(2), as: UTF8.self) == #"{"type":"Video/MP4","c":""}"#)
    }

    @Test func captionsHaveALimit() {
        #expect(throws: E2E.Failure.captionTooLong) { try E2E.packPic(Data(), caption: String(repeating: "é", count: 501)) }
        #expect((try? E2E.packPic(Data(), caption: String(repeating: "é", count: 500))) != nil)
    }
}
