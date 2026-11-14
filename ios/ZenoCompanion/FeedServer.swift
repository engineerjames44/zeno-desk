import Foundation
import Network

/// A tiny HTTP server on the phone: the Pi pushes Zeno's feed with POST /feed.
/// The Pi's firewall stays closed, the same as with the TV: the Pi always starts the connection.
@MainActor
final class FeedServer {
    static let port: NWEndpoint.Port = 8080
    nonisolated static let maxBody = 8 * 1024
    /// Only these senders may change what's on screen: the addresses in ZENO_FEED_SENDERS (the Pi, and
    /// a Mac for testing; set in Local.xcconfig, kept out of git), plus the phone itself, which also
    /// covers the Simulator on the Mac.
    static let allowedSenders: Set<String> = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "ZenoFeedSenders") as? String ?? ""
        return Set(configured.split(separator: " ").map(String.init)).union(["127.0.0.1", "::1"])
    }()

    private let store: FeedStore
    private var listener: NWListener?
    /// Set by the desk view, for the dashboard's training-data recorder.
    var recorder: GestureRecorder?
    /// Set by the desk view, for the dashboard's live hand skeleton.
    var gestures: HandGestures?

    init(store: FeedStore) { self.store = store }

    func start() {
        guard listener == nil, let listener = try? NWListener(using: .tcp, on: Self.port) else { return }
        listener.service = NWListener.Service(name: "Zeno Desk", type: "_zenodesk._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            // Restart after a network change kills the listener.
            if case .failed = state {
                MainActor.assumeIsolated {
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.start()
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > Self.maxBody + 4096 { return self.reply(connection, 413, "too big") }

                switch Request.parse(buffer) {
                case .incomplete where !done && error == nil:
                    self.receive(connection, buffer: buffer)
                case .complete(let request):
                    self.respond(to: request, from: connection)
                default:
                    self.reply(connection, 400, "bad request")
                }
            }
        }
    }

    private func respond(to request: Request, from connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              Self.allowedSenders.contains(Self.address(host)) else {
            return reply(connection, 403, "not allowed")
        }
        #if DEBUG
        // Heat tests from the Mac dashboard: POST /stress?on=1 or ?on=0. Debug builds only.
        if request.method == "POST", request.path.hasPrefix("/stress") {
            if request.path.hasSuffix("on=1") { Stress.start() } else if request.path.hasSuffix("on=0") { Stress.stop() }
            return reply(connection, 200, Stress.running ? "stress on" : "stress off")
        }
        // Training data for the gesture model, driven from the Mac dashboard:
        //   POST /record?label=swipe_left&secs=10   start (3-2-1 countdown on the phone first)
        //   POST /record                              current state
        //   POST /recordings                          list of saved recordings
        //   POST /recfile?name=swipe_left/x.csv       one recording's CSV
        let url = URLComponents(string: request.path)
        let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if request.method == "POST", url?.path == "/record", let recorder {
            if let label = query["label"], let secs = Int(query["secs"] ?? "") { recorder.start(label: label, seconds: secs) }
            if query["cancel"] == "1" { recorder.cancel() }
            let state: String = switch recorder.state {
            case .idle: "idle"
            case .countingDown(let label, let left): "\(label) in \(left)"
            case .recording(let label, _): "recording \(label)"
            }
            let body: [String: Any] = ["state": state, "last_saved": recorder.lastSaved ?? NSNull(),
                                       "count": GestureRecorder.list().count]
            return replyJSON(connection, String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self))
        }
        // Live hand points for the dashboard (numbers only, never the image), same columns as a recording.
        if request.method == "POST", url?.path == "/hand", let gestures {
            let body: [String: Any] = ["columns": GestureRecorder.header.split(separator: ",").dropFirst().map(String.init),
                                       "values": gestures.latestFeatures.map { Double($0) },
                                       "running": gestures.running]
            return replyJSON(connection, String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self))
        }
        if request.method == "POST", url?.path == "/recordings" {
            return replyJSON(connection, String(decoding: (try? JSONSerialization.data(withJSONObject: GestureRecorder.list())) ?? Data("[]".utf8), as: UTF8.self))
        }
        if request.method == "POST", url?.path == "/recfile" {
            guard let csv = query["name"].flatMap(GestureRecorder.file) else { return reply(connection, 404, "not found") }
            return replyText(connection, csv)
        }
        if request.method == "POST", request.path == "/metrics" {
            return replyJSON(connection, Metrics.json)
        }
        // A real LLM running on the phone: POST /llm?on=1 or ?on=0; plain POST /llm reports its state.
        if request.method == "POST", request.path.hasPrefix("/llm") {
            if request.path.hasSuffix("on=1") { LLMStress.start() } else if request.path.hasSuffix("on=0") { LLMStress.stop() }
            return replyJSON(connection, LLMStress.json)
        }
        #endif
        guard request.method == "POST", request.path == "/feed" else { return reply(connection, 404, "not found") }
        let ok = store.accept(request.body)
        reply(connection, ok ? 200 : 400, ok ? "ok" : "not a v1 feed")
    }

    private static func address(_ host: NWEndpoint.Host) -> String {
        // IPv4 senders can arrive as IPv4-mapped IPv6 ("::ffff:192.0.2.10").
        let text: String = switch host {
        case .ipv4(let a): "\(a)"
        case .ipv6(let a): "\(a)"
        case .name(let n, _): n
        @unknown default: ""
        }
        return text.replacingOccurrences(of: "::ffff:", with: "").components(separatedBy: "%").first ?? text
    }

    private func replyText(_ connection: NWConnection, _ body: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/csv\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func replyJSON(_ connection: NWConnection, _ body: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func reply(_ connection: NWConnection, _ code: Int, _ text: String) {
        let body = "{\"ok\":\(code == 200),\"message\":\"\(text)\"}"
        let head = "HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Just enough HTTP/1.1 to read one request with a Content-Length body.
private struct Request {
    var method: String
    var path: String
    var body: Data

    enum Parse { case incomplete, complete(Request), invalid }

    static func parse(_ data: Data) -> Parse {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .invalid }

        var length = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
            }
        }
        guard (0...FeedServer.maxBody).contains(length) else { return .invalid }
        let body = data[split.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(Request(method: String(first[0]), path: String(first[1]), body: Data(body.prefix(length))))
    }
}
