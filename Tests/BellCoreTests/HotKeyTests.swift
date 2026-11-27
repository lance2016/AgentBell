import Foundation
import Testing
@testable import BellCore

struct HotKeyTests {
    @Test func labelListsModifiersInMenuOrder() {
        let key = HotKey(keyCode: 0x26, modifiers: HotKey.command | HotKey.shift | HotKey.control | HotKey.option, key: "J")
        #expect(key.label == "⌃⌥⇧⌘J")
        #expect(Shortcut.jumpToWaiting.defaultKey.label == "⌃⌥⌘J")
    }

    @Test func keyNames() {
        #expect(HotKey.keyName(keyCode: 0x26, characters: "j") == "J")
        #expect(HotKey.keyName(keyCode: 0x31, characters: " ") == "空格")
        #expect(HotKey.keyName(keyCode: 0x7A, characters: "\u{F704}") == "F1")
        // A key that types nothing printable and has no name of its own.
        #expect(HotKey.keyName(keyCode: 0x72, characters: "\u{F746}") == "键 114")
    }

    @Test func shiftAloneIsNotUsable() {
        #expect(!HotKey(keyCode: 0, modifiers: HotKey.shift, key: "A").isUsable)
        #expect(!HotKey(keyCode: 0, modifiers: 0, key: "A").isUsable)
        #expect(HotKey(keyCode: 0, modifiers: HotKey.option, key: "A").isUsable)
    }

    @Test func storedValueMeansDefaultOffOrOwnKey() {
        let fallback = Shortcut.openPanel.defaultKey
        #expect(HotKey.stored(nil, default: fallback) == fallback)
        #expect(HotKey.stored(Data(), default: fallback) == nil)
        #expect(HotKey.stored(Data("junk".utf8), default: fallback) == fallback)
        let own = HotKey(keyCode: 0x01, modifiers: HotKey.command | HotKey.option, key: "S")
        #expect(HotKey.stored(HotKey.encoded(own), default: fallback) == own)
        #expect(HotKey.encoded(nil).isEmpty)
    }
}
