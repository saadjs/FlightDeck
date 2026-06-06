import Common
import Foundation

let flightdeckConfigDotfileName = ".flightdeck.toml"
let aerospaceConfigDotfileName = ".aerospace.toml"

// Dotfile used when FlightDeck creates a brand-new config from scratch (menu bar "Open config").
let configDotfileName = flightdeckConfigDotfileName

func findCustomConfigUrl() -> ConfigFile {
    if let configLocation = serverArgs.configLocation {
        return matchConfigCandidates([URL(filePath: configLocation)])
    }
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/")
    let home = FileManager.default.homeDirectoryForCurrentUser
    // FlightDeck config takes precedence over AeroSpace config in every supported location.
    // The two tiers are checked in order; the first tier that has any config wins.
    let tiers: [[URL]] = [
        [
            home.appending(path: flightdeckConfigDotfileName),
            xdgConfigHome.appending(path: "flightdeck").appending(path: "flightdeck.toml"),
        ],
        [
            home.appending(path: aerospaceConfigDotfileName),
            xdgConfigHome.appending(path: "aerospace").appending(path: "aerospace.toml"),
        ],
    ]
    for tier in tiers {
        switch matchConfigCandidates(tier) {
            case .noCustomConfigExists: continue
            case let result: return result
        }
    }
    return .noCustomConfigExists
}

private func matchConfigCandidates(_ candidates: [URL]) -> ConfigFile {
    let existingCandidates: [URL] = candidates.filter { (candidate: URL) in FileManager.default.fileExists(atPath: candidate.path) }
    return switch existingCandidates.count {
        case 0: .noCustomConfigExists
        case 1: .file(existingCandidates.first.orDie())
        default: .ambiguousConfigError(existingCandidates)
    }
}

enum ConfigFile {
    case file(URL), ambiguousConfigError(_ candidates: [URL]), noCustomConfigExists

    var urlOrNil: URL? {
        return switch self {
            case .file(let url): url
            case .ambiguousConfigError, .noCustomConfigExists: nil
        }
    }
}
