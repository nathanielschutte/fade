import CryptoKit
import Foundation
import NapsackCrypto
import Testing
@testable import Napsack

/// What each chat row says, with the vectors' people: I'm Bob (id 3), Alice
/// (id 7) is a friend, and her messages are the vectors' real ciphertexts.
/// The data is decoded from JSON shaped as the server sends it.
@Suite struct ChatListTests {
    let v: [String: Any], vg: [String: Any]
    let alice: [String: Any], bob: [String: Any]
    let reader: Reader

    init() throws {
        let folder = try #require(Bundle.main.url(forResource: "vectors", withExtension: nil))
        func load(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "\(name).json"))) as! [String: Any]
        }
        v = try load("format1")
        vg = try load("group3")
        alice = v["alice"] as! [String: Any]
        bob = v["bob"] as! [String: Any]
        let me = Me(id: 3, username: "bob", displayName: "Bobby", role: "user", hasRecoveryKey: true)
        let identity = try P256.KeyAgreement.PrivateKey(derRepresentation: E2E.fromB64(bob["pkcs8"] as! String))
        let friend = try Self.decode(Friend.self, Self.friendJSON(alice: alice, nickname: "Al", last: nil))
        reader = Reader(me: me, identity: identity, friends: [7: friend])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try Server.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func friendJSON(alice: [String: Any], nickname: String? = nil, last: Any?, extra: [String: Any] = [:]) -> [String: Any] {
        var f: [String: Any] = ["id": 7, "username": "alice", "display_name": "Alice", "nickname": nickname ?? NSNull(),
                                "avatar_id": NSNull(), "public_key": alice["spki"]!, "last_message": last ?? NSNull(),
                                "unread": 0, "favorite": false, "hidden": false, "muted": false, "deactivated": false, "system": false,
                                "streak": 0, "streak_expiring": false]
        f.merge(extra) { $1 }
        return f
    }

    func direct(_ m: [String: Any], extra: [String: Any] = [:]) throws -> Friend {
        try Self.decode(Friend.self, Self.friendJSON(alice: alice, nickname: "Al", last: m, extra: extra))
    }

    func message(from sender: Int64, to recipient: Int64, kind: String = "text", ciphertext: String? = nil, format: Int = 1,
                 snap: String? = nil, read: Bool = false, edit: String? = nil, id: Int64 = 100) -> [String: Any] {
        ["id": id, "sender_id": sender, "recipient_id": recipient, "kind": kind, "ciphertext": ciphertext ?? NSNull(),
         "format": format, "snap_state": snap ?? NSNull(), "created_at": 1_793_300_000, "read_at": read ? 1_793_300_100 : NSNull(),
         "client_id": NSNull(), "edit_ciphertext": edit ?? NSNull(), "edit_format": NSNull(), "edited_at": NSNull(), "reactions": []]
    }

    var pairKey: SymmetricKey {
        get throws { try E2E.pairKey(mine: reader.identity, theirs: alice["spki"] as! String, myId: 3, theirId: 7) }
    }

    @Test func aTextFromAFriendIsDecrypted() throws {
        let text = v["text"] as! [String: Any]  // Alice (7) to Bob (3), format 1
        let unread = try direct(message(from: 7, to: 3, ciphertext: text["ciphertext"] as? String))
        #expect(reader.status(unread) == (text["plaintext"] as! String, .text))
        let read = try direct(message(from: 7, to: 3, ciphertext: text["ciphertext"] as? String, read: true))
        #expect(reader.status(read) == (text["plaintext"] as! String, nil))
        #expect(reader.row(read).name == "Al")  // my nickname for her
    }

    @Test func myOwnTextAndItsNewestEdit() throws {
        let sent = try E2E.encryptText2(pairKey, "on my way", replyTo: nil, sender: 3, recipient: 7)
        #expect(reader.status(try direct(message(from: 3, to: 7, ciphertext: sent, format: 2))) == ("You: on my way", nil))
        let edit = try E2E.encryptEdit(pairKey, "on my way, 5 min", sender: 3, recipient: 7, message: 100)
        #expect(reader.status(try direct(message(from: 3, to: 7, ciphertext: sent, format: 2, edit: edit))) == ("You: on my way, 5 min", nil))
    }

    @Test func whatCantBeOpenedSaysSo() throws {
        let sent = try E2E.encryptText2(pairKey, "hi", replyTo: nil, sender: 3, recipient: 7)
        #expect(reader.status(try direct(message(from: 7, to: 3, ciphertext: sent, format: 2, read: true))).0 == "Encrypted message")  // wrong sender
        #expect(reader.status(try direct(message(from: 7, to: 3, ciphertext: sent, format: 9, read: true))).0 == "Encrypted message")  // a newer format
    }

    @Test func picsAndVideosInWords() throws {
        func snap(_ from: Int64, _ state: String, format: Int = 2) throws -> (String, ChatRow.Waiting?) {
            reader.status(try direct(message(from: from, to: from == 3 ? 7 : 3, kind: "snap", format: format, snap: state)))
        }
        #expect(try snap(7, "pending") == ("New pic", .snap))
        #expect(try snap(7, "pending", format: 4) == ("New video", .snap))
        #expect(try snap(3, "pending") == ("Sent a pic", nil))
        #expect(try snap(3, "opened") == ("Pic opened", nil))
        #expect(try snap(3, "expired") == ("Pic expired unopened", nil))
        #expect(try snap(7, "opened") == ("Pic viewed", nil))
        #expect(try snap(7, "expired", format: 4) == ("Video expired", nil))
    }

    @Test func emptyAndTurnedOffChats() throws {
        #expect(reader.status(try Self.decode(Friend.self, Self.friendJSON(alice: alice, last: nil))) == ("Say hi", nil))
        let off = try Self.decode(Friend.self, Self.friendJSON(alice: alice, last: nil, extra: ["deactivated": true]))
        #expect(reader.status(off) == ("Account turned off", nil))
    }

    func group(_ last: [String: Any]?, unread: Int = 0) throws -> GroupSummary {
        try Self.decode(GroupSummary.self, ["id": 12, "name": "Road trip", "role": "member", "member_count": 4,
                                            "last_message": last.map { $0 as Any } ?? NSNull(), "unread": unread, "favorite": false,
                                            "muted": false, "muted_until": NSNull(), "avatar_id": NSNull(), "encrypted": false])
    }

    func groupMessage(kind: String = "text", body: String = "", format: Int = 0, sender: Int64 = 7, extra: [String: Any] = [:]) -> [String: Any] {
        var m: [String: Any] = ["id": 50, "group_id": vg["group_id"]!, "sender_id": sender, "sender_name": "alice", "kind": kind,
                                "body": body, "format": format, "created_at": 1_793_300_000, "pic_id": NSNull(), "reply_to": NSNull(),
                                "pic": NSNull(), "reactions": []]
        m.merge(extra) { $1 }
        return m
    }

    @Test func anEncryptedGroupTextIsOpenedWithMyOwnWrap() throws {
        let t = vg["text"] as! [String: Any]
        let m = groupMessage(format: 3, sender: vg["sender"] as! Int64, extra: [
            "client_id": t["client_id"]!, "recipients": t["recipients"]!, "content": t["content"]!,
            "key": (t["wraps"] as! [String: Any])["3"]!, "sender_public_key": alice["spki"]!])
        #expect(reader.status(try group(m, unread: 1)) == ("Al: \(t["text"] as! String)", .text))
        // Someone else's wrap doesn't open it.
        var wrong = m
        wrong["key"] = (t["wraps"] as! [String: Any])["7"]!
        #expect(reader.status(try group(wrong)).0 == "Al: Encrypted message")
    }

    @Test func groupPicsEventsAndOldPlainTexts() throws {
        #expect(reader.status(try group(nil)) == ("4 people", nil))
        #expect(reader.status(try group(groupMessage(body: "hello all"))) == ("Al: hello all", nil))
        #expect(reader.status(try group(groupMessage(body: "mine", sender: 3))) == ("You: mine", nil))
        let pic: [String: Any] = ["id": 1, "bytes": 10, "expires_at": 0, "discard_reason": NSNull(), "viewers": []]
        #expect(reader.status(try group(groupMessage(format: 7, extra: ["pic": pic]))) == ("Al sent a pic", .snap))
        #expect(reader.status(try group(groupMessage(format: 5, sender: 3, extra: ["pic": pic]))) == ("You sent a video", nil))
        let added = groupMessage(kind: "event", body: #"{"type":"added","target":3,"target_name":"bob"}"#)
        #expect(reader.status(try group(added)).0 == "Al added you")
        let renamed = groupMessage(kind: "event", body: #"{"type":"renamed","name":"Beach"}"#, sender: 3)
        #expect(reader.status(try group(renamed)).0 == "You renamed the group to “Beach”")
    }

    @Test func streaksAndBirthdaysBesideTheName() throws {
        let today = Calendar.current.dateComponents([.month, .day], from: .now)
        let md = String(format: "%02d-%02d", today.month!, today.day!)
        func marks(_ extra: [String: Any]) throws -> String { Reader.marks(try direct(message(from: 7, to: 3, read: true), extra: extra)) }
        #expect(try marks(["streak": 2]) == "")  // shown from 3 days
        #expect(try marks(["streak": 5]) == " 🔥5")
        #expect(try marks(["streak": 5, "streak_expiring": true]) == " 🔥5⌛")
        #expect(try marks(["birthday": md]) == " 🎂")
        #expect(try marks(["birthday": "13-40"]) == "")
        #expect(try reader.row(try direct(message(from: 7, to: 3, read: true), extra: ["streak": 3, "birthday": md])).marks == " 🔥3 🎂")
    }

    @MainActor @Test func anAnnouncementShowsUntilItEnds() {
        let list = ChatList(pinStore: MemoryPinStore(), cacheRoot: nil)
        let now = Int64(Date().timeIntervalSince1970)
        list.announce(ChatList.Announcement(id: 1, body: "Maintenance tonight", endsAt: now + 3600))
        #expect(list.announcement?.body == "Maintenance tonight")
        list.announce(ChatList.Announcement(id: 2, body: "Over", endsAt: now - 1))
        #expect(list.announcement == nil)
        guard case .announcement(let a) = LiveEvent.decode(json(["type": "announcement", "announcement": ["id": 3, "body": "Hi", "created_at": 1, "ends_at": now + 60]])),
              a?.id == 3, case .announcement(nil) = LiveEvent.decode(json(["type": "announcement", "announcement": NSNull()]))
        else { Issue.record("announcement events"); return }
    }

    /// What tapping a row does, decided by its data (Nate, 2026-11-02): the
    /// newest message a pic or video from them, waiting, in a format this app
    /// opens, shows the pics from the list; anything else opens the chat.
    @Test func tappingARowDecidesByItsData() throws {
        func opens(_ m: [String: Any], extra: [String: Any] = [:], changed: Bool = false) throws -> Bool {
            var reader = reader
            if changed { reader.changed = [7] }
            return reader.row(try direct(m, extra: extra)).opensPics
        }
        #expect(try opens(message(from: 7, to: 3, kind: "snap", format: 6, snap: "pending")))  // a photo
        #expect(try opens(message(from: 7, to: 3, kind: "snap", format: 4, snap: "pending")))  // a video
        #expect(try opens(message(from: 7, to: 3, kind: "snap", format: 2, snap: "pending")))  // an older pic
        #expect(try !opens(message(from: 3, to: 7, kind: "snap", format: 6, snap: "pending")))  // mine
        #expect(try !opens(message(from: 7, to: 3, kind: "snap", format: 6, snap: "opened")))
        #expect(try !opens(message(from: 7, to: 3, kind: "snap", format: 6, snap: "expired")))
        #expect(try !opens(message(from: 7, to: 3, kind: "snap", format: 9, snap: "pending")))  // newer than this app: the chat says so
        #expect(try !opens(message(from: 7, to: 3, ciphertext: (v["text"] as! [String: Any])["ciphertext"] as? String)))  // a text
        #expect(try !opens(message(from: 7, to: 3, kind: "snap", format: 6, snap: "pending"), changed: true))  // safety code changed
        #expect(try !opens(message(from: 7, to: 3, kind: "snap", format: 6, snap: "pending"), extra: ["deactivated": true]))
        #expect(try !reader.row(Self.decode(Friend.self, Self.friendJSON(alice: alice, last: nil))).opensPics)

        func groupOpens(_ format: Int, sender: Int64 = 7, viewers: [Int64] = [], discarded: String? = nil, key: String? = "wrap") throws -> Bool {
            let pic: [String: Any] = ["id": 1, "bytes": 10, "expires_at": 0, "discard_reason": discarded ?? NSNull(), "viewers": viewers]
            return reader.row(try group(groupMessage(format: format, sender: sender, extra: ["pic": pic, "key": key ?? NSNull()]))).opensPics
        }
        #expect(try groupOpens(7) && groupOpens(5) && groupOpens(3))
        #expect(try !groupOpens(7, sender: 3))  // mine
        #expect(try !groupOpens(7, viewers: [3]))  // seen already
        #expect(try !groupOpens(7, discarded: "expired"))
        #expect(try !groupOpens(0, key: nil))  // an old group pic, not sealed for me
        #expect(try !groupOpens(7, key: nil))
        #expect(try !reader.row(group(groupMessage(body: "a text"), unread: 1)).opensPics)
    }

    /// After a group's pics were shown from the list, it's read only if they
    /// were all that was unread; otherwise a text nobody saw would show as seen.
    @Test func aGroupIsReadAfterItsPicsOnlyIfNothingElseWasUnread() {
        func bubble(_ id: Int64, mine: Bool = false, _ content: Bubble.Content = .media("New pic")) -> Bubble {
            Bubble(id: id, mine: mine, sender: mine ? nil : "Al", content: content, replyTo: nil, time: .now, reactions: [])
        }
        let page = [bubble(1, .text("earlier", edited: false)), bubble(2, .text("unseen", edited: false)), bubble(3), bubble(4, .event("Al added you")),
                    bubble(5, mine: true, .text("mine", edited: false)), bubble(6)]
        #expect(Reader.readAfterShowing([3, 6], unread: 2, in: page))  // the two pics were all that was unread
        #expect(!Reader.readAfterShowing([3, 6], unread: 3, in: page))  // a text before them too
        #expect(!Reader.readAfterShowing([6], unread: 2, in: page))  // one wasn't shown (stopped halfway)
        #expect(!Reader.readAfterShowing([3, 6], unread: 0, in: page))  // nothing to read
        #expect(!Reader.readAfterShowing([1, 2, 3, 6], unread: 9, in: page))  // more unread than the page has
    }

    /// A reload doesn't do the work again: each chat key is worked out once,
    /// and a row's newest message is opened once while its sealed bytes stay
    /// the same (an edit opens it again). Only the rows' newest are kept.
    @Test func keysAndPreviewsAreWorkedOutOnce() throws {
        let sent = try E2E.encryptText2(pairKey, "first words", replyTo: nil, sender: 7, recipient: 3)
        let friend = try direct(message(from: 7, to: 3, ciphertext: sent, format: 2, read: true))
        #expect(reader.status(friend).0 == "first words")
        #expect(reader.memo.keptPreviews == 1)
        let key = try #require(reader.readingKeys(friend).first)
        #expect(reader.readingKeys(friend).first == key)
        // The same id with other bytes (an edit) is opened again, not taken from what was kept.
        let edit = try E2E.encryptEdit(pairKey, "second words", sender: 7, recipient: 3, message: 100)
        #expect(reader.status(try direct(message(from: 7, to: 3, ciphertext: sent, format: 2, read: true, edit: edit))).0 == "second words")
        // Rows made: only their newest messages stay kept.
        _ = reader.rows(friends: [try direct(message(from: 7, to: 3, ciphertext: sent, format: 2, read: true, id: 101))], groups: [])
        #expect(reader.memo.keptPreviews == 1)
        _ = reader.rows(friends: [], groups: [])
        #expect(reader.memo.keptPreviews == 0)
    }

    @Test func newestFirstThenByName() throws {
        let old = message(from: 7, to: 3, read: true)
        var newer = old
        newer["created_at"] = 1_793_400_000
        let a = try direct(newer)
        let b = try Self.decode(Friend.self, Self.friendJSON(alice: alice, last: old, extra: ["id": 8, "username": "zed", "nickname": NSNull(), "display_name": NSNull()]))
        let quiet = try group(nil)
        #expect(reader.rows(friends: [b, a], groups: [quiet]).map(\.name) == ["Al", "zed", "Road trip"])
    }
}

/// Lets `#expect` compare a row's words and marker as one.
func == (a: (String, ChatRow.Waiting?), b: (String, ChatRow.Waiting?)) -> Bool { a.0 == b.0 && a.1 == b.1 }
