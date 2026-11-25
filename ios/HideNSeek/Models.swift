import Foundation
import CoreLocation

enum Role: String, Codable {
    case unassigned, hider, seeker, referee
    var label: String { rawValue.capitalized }
}

struct LatLng: Codable, Equatable {
    var lat: Double
    var lng: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

struct GameSettings: Codable, Equatable {
    var durationMs: Double
    var headStartMs: Double
    var pingIntervalMs: Double
    var graceMs: Double
    var warnSeekers: Bool
    var darkHiderMs: Double
    var hiderSelfTag: Bool
    var center: LatLng?
    var radiusM: Double
    var allowLateJoin: Bool
    var lateJoinRole: String
    var chatEnabled: Bool
    var mediaEnabled: Bool
    var showTeamSpeed: Bool
    var seekersSeeEachOther: Bool
    var awards: Bool
}

struct Timing: Codable, Equatable {
    var startsAt: Double
    var huntStartsAt: Double
    var endsAt: Double
    var nextPingAt: Double
}

struct RosterEntry: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var color: String
    var role: Role
    var isLeader: Bool
    var connected: Bool
}

struct LivePos: Codable, Identifiable, Equatable {
    var id: String
    var lat: Double
    var lng: Double
    var speed: Double?
    var at: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

struct PingPos: Codable, Equatable {
    var id: String
    var lat: Double
    var lng: Double
    var at: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

struct PingMsg: Codable, Equatable {
    var seq: Int
    var at: Double
    var positions: [PingPos]
}

struct GameState: Codable {
    var serverTime: Double
    var epoch: Int
    var status: String // lobby | active | ended
    var role: Role
    var paused: Bool
    var timing: Timing
    var settings: GameSettings
    var roster: [RosterEntry]
    var hidersLeft: Int
    var live: [LivePos]
    var lastPing: PingMsg?
    var winner: String?
}

struct GameEventMsg: Codable, Identifiable {
    var type: String
    var at: Double
    var seq: Int?
    var playerId: String?
    var lat: Double?
    var lng: Double?
    var willConvert: Bool?
    var reason: String?
    var by: String?
    var winner: String?
    var id: String { "\(type)-\(at)-\(playerId ?? "")" }
}

struct ChatEnvelope: Codable {
    var id: String
    var channel: String
    var senderId: String
    var kind: String
    var body: String?
    var mediaId: String?
    var mime: String?
    var size: Double?
    var at: Double
}

/// A chat message as stored on this phone. Chat and media live only on the devices.
struct LocalMessage: Codable, Identifiable, Equatable {
    var id: String
    var channel: String // all | seekers | hiders
    var senderId: String
    var senderName: String
    var kind: String // text | photo | video | gif | system
    var body: String?
    var mime: String?
    var mediaFile: String? // file name inside the game's media folder
    var mediaId: String?
    var size: Double?
    var at: Double
    var mine: Bool
    var status: String // sending | sent | failed | pending | downloading | downloaded | expired
    var saved: Bool?
}

// MARK: Results

struct PlayerStats: Codable {
    var distanceM: Double
    var hiderDistanceM: Double
    var seekerDistanceM: Double
    var topSpeedMps: Double
    var avgMovingSpeedMps: Double
    var movingMs: Double
    var stillMs: Double
    var points: Int
}

struct PlayerResult: Codable, Identifiable {
    var id: String
    var name: String
    var color: String
    var startRole: Role
    var finalRole: Role
    var convertedAt: Double?
    var left: Bool
    var survivedMs: Double
    var tagsMade: Int
    var stats: PlayerStats
    var route: [[Double]] // [lat, lng, speed, t]
    var speedSeries: [[Double]] // [t, speed]
}

struct Award: Codable, Identifiable {
    var id: String
    var title: String
    var playerIds: [String]
    var value: Double?
}

struct Geofence: Codable {
    var center: LatLng
    var radiusM: Double
}

struct Results: Codable {
    var winner: String?
    var endReason: String?
    var startsAt: Double
    var huntStartsAt: Double
    var endsAt: Double
    var endedAt: Double
    var geofence: Geofence?
    var pings: [PingMsg]
    var events: [GameEventMsg]
    var players: [PlayerResult]
    var awards: [Award]
}

// MARK: Formatting

enum Fmt {
    static func speed(_ mps: Double, metric: Bool) -> String {
        metric ? String(format: "%.1f km/h", mps * 3.6) : String(format: "%.1f mph", mps * 2.23694)
    }
    static func dist(_ m: Double, metric: Bool) -> String {
        if metric { return m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m) }
        let ft = m * 3.28084
        return ft >= 1000 ? String(format: "%.2f mi", m / 1609.344) : String(format: "%.0f ft", ft)
    }
    static func clock(_ ms: Double) -> String {
        let s = max(0, Int((ms / 1000).rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    static func minutes(_ ms: Double) -> String {
        let m = ms / 60_000
        return m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m)
    }
    static func ago(_ ms: Double) -> String {
        let s = Int(max(0, ms) / 1000)
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }
}
