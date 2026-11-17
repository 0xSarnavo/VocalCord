import Foundation
import Security

/// One line as Jev checks it, and the cache key for its result: the text and tone to judge (a pending change's, if any)
/// and the text an agent's rewrite replaced. Bracketed tags such as [pause 0.5] and [breath] are left out: they are
/// directions to the engine, not words.
struct JevSubject: Hashable, Sendable {
    var text: String
    var tone: String
    var original: String?

    init(text: String, tone: String, original: String? = nil) {
        self.text = Self.words(text)
        self.tone = tone
        let original = original.map(Self.words)
        self.original = original == self.text || original?.isEmpty == true ? nil : original
    }

    init(_ line: Line) {
        guard let proposal = line.proposal else {
            self.init(text: line.text, tone: line.tone, original: line.original)
            return
        }
        self.init(text: proposal.text, tone: proposal.tone, original: proposal.text == line.text ? line.original : line.text)
    }

    static func words(_ text: String) -> String {
        text.replacing(/\[[^\]]*\]/, with: " ").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Jev's answers for one line, each the probability that the check passes.
struct JevResult: Hashable, Sendable {
    var model: String
    var answers: [JevQuestions.Check: Double]

    var verdicts: [(check: JevQuestions.Check, verdict: Verdict)] {
        JevQuestions.Check.allCases.compactMap { check in answers[check].map { (check, JevQuestions.verdict($0)) } }
    }

    /// A line fails when any check fails, is unsettled when none fails but one is unsettled, and passes otherwise.
    var status: Verdict {
        let all = verdicts.map(\.verdict)
        return all.contains(.no) ? .no : all.contains(.unsettled) ? .unsettled : .yes
    }

    /// The checks that didn't pass; when all passed, every check.
    func notes(tone: String) -> [String] {
        let open = verdicts.filter { $0.verdict != .yes }
        return (open.isEmpty ? verdicts : open).map { JevQuestions.note($0.check, $0.verdict, tone: tone) }
    }
}

/// The Jev plugin: the API key's presence, and each line's checks. Results are kept per `JevSubject`, so a line is
/// sent again only once its text, tone or original changes. Failed calls are kept apart as errors, never as answers.
@MainActor @Observable
final class Jev {
    private(set) var added: Bool
    private(set) var results: [JevSubject: JevResult] = [:]
    private(set) var failures: [JevSubject: String] = [:]
    private(set) var checking: Set<JevSubject> = []
    var isChecking: Bool { !checking.isEmpty }

    @ObservationIgnored private let keys: any KeyStore
    @ObservationIgnored private let send: TypeSafe.Send
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(keys: any KeyStore = Keychain(), send: @escaping TypeSafe.Send = TypeSafe.urlSession) {
        self.keys = keys
        self.send = send
        added = keys.exists
    }

    /// Saves the key once a cheap call (listing models) accepts it.
    func add(key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw AppError("Paste a TypeSafe API key.") }
        try await TypeSafe.listModels(key: key, send: send)
        try keys.save(key)
        added = true
    }

    func remove() throws {
        try keys.delete()
        added = false
        results = [:]
        failures = [:]
    }

    /// Checks each subject without a result yet, a few at a time. A check already running finishes first.
    func check(_ subjects: [JevSubject]) async {
        let previous = queue
        let task = Task {
            await previous?.value
            await run(subjects)
        }
        queue = task
        await task.value
    }

    private static let parallel = 4

    private func run(_ subjects: [JevSubject]) async {
        var waiting = Array(Set(subjects.filter { !$0.text.isEmpty && results[$0] == nil }))[...]
        guard !waiting.isEmpty else { return }
        for subject in waiting { failures[subject] = nil }
        guard added, let key = keys.read() else {
            for subject in waiting { failures[subject] = "No API key. Add Jev again in Settings." }
            return
        }
        checking.formUnion(waiting)
        let send = send
        await withTaskGroup(of: (JevSubject, Result<JevResult, any Error>).self) { group in
            func start(_ subject: JevSubject) {
                group.addTask {
                    do { return (subject, .success(try await TypeSafe.check(subject, key: key, send: send))) } catch { return (subject, .failure(error)) }
                }
            }
            for _ in 0..<Self.parallel { if let subject = waiting.popFirst() { start(subject) } }
            for await (subject, result) in group {
                checking.remove(subject)
                switch result {
                case .success(let result): results[subject] = result
                case .failure(let error): failures[subject] = error.localizedDescription
                }
                if let next = waiting.popFirst() { start(next) }
            }
        }
    }
}

