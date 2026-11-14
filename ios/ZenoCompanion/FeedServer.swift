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
