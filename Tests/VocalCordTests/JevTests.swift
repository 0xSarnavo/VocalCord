import Foundation
import Synchronization
import Testing
@testable import VocalCord

// No live calls: TypeSafe is faked with saved replies in the documented response schema
// (https://docs.typesafe.ai/api/system-one.md, https://docs.typesafe.ai/api/list-models.md).

final class MemoryKeys: KeyStore {
    let key: Mutex<String?>
    init(_ key: String? = nil) { self.key = Mutex(key) }
    var exists: Bool { key.withLock { $0 != nil } }
    func read() -> String? { key.withLock { $0 } }
    func save(_ key: String) throws { self.key.withLock { $0 = key } }
    func delete() throws { key.withLock { $0 = nil } }
}

/// Replies by the line in the request's state; `models` answers GET /v1/models. Records every request.
final class FakeTypeSafe: Sendable {
    let requests = Mutex<[URLRequest]>([])
    let replies: Mutex<[String: [(status: Int, body: String)]]>

    init(_ replies: [String: [(status: Int, body: String)]]) { self.replies = Mutex(replies) }

    static func answers(_ nouls: [String: Double]) -> (status: Int, body: String) {
        let answers = nouls.map { "\"\($0.key)\":{\"type\":\"noul\",\"noul\":\($0.value)}" }.joined(separator: ",")
        return (200, "{\"model\":\"jev-1.14.0\",\"answers\":{\(answers)},\"usage\":{\"input_tokens\":212,\"output_tokens\":24}}")
    }

    static let models = (status: 200, body: """
        {"models":[{"name":"jev-latest","description":"General-purpose system one model.","release_date":"2026-10-14"}]}
        """)

    var bodies: [[String: Any]] {
        requests.withLock { $0 }.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    var send: TypeSafe.Send {
        { request in
            self.requests.withLock { $0.append(request) }
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let name = request.url?.lastPathComponent == "models" ? "models" : (body?["state"] as? [String: String])?["line"] ?? ""
            // A queue per name: the last reply repeats.
            let reply = self.replies.withLock { replies in
                guard var queue = replies[name], !queue.isEmpty else { return (status: 404, body: "{\"detail\":\"Not Found\"}") }
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                replies[name] = queue
                return next
            }
            guard reply.status >= 0 else { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Retry-After": "0"])!
            return (Data(reply.body.utf8), response)
        }
    }
}

// MARK: Questions

@Test func aRequestCarriesOnlyTheLineTextAndTone() throws {
    let subject = JevSubject(text: "[breath] We  shipped it today. [pause 0.5]", tone: "Happy", original: "The team shipped the product today.")
    #expect(subject.text == "We shipped it today.")
    let data = try JSONSerialization.data(withJSONObject: JevQuestions.body(subject), options: .sortedKeys)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["model", "state", "questions"] && json["model"] as? String == JevQuestions.model)
    #expect(json["state"] as? [String: String] == ["line": "We shipped it today."])
    let questions = try #require(json["questions"] as? [String: [String: Any]])
    #expect(Set(questions.keys) == ["spoken", "fits_tone", "keeps_meaning"])
    for question in questions.values {
        #expect(question["type"] as? String == "noul")
        #expect((question["criteria"] as? [String: String]).map { Set($0.keys) } == ["true", "false"])
    }
    #expect(questions["spoken"]?["instructions"] as? String == "Does `line` read like something a person would say aloud?")
    #expect(questions["fits_tone"]?["instructions"] as? String == "Does `line` suit being spoken in a Happy tone?")
    #expect((questions["fits_tone"]?["criteria"] as? [String: String])?["true"]?.contains("pleased, upbeat") == true)
    #expect(questions["keeps_meaning"]?["instructions"] as? [String: String]
        == ["question": "Does `line` keep the meaning of `original`?", "original": "The team shipped the product today."])

    // Without a rewrite there is no meaning check, and every tone has a meaning.
    let plain = JevQuestions.body(JevSubject(text: "Hi there.", tone: "Neutral"))
    #expect((plain["questions"] as? [String: Any]).map { Set($0.keys) } == ["spoken", "fits_tone"])
    #expect(Tone.all.allSatisfy { JevQuestions.toneMeaning[$0] != nil })
}

