// shared/crypto/vector-checks.js in Swift: the same checks, in the same order,
// under the same names, against the pinned vectors. The tests run them on a
// Mac (`swift test`) and the app on a phone. A failure means this app would
// disagree with the others about bytes on the wire: the Swift is wrong, never
// the vector. (vector-checks.js also checks the browser has WebCrypto and
// TextEncoder; Swift has no such question to ask.)

import CryptoKit
import Foundation
import NapsackCrypto

public struct CheckResult: Sendable, Identifiable, CustomStringConvertible {
    public let name: String
    public let ok: Bool
    public let duration: Duration
    public let error: String?

    public var id: String { name }
    public var description: String { name }
}

/// A check that fails by throwing, for setup the later checks rely on.
struct Missing: Error {}

public enum VectorChecks {
    /// Runs every check, in order (later ones use what earlier ones derived).
    /// `onResult` hears each as it finishes. Slow on purpose in places: several
    /// checks derive keys from a password (600,000 rounds of PBKDF2).
    public static func run(_ vectors: Vectors, onResult: (CheckResult) -> Void = { _ in }) -> [CheckResult] {
        var results: [CheckResult] = []
        func check(_ name: String, _ body: () throws -> Bool) {
            let clock = ContinuousClock()
            let start = clock.now
            var ok = false, error: String?
            do { ok = try body() } catch let e { error = String(describing: e) }
            let r = CheckResult(name: name, ok: ok, duration: clock.now - start, error: error)
            results.append(r)
            onResult(r)
        }
        func fails(_ body: () throws -> Any) -> Bool {
            do { _ = try body(); return false } catch { return true }
        }
        func data(_ b64: String) throws -> Data { try E2E.fromB64(b64) }
        func priv(_ p: Format1.Party) throws -> P256.KeyAgreement.PrivateKey {
            try P256.KeyAgreement.PrivateKey(derRepresentation: data(p.pkcs8))
        }

        let v = vectors.format1, v2 = vectors.format2, vr = vectors.recovery, vt = vectors.texts2
        let vg = vectors.group3, vm = vectors.media4, ve = vectors.edits2, vp = vectors.media6
        var d: E2E.PasswordKeys?, ka: SymmetricKey?, kb: SymmetricKey?, gb: SymmetricKey?, ga: SymmetricKey?
        var rec: E2E.PasswordKeys?
        func got<T>(_ x: T?) throws -> T { guard let x else { throw Missing() }; return x }

        check("base64 round-trips") { E2E.toB64(try data("AAEC/w==")) == "AAEC/w==" }

        // Password -> keys (the slow one: 600,000 rounds of PBKDF2)
        check("password derives the vector's auth key") {
            d = try E2E.deriveFromPassword(username: v.password.username, password: v.password.password)
            return d?.authKey == v.password.authKey
        }
        check("username is case-insensitive") {
            try E2E.deriveFromPassword(username: v.password.username.lowercased(), password: v.password.password).authKey == v.password.authKey
        }
        check("unwrapped key decrypts the vector text") {
            let unwrapped = try E2E.unwrapIdentity(wrapKey: got(d).wrapKey, wrapped: v.password.wrappedPrivateKey)
            let k = try E2E.pairKey(mine: unwrapped, theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
            return try E2E.decryptText(k, v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext
        }
        check("a wrong password can't unwrap") {
            let wrong = try E2E.deriveFromPassword(username: v.password.username, password: "wrong password")
            return fails { try E2E.unwrapIdentity(wrapKey: wrong.wrapKey, wrapped: v.password.wrappedPrivateKey) }
        }

        // Both sides derive the same chat key (ECDH + HKDF)
        check("both friends derive the chat key") {
            ka = try E2E.pairKey(mine: priv(v.alice), theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
            kb = try E2E.pairKey(mine: priv(v.bob), theirs: v.alice.spki, myId: v.bob.id, theirId: v.alice.id)
            return ka == kb
        }
        check("recipient decrypts the vector text") {
            try E2E.decryptText(got(kb), v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext
        }
        check("recipient decrypts the vector pic (format 1)") {
            E2E.toB64(try E2E.decryptSnap(got(kb), data(v.snap.ciphertextB64), sender: v.snap.from, recipient: v.snap.to)) == v.snap.plaintextB64
        }
        check("a fresh text round-trips with a fresh IV") {
            let a = try E2E.encryptText(got(ka), "round trip", sender: v.alice.id, recipient: v.bob.id)
            let b = try E2E.encryptText(got(ka), "round trip", sender: v.alice.id, recipient: v.bob.id)
            return try a != b && E2E.decryptText(got(kb), a, sender: v.alice.id, recipient: v.bob.id) == "round trip"
        }

        // Associated data binds sender, recipient, and kind
        check("swapped sender fails") {
            let k = try got(kb)
            return fails { try E2E.decryptText(k, v.text.ciphertext, sender: v.text.to, recipient: v.text.from) }
        }
        check("a text can't be read as a pic") {
            let k = try got(kb)
            return fails { try E2E.decryptSnap(k, data(v.text.ciphertext), sender: v.text.from, recipient: v.text.to) }
        }
        check("tampering fails") {
            let k = try got(kb)
            var t = [UInt8](try data(v.text.ciphertext))
            t[20] ^= 1
            return fails { try E2E.decryptText(k, E2E.toB64(Data(t)), sender: v.text.from, recipient: v.text.to) }
        }

        // Format 2: pics with captions
        for (name, p) in [("pic", v2.pic), ("pic_no_caption", v2.picNoCaption)] {
            check("recipient decrypts format 2 \(name)") {
                let pic = try E2E.decryptPic(got(kb), data(p.ciphertextB64), format: 2, sender: p.from, recipient: p.to)
                return pic.caption == p.caption && E2E.toB64(pic.photo) == p.photoB64
            }
            check("packs \(name) like the vector") {
                E2E.toB64(try E2E.packPic(data(p.photoB64), caption: p.caption)) == p.plaintextB64
            }
        }
        check("format 2 can't be read as format 1") {
            let k = try got(kb)
            return fails { try E2E.decryptPic(k, data(v2.pic.ciphertextB64), format: 1, sender: v2.pic.from, recipient: v2.pic.to) }
        }
        check("a captioned pic round-trips") {
            let sealed = try E2E.encryptPic(got(ka), photo: Data([1, 2, 3]), caption: "hi \u{1F44B}", sender: v.alice.id, recipient: v.bob.id)
            let back = try E2E.decryptPic(got(kb), sealed, format: 2, sender: v.alice.id, recipient: v.bob.id)
            return back.caption == "hi \u{1F44B}" && back.photo == Data([1, 2, 3])
        }

        // A new account's keys, the way sign-up makes them
        check("a new identity wraps and unwraps") {
            let id = try E2E.createIdentity(wrapKey: got(d).wrapKey)
            let back = try E2E.unwrapIdentity(wrapKey: got(d).wrapKey, wrapped: id.wrappedPrivateKey)
            let k1 = try E2E.pairKey(mine: back, theirs: v.bob.spki, myId: 1, theirId: v.bob.id)
            let k2 = try E2E.pairKey(mine: priv(v.bob), theirs: id.publicKey, myId: v.bob.id, theirId: 1)
            return try E2E.decryptText(k2, E2E.encryptText(k1, "new", sender: 1, recipient: v.bob.id), sender: 1, recipient: v.bob.id) == "new"
        }

        // Format 2 texts (replies) and reactions
        for (i, t) in vt.texts.enumerated() {
            check("format 2 text \(i + 1) decrypts like the vector") {
                let text = try E2E.decryptAnyText(got(kb), t.ciphertext, format: 2, sender: t.from, recipient: t.to)
                return text.text == t.text && text.replyTo == t.replyTo && E2E.packText(t.text, replyTo: t.replyTo) == t.plaintext
            }
        }
        check("format 1 texts still read, with no reply") {
            let text = try E2E.decryptAnyText(got(kb), v.text.ciphertext, format: 1, sender: v.text.from, recipient: v.text.to)
            return text.text == v.text.plaintext && text.replyTo == nil
        }
        check("a format 2 text can't be read as format 1") {
            let k = try got(kb), t = vt.texts[0]
            return fails { try E2E.decryptAnyText(k, t.ciphertext, format: 1, sender: t.from, recipient: t.to) }
        }
        check("unknown envelope fields are ignored") {
            try E2E.unpackText(#"{"t":"later","re":7,"future":true}"#) == E2E.Text(text: "later", replyTo: 7)
        }
        check("malformed envelopes are refused") {
            [#"{"x":1}"#, "not json", #"{"t":5}"#].allSatisfy { j in fails { try E2E.unpackText(j) } }
        }
        let r = vt.reaction
        check("reaction decrypts like the vector") {
            try E2E.decryptReaction(got(kb), r.ciphertext, sender: r.from, recipient: r.to, message: r.messageId) == r.emoji
        }
        check("a reaction can't move to another message") {
            let k = try got(kb)
            return fails { try E2E.decryptReaction(k, r.ciphertext, sender: r.from, recipient: r.to, message: r.messageId + 1) }
        }
        check("a reaction round-trips") {
            let ct = try E2E.encryptReaction(got(ka), E2E.reactions[1], sender: v.alice.id, recipient: v.bob.id, message: 42)
            return try E2E.decryptReaction(got(kb), ct, sender: v.alice.id, recipient: v.bob.id, message: 42) == E2E.reactions[1]
        }

        // Format 3 group messages (docs/implementation/group-encryption.md)
        func opening(_ m: SealedGroup, group: Int64, sender: Int64, me: Int64, _ wrapKey: SymmetricKey) -> E2E.GroupOpening {
            E2E.GroupOpening(groupId: group, senderId: sender, myId: me, clientId: m.clientId, recipients: m.recipients, wrapKey: wrapKey)
        }
        func bobs(_ m: SealedGroup, group: Int64, sender: Int64) throws -> E2E.GroupOpening {
            opening(m, group: group, sender: sender, me: v.bob.id, try got(gb))
        }
        let gt = vg.text.sealed, gp = vg.pic.sealed
        check("group wrap keys for bob and alice") {
            gb = try E2E.groupWrapKey(mine: priv(v.bob), theirs: v.alice.spki, myId: v.bob.id, theirId: v.alice.id)
            ga = try E2E.groupWrapKey(mine: priv(v.alice), theirs: v.alice.spki, myId: v.alice.id, theirId: v.alice.id)
            return true
        }
        check("group text decrypts like the vector") {
            let text = try E2E.decryptGroupText(data(gt.content), wrap: gt.wrap(for: v.bob.id), bobs(gt, group: vg.groupId, sender: vg.sender))
            return text.text == vg.text.text && text.replyTo == vg.text.replyTo
                && E2E.packText(vg.text.text, replyTo: vg.text.replyTo) == vg.text.plaintext
        }
        check("the sender's own devices read it too") {
            let o = opening(gt, group: vg.groupId, sender: vg.sender, me: v.alice.id, try got(ga))
            return try E2E.decryptGroupText(data(gt.content), wrap: gt.wrap(for: v.alice.id), o).text == vg.text.text
        }
        check("group pic decrypts like the vector, caption and all") {
            let pic = try E2E.decryptGroupPic(data(gp.content), wrap: gp.wrap(for: v.bob.id), bobs(gp, group: vg.groupId, sender: vg.sender))
            return pic.caption == vg.pic.caption && E2E.toB64(pic.photo) == vg.pic.photo
        }
        check("one member's wrap doesn't open for another") {
            let o = try bobs(gt, group: vg.groupId, sender: vg.sender)
            return fails { try E2E.decryptGroupText(data(gt.content), wrap: gt.wrap(for: v.alice.id), o) }
        }
        check("a group message can't move to another group") {
            var o = try bobs(gt, group: vg.groupId, sender: vg.sender)
            o.groupId += 1
            return fails { try E2E.decryptGroupText(data(gt.content), wrap: gt.wrap(for: v.bob.id), o) }
        }
        check("or claim a different member list") {
            var o = try bobs(gt, group: vg.groupId, sender: vg.sender)
            o.recipients.append(11)
            return fails { try E2E.decryptGroupText(data(gt.content), wrap: gt.wrap(for: v.bob.id), o) }
        }
        check("a group text can't be read as a pic") {
            let o = try bobs(gt, group: vg.groupId, sender: vg.sender)
            return fails { try E2E.decryptGroupPic(data(gt.content), wrap: gt.wrap(for: v.bob.id), o) }
        }
        check("changed content fails") {
            let o = try bobs(gt, group: vg.groupId, sender: vg.sender)
            var c = [UInt8](try data(gt.content))
            c[c.count - 1] ^= 1
            return fails { try E2E.decryptGroupText(Data(c), wrap: gt.wrap(for: v.bob.id), o) }
        }
        check("a new group message round-trips") {
            let wrapKeys = [
                v.alice.id: try E2E.groupWrapKey(mine: priv(v.alice), theirs: v.alice.spki, myId: v.alice.id, theirId: v.alice.id),
                v.bob.id: try E2E.groupWrapKey(mine: priv(v.alice), theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id),
            ]
            let m = try E2E.encryptGroupText("new", replyTo: nil, groupId: 9, senderId: v.alice.id, wrapKeys: wrapKeys)
            let o = E2E.GroupOpening(groupId: 9, senderId: v.alice.id, myId: v.bob.id, clientId: m.clientId, recipients: m.recipients, wrapKey: try got(gb))
            return try E2E.decryptGroupText(m.content, wrap: m.wraps[v.bob.id] ?? "", o).text == "new" && E2E.groupFormat == 3 && m.wraps.count == 2
        }

        // Videos: format 4 (direct) and 5 (group), the media envelope
        let md = vm.direct, mg = vm.group.sealed
        check("a format 4 video decrypts like the vector, caption and all") {
            let m = try E2E.decryptVideo(got(kb), data(md.ciphertext), sender: md.from, recipient: md.to)
            return try m.type == md.type && m.caption == md.caption && E2E.toB64(m.media) == md.media
                && E2E.toB64(E2E.packMedia(data(md.media), type: md.type, caption: md.caption)) == md.plaintext
        }
        check("a video can't be read as a pic") {
            let k = try got(kb)
            return fails { try E2E.decryptPic(k, data(md.ciphertext), format: 2, sender: md.from, recipient: md.to) }
        }
        check("a format 5 group video decrypts like the vector") {
            let m = try E2E.decryptGroupVideo(data(mg.content), wrap: mg.wrap(for: v.bob.id), bobs(mg, group: vm.group.groupId, sender: vm.group.sender))
            return m.type == vm.group.type && m.caption == vm.group.caption && E2E.toB64(m.media) == vm.group.media
        }
        check("a group video can't be read as a group pic") {
            let o = try bobs(mg, group: vm.group.groupId, sender: vm.group.sender)
            return fails { try E2E.decryptGroupPic(data(mg.content), wrap: mg.wrap(for: v.bob.id), o) }
        }
        check("only video types travel in the envelope") {
            let header = Data(#"{"type":"text/html","c":""}"#.utf8)
            let forged = Data([0, UInt8(header.count)]) + header + Data([1, 2, 3])
            return fails { try E2E.packMedia(Data([1]), type: "text/html", caption: "") }
                && fails { try E2E.unpackMedia(forged, kind: .video) }
        }
        check("a video round-trips") {
            let sealed = try E2E.encryptVideo(got(kb), Data([9, 8, 7]), type: "video/mp4", caption: "hi", sender: v.alice.id, recipient: v.bob.id)
            let m = try E2E.decryptVideo(got(kb), sealed, sender: v.alice.id, recipient: v.bob.id)
            return m.caption == "hi" && m.media == Data([9, 8, 7]) && E2E.videoFormat == 4 && E2E.groupVideoFormat == 5
        }

        // Photos in the media envelope (formats 6 and 7), with the caption's place
        let pd = vp.direct, pg = vp.group.sealed
        check("a format 6 photo decrypts like the vector, caption and place") {
            let m = try E2E.decryptImage(got(kb), data(pd.ciphertext), sender: pd.from, recipient: pd.to)
            return try m.type == "image/jpeg" && m.caption == pd.caption && m.y == pd.y && E2E.toB64(m.media) == pd.media
                && E2E.toB64(E2E.packMedia(data(pd.media), type: "image/jpeg", caption: pd.caption, y: pd.y)) == pd.plaintext
        }
        check("a photo can't be read as a video or a format 2 pic") {
            let k = try got(kb)
            return fails { try E2E.decryptVideo(k, data(pd.ciphertext), sender: pd.from, recipient: pd.to) }
                && fails { try E2E.decryptPic(k, data(pd.ciphertext), format: 2, sender: pd.from, recipient: pd.to) }
        }
        check("a format 7 group photo decrypts like the vector, with no place") {
            let o = try bobs(pg, group: vp.group.groupId, sender: vp.group.sender)
            let m = try E2E.decryptGroupImage(data(pg.content), wrap: pg.wrap(for: v.bob.id), o)
            return m.caption == vp.group.caption && m.y == nil && E2E.toB64(m.media) == vp.group.media
                && fails { try E2E.decryptGroupVideo(data(pg.content), wrap: pg.wrap(for: v.bob.id), o) }
        }
        check("only JPEGs travel as photos") {
            fails { try E2E.packMedia(Data([1]), type: "image/svg+xml", caption: "") }
        }

        // Edits to texts: bound to the message they edit
        let ed = ve.direct, eg = ve.group.sealed
        check("a direct edit decrypts like the vector") {
            try E2E.decryptEdit(got(kb), ed.ciphertext, sender: ed.from, recipient: ed.to, message: ed.messageId) == ed.text
                && E2E.packText(ed.text) == ed.plaintext
        }
        check("an edit can't be moved to another message") {
            let k = try got(kb)
            return fails { try E2E.decryptEdit(k, ed.ciphertext, sender: ed.from, recipient: ed.to, message: ed.messageId + 1) }
        }
        check("an edit can't be read as a text") {
            let k = try got(kb)
            return fails { try E2E.decryptAnyText(k, ed.ciphertext, format: 2, sender: ed.from, recipient: ed.to) }
        }
        check("a group edit decrypts like the vector") {
            let o = try bobs(eg, group: ve.group.groupId, sender: ve.group.sender)
            return try E2E.decryptGroupEdit(data(eg.content), wrap: eg.wrap(for: v.bob.id), message: ve.group.messageId, o) == ve.group.text
                && fails { try E2E.decryptGroupEdit(data(eg.content), wrap: eg.wrap(for: v.bob.id), message: ve.group.messageId + 1, o) }
        }

        // Recovery keys and changing the password
        check("recovery key displays like the vector") {
            let hex = Array(vr.keyBytesHex)
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(String(hex[$0..<$0 + 2]), radix: 16) }
            return E2E.formatRecoveryKey(Data(bytes)) == vr.recoveryKey
        }
        check("recovery key reads back despite typos") {
            let sloppy = vr.recoveryKey.lowercased()
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "0", with: "o")
                .replacingOccurrences(of: "1", with: "l")
            return try E2E.parseRecoveryKey(sloppy) == E2E.parseRecoveryKey(vr.recoveryKey)
        }
        check("recovery key derives the vector's auth key") {
            rec = try E2E.deriveFromRecoveryKey(vr.recoveryKey)
            return rec?.authKey == vr.recoveryAuthKey
        }
        check("recovery key unlocks the vector's private key") {
            let next = try E2E.deriveFromPassword(username: v.password.username, password: "a brand new password")
            let back = try E2E.recoverIdentity(recoveryWrapKey: got(rec).wrapKey, recoveryWrapped: vr.recoveryWrappedKey, newWrapKey: next.wrapKey)
            let k = try E2E.pairKey(mine: back.privateKey, theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
            let again = try E2E.unwrapIdentity(wrapKey: next.wrapKey, wrapped: back.wrappedPrivateKey)
            let k2 = try E2E.pairKey(mine: again, theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
            return try E2E.decryptText(k, v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext
                && E2E.decryptText(k2, v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext
        }
        check("a recovery copy round-trips") {
            let copy = try E2E.wrapForRecovery(wrapKey: got(d).wrapKey, wrapped: v.password.wrappedPrivateKey, recoveryWrapKey: got(rec).wrapKey)
            let back = try E2E.recoverIdentity(recoveryWrapKey: got(rec).wrapKey, recoveryWrapped: copy, newWrapKey: got(d).wrapKey)
            let k = try E2E.pairKey(mine: back.privateKey, theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
            return try E2E.decryptText(k, v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext
        }
        check("the password-wrapped key can't pass as a recovery copy") {
            let recovery = try got(rec), password = try got(d)
            return fails { try E2E.recoverIdentity(recoveryWrapKey: recovery.wrapKey, recoveryWrapped: v.password.wrappedPrivateKey, newWrapKey: password.wrapKey) }
        }
        check("a wrong recovery key can't unlock") {
            let wrong = try E2E.deriveFromRecoveryKey(E2E.newRecoveryKey()), password = try got(d)
            return fails { try E2E.recoverIdentity(recoveryWrapKey: wrong.wrapKey, recoveryWrapped: vr.recoveryWrappedKey, newWrapKey: password.wrapKey) }
        }
        check("malformed recovery keys are refused") {
            ["", "ABCD-EFGH", String(repeating: "U", count: 32), vr.recoveryKey + "0"].allSatisfy { t in fails { try E2E.parseRecoveryKey(t) } }
        }
        check("changing the password keeps the same key") {
            let next = try E2E.deriveFromPassword(username: v.password.username, password: "another new password")
            let old = try got(d)
            let rewrapped = try E2E.rewrapIdentity(oldWrapKey: old.wrapKey, wrapped: v.password.wrappedPrivateKey, newWrapKey: next.wrapKey)
            let k = try E2E.pairKey(mine: E2E.unwrapIdentity(wrapKey: next.wrapKey, wrapped: rewrapped), theirs: v.bob.spki, myId: v.alice.id, theirId: v.bob.id)
            return try E2E.decryptText(k, v.text.ciphertext, sender: v.text.from, recipient: v.text.to) == v.text.plaintext
                && fails { try E2E.unwrapIdentity(wrapKey: old.wrapKey, wrapped: rewrapped) }
        }

        // Safety code and formats
        check("safety code matches the vector") { E2E.safetyCode(v.alice.spki, v.bob.spki) == v.safetyCode }
        check("safety code is symmetric") { E2E.safetyCode(v.bob.spki, v.alice.spki) == v.safetyCode }
        check("new texts and pics are format 2") { E2E.textFormat == 2 && E2E.snapFormat == 2 }
        return results
    }
}
