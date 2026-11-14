import Foundation
import Observation

/// Zeno's news, in the same JSON the Pi already sends the Zeno 64 TV (zeno-tv-link.md, v1).
struct Feed: Codable, Equatable {
    var v: Int
    var sent: String?
    var items: [Item]?
    var ticker: [String]?
    var live_call: LiveCall?

    struct Item: Codable, Equatable, Hashable {
        var kind: String
        var title: String
        var detail: String?
        var at: String?
    }

    struct LiveCall: Codable, Equatable {
        var to: String
        var state: String          // ringing | live | ended
        var lines: [Line]?
    }

    struct Line: Codable, Equatable, Hashable {
        var who: String            // zeno | them
        var text: String
    }

    static let empty = Feed(v: 1, items: [], ticker: [], live_call: nil)
}

/// Holds the latest feed and survives restarts.
@MainActor @Observable
final class FeedStore {
    private(set) var feed: Feed
    private(set) var receivedAt: Date?

    private static let feedKey = "feed"
    private static let receivedKey = "feedReceivedAt"

    init() {
        let defaults = UserDefaults.standard
        feed = defaults.data(forKey: Self.feedKey)
            .flatMap { try? JSONDecoder().decode(Feed.self, from: $0) } ?? .empty
        receivedAt = defaults.object(forKey: Self.receivedKey) as? Date
    }

    /// Returns false when the body isn't a v1 feed.
    func accept(_ data: Data) -> Bool {
        guard var new = try? JSONDecoder().decode(Feed.self, from: data), new.v == 1 else { return false }
        new.items = Array((new.items ?? []).prefix(8))
        new.ticker = Array((new.ticker ?? []).prefix(6))
        if let lines = new.live_call?.lines { new.live_call?.lines = Array(lines.suffix(6)) }
        feed = new
        receivedAt = .now
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(new), forKey: Self.feedKey)
        defaults.set(receivedAt, forKey: Self.receivedKey)
        return true
    }

    /// The call to show at `now`, with the TV's expiry rules: a ringing or live call with no
    /// new feed for 20 s is dead, and an ended call leaves the screen after 30 s.
    func activeCall(at now: Date) -> Feed.LiveCall? {
        guard let call = feed.live_call, let receivedAt else { return nil }
        let quiet = now.timeIntervalSince(receivedAt)
        switch call.state {
        case "ringing", "live": return quiet < 20 ? call : nil
        case "ended": return quiet < 30 ? call : nil
        default: return nil
        }
    }
}