@Test func thresholdsSplitYesUnsettledAndNo() {
    #expect([0.95, 0.7, 0.69, 0.5, 0.31, 0.3, 0.02].map(JevQuestions.verdict) == [.yes, .yes, .unsettled, .unsettled, .unsettled, .no, .no])
    let fail = JevResult(model: "m", answers: [.spoken: 0.9, .fitsTone: 0.1, .keepsMeaning: 0.5])
    #expect(fail.status == .no && fail.notes(tone: "Sad") == ["Doesn't fit Sad", "May change the original meaning"])
    let unsettled = JevResult(model: "m", answers: [.spoken: 0.5, .fitsTone: 0.9])
    #expect(unsettled.status == .unsettled && unsettled.notes(tone: "Sad") == ["May read like written text"])
    let pass = JevResult(model: "m", answers: [.spoken: 0.9, .fitsTone: 0.8])
    #expect(pass.status == .yes && pass.notes(tone: "Sad") == ["Reads as speech", "Fits Sad"])
}

@MainActor @Test func aRewriteIsCheckedAgainstTheTextItReplaced() throws {
    let projects = ProjectStore(root: try tempFolder())
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let id = projects.create(name: "Film")
    projects.addLines(["Our app helps you save money every single month."], to: id, voices: voices)
    let lineID = try #require(projects.project(id)?.lines.first?.id)
    #expect(JevSubject(try #require(projects.project(id)?.lines.first)).original == nil)

    // Pending: the proposal is judged against the line as it is.
    projects.propose(Proposal(text: "Save money. Every month.", tone: "Confident", pauseAfter: 0.5), line: lineID, in: id)
    var line = try #require(projects.project(id)?.lines.first)
    #expect(JevSubject(line) == JevSubject(text: "Save money. Every month.", tone: "Confident", original: "Our app helps you save money every single month."))

    // Accepted: the replaced text is kept, through a second rewrite, and saved.
    projects.accept([lineID], in: id)
    projects.propose(Proposal(text: "Save every month.", tone: "Confident", pauseAfter: 0.5), line: lineID, in: id)
    projects.accept([lineID], in: id)
    line = try #require(ProjectStore(root: projects.root).project(id)?.lines.first)
    #expect(JevSubject(line) == JevSubject(text: "Save every month.", tone: "Confident", original: "Our app helps you save money every single month."))

    // The user's own edit ends the agent rewrite.
    projects.setText("Save every month, easily.", line: lineID, in: id)
    #expect(projects.project(id)?.lines.first?.original == nil)
}

// MARK: Plugin

@MainActor @Test func addingAKeyValidatesItFirst() async throws {
    let keys = MemoryKeys()
    let typeSafe = FakeTypeSafe(["models": [(401, "{\"detail\":\"Invalid API key\"}"), FakeTypeSafe.models]])
    let jev = Jev(keys: keys, send: typeSafe.send)
    #expect(!jev.added)

    await #expect(throws: AppError.self) { try await jev.add(key: "  ") }
    let error = await #expect(throws: AppError.self) { try await jev.add(key: "bad") }
    #expect(error?.localizedDescription == "TypeSafe didn't accept the API key.")
    #expect(!jev.added && keys.read() == nil)

    try await jev.add(key: " ts_live_123\n")
    #expect(jev.added && keys.read() == "ts_live_123")
    let request = try #require(typeSafe.requests.withLock { $0.last })
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/models" && request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ts_live_123")

    try jev.remove()
    #expect(!jev.added && keys.read() == nil && !Jev(keys: keys, send: typeSafe.send).added)
}

