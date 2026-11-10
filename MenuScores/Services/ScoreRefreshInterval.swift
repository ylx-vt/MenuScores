/// Stored values remain compatible with earlier settings, including intervals
/// no longer offered by the picker. Unknown values keep the 15-second default.
enum ScoreRefreshInterval {
    static func seconds(for value: String) -> UInt64 {
        switch value {
        case "10 seconds": return 10
        case "20 seconds": return 20
        case "30 seconds": return 30
        case "40 seconds": return 40
        case "50 seconds": return 50
        case "1 minute": return 60
        case "2 minutes": return 120
        case "5 minutes": return 300
        default: return 15
        }
    }
}
