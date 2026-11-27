import Foundation
import Testing
@testable import BellCore

struct AgentRecordTests {
    @Test func parsesRealOutput() throws {
        let json = """
        [
          {"pid": 96466, "cwd": "/Users/me/ai-pet", "kind": "interactive",
           "startedAt": 1795512153074, "sessionId": "0bd4d541", "name": "ai-pet-7f", "status": "idle"},
          {"pid": 30792, "cwd": "/Users/me/robot", "kind": "interactive",
           "startedAt": 1795661233043, "sessionId": "e19d06ee", "name": "robot-5c", "status": "busy"}
        ]
        """
        let records = try AgentRecord.parseList(Data(json.utf8))
        #expect(records.count == 2)
        #expect(records[0].sessionId == "0bd4d541")
        #expect(records[0].pid == 96466)
        #expect(records[0].isBusy == false)
        #expect(records[1].isBusy == true)
        #expect(records[0].startedAtDate == Date(timeIntervalSince1970: 1_795_512_153.074))
    }

    @Test func skipsMalformedElements() throws {
        let json = """
        [{"pid": 1, "sessionId": "no-cwd"}, {"pid": 2, "cwd": "/a", "sessionId": "ok", "extra": true}]
        """
        let snapshot = try AgentRecord.parseSnapshot(Data(json.utf8))
        #expect(snapshot.records.map(\.sessionId) == ["ok"])
        #expect(!snapshot.isComplete)
    }

    @Test func rejectsNonArray() {
        #expect(throws: (any Error).self) {
            try AgentRecord.parseList(Data("error: unknown command".utf8))
        }
    }
}