@MainActor @Test func checksAreCachedAndFailedCallsAreErrors() async throws {
    let typeSafe = FakeTypeSafe([
        "We did it!": [FakeTypeSafe.answers(["spoken": 0.96, "fits_tone": 0.91])],
        "We lost everything.": [FakeTypeSafe.answers(["spoken": 0.93, "fits_tone": 0.08])],
        "Click here: https://x.io": [FakeTypeSafe.answers(["spoken": 0.45, "fits_tone": 0.8])],
        "Busy line.": [(429, "{}"), FakeTypeSafe.answers(["spoken": 0.9, "fits_tone": 0.9])],
        "Server error.": [(500, "{}")],
        "Offline.": [(-1, "")],
        "Short reply.": [FakeTypeSafe.answers(["spoken": 0.9])],
    ])
    let jev = Jev(keys: MemoryKeys("ts_key"), send: typeSafe.send)
    let happy = JevSubject(text: "We did it!", tone: "Happy"), sad = JevSubject(text: "We lost everything.", tone: "Happy")
    let link = JevSubject(text: "Click here: https://x.io", tone: "Neutral"), busy = JevSubject(text: "Busy line.", tone: "Neutral")
    let broken = ["Server error.", "Offline.", "Short reply."].map { JevSubject(text: $0, tone: "Neutral") }
    await jev.check([happy, sad, link, busy, JevSubject(text: "[pause 1]", tone: "Neutral")] + broken)

    #expect(jev.results[happy]?.status == .yes && jev.results[sad]?.status == .no && jev.results[link]?.status == .unsettled)
    #expect(jev.results[sad]?.notes(tone: "Happy") == ["Doesn't fit Happy"])
    #expect(jev.results[busy]?.status == .yes)
    #expect(broken.allSatisfy { jev.results[$0] == nil })
    #expect(jev.failures[broken[0]] == "TypeSafe returned an error (HTTP 500).")
    #expect(jev.failures[broken[1]]?.hasPrefix("Couldn't reach TypeSafe.") == true)
    #expect(jev.failures[broken[2]] == "Unexpected reply from TypeSafe: no answer for fits_tone.")
    #expect(!jev.isChecking)
    // 7 lines and one retry; the tag-only line is never sent.
    #expect(typeSafe.requests.withLock { $0.count } == 8)
    let request = try #require(typeSafe.requests.withLock { $0.first })
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone" && request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ts_key")

    // Unchanged lines aren't sent again; a new tone is. Errors are retried.
    await jev.check([happy, sad, JevSubject(text: "We lost everything.", tone: "Sad")])
    #expect(typeSafe.requests.withLock { $0.count } == 9)
    await jev.check(broken)
    #expect(typeSafe.requests.withLock { $0.count } == 12)
}

@MainActor @Test func checkScriptReturnsAResultPerLine() async throws {
    let projects = ProjectStore(root: try tempFolder())
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let id = projects.create(name: "Film")
    projects.addLines(["We did it!", "", "We lost everything."], to: id, voices: voices)
    let lines = try #require(projects.project(id)?.lines)
    projects.propose(Proposal(text: "We lost it all.", tone: "Sad", pauseAfter: 0.5), line: lines[2].id, in: id)

    let off = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { id }
    #expect(await off.call("check_script", [:]) == ("Jev plugin not added", false))

    let typeSafe = FakeTypeSafe([
        "We did it!": [FakeTypeSafe.answers(["spoken": 0.96, "fits_tone": 0.91])],
        "We lost it all.": [FakeTypeSafe.answers(["spoken": 0.9, "fits_tone": 0.85, "keeps_meaning": 0.2])],
    ])
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys("k"), send: typeSafe.send)) { id }
    let result = await bridge.call("check_script", [:])
    #expect(!result.isError)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: Any]])
    #expect(json.count == 2)
    #expect(json[0]["line"] as? Int == 1 && json[0]["result"] as? String == "pass" && json[0]["spoken"] as? String == "yes")
    #expect(json[0]["notes"] == nil && json[0]["keeps_meaning"] == nil)
    #expect(json[1]["line"] as? Int == 3 && json[1]["result"] as? String == "fail" && json[1]["pending_change"] as? Bool == true)
    #expect(json[1]["keeps_meaning"] as? String == "no" && json[1]["notes"] as? [String] == ["Changes the original meaning"])
    // The meaning check sent the line's current text as the original, and nothing about voices or files.
    let sent = try #require(typeSafe.bodies.first { ($0["state"] as? [String: String])?["line"] == "We lost it all." })
    let meaning = (sent["questions"] as? [String: [String: Any]])?["keeps_meaning"]?["instructions"] as? [String: String]
    #expect(meaning?["original"] == "We lost everything.")

    // Every call failing is an error, not a set of answers.
    let down = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys("k"), send: FakeTypeSafe([:]).send)) { id }
    #expect(await down.call("check_script", [:]) == ("Jev check failed. TypeSafe returned an error (HTTP 404).", true))
}