/// TypeSafe's HTTP API (https://docs.typesafe.ai/api). Only the key goes in a header; it is never logged.
enum TypeSafe {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let api = URL(string: "https://api.typesafe.ai/v1/")!
    /// Ephemeral, so no response is cached on disk.
    static let urlSession: Send = { try await session.data(for: $0) }
    private static let session = URLSession(configuration: .ephemeral)

    private struct Models: Decodable { var models: [Model]; struct Model: Decodable { var name: String } }

    private struct Reply: Decodable {
        var model: String
        var answers: [String: Answer]
        struct Answer: Decodable { var type: String; var noul: Double? }
    }

    static func listModels(key: String, send: Send) async throws {
        let data = try await call(URLRequest(url: api.appending(path: "models")), key: key, send: send)
        guard (try? JSONDecoder().decode(Models.self, from: data)) != nil else { throw AppError("Unexpected reply from TypeSafe.") }
    }

    static func check(_ subject: JevSubject, key: String, send: Send) async throws -> JevResult {
        var request = URLRequest(url: api.appending(path: "systemone"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: JevQuestions.body(subject), options: [.sortedKeys, .withoutEscapingSlashes])
        request.httpBody = body
        #if DEBUG
        print("Jev request: POST \(request.url!.absoluteString) \(String(decoding: body, as: UTF8.self))")
        #endif
        let data = try await call(request, key: key, send: send)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw AppError("Unexpected reply from TypeSafe.") }
        var answers: [JevQuestions.Check: Double] = [:]
        for check in JevQuestions.checks(subject) {
            guard let noul = reply.answers[check.rawValue]?.noul, (0...1).contains(noul) else {
                throw AppError("Unexpected reply from TypeSafe: no answer for \(check.rawValue).")
            }
            answers[check] = noul
        }
        return JevResult(model: reply.model, answers: answers)
    }

    /// Sends a request with the key; retries twice when TypeSafe is rate-limited or overloaded.
    static func call(_ request: URLRequest, key: String, send: Send) async throws -> Data {
        var request = request
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        var attempt = 0
        while true {
            attempt += 1
            let data: Data, response: URLResponse
            do { (data, response) = try await send(request) } catch is CancellationError { throw CancellationError() } catch {
                throw AppError("Couldn't reach TypeSafe. \(error.localizedDescription)")
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            #if DEBUG
            if status != 200 { print("TypeSafe \(status): \(String(decoding: data.prefix(2000), as: UTF8.self))") }
            #endif
            switch status {
            case 200: return data
            case 401: throw AppError("TypeSafe didn't accept the API key.")
            case 429, 529:
                guard attempt < 3 else { throw AppError("TypeSafe is busy. Try again in a moment.") }
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt)
                try await Task.sleep(for: .seconds(min(max(wait, 0), 10)))
            default: throw AppError("TypeSafe returned an error (HTTP \(status)).")
            }
        }
    }
}

/// Where the API key lives.
protocol KeyStore: Sendable {
    /// Checks for the key without reading it, so it never asks for Keychain access.
    var exists: Bool { get }
    func read() -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// The key as a generic password in the login Keychain. Never written to files or logs.
struct Keychain: KeyStore {
    var service = "VocalCord Jev"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "TypeSafe API key"]
    }

    var exists: Bool { SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }

    func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        SecItemDelete(query as CFDictionary)
        var query = query
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError("Couldn't save the key to the Keychain. \(Self.message(status))") }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError("Couldn't remove the key from the Keychain. \(Self.message(status))")
        }
    }

    private static func message(_ status: OSStatus) -> String { SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)." }
}
