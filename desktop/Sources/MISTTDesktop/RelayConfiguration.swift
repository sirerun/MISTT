import Darwin
import Foundation

struct RelayConfiguration {
    static let environmentKeys: Set<String> = [
        "MISTT_LISTEN", "MISTT_DGX_ENDPOINT", "MISTT_TOKEN_FILE", "MISTT_CA_FILE",
        "MISTT_LANGUAGE", "MISTT_MICROPHONE_DEVICE", "MISTT_TARGET_BUNDLE_ID",
        "MISTT_HELPER_PIDS", "MISTT_HELPER_EXECUTABLES", "MISTT_STARTUP_TIMEOUT",
        "MISTT_DRAIN_TIMEOUT", "MISTT_MAX_DURATION", "MISTT_CLIENT_BUFFER", "MISTT_FRAME_QUEUE",
    ]

    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("MISTT/config.json")
    }

    static func configuredURL(environment: [String: String], fileManager: FileManager = .default) -> URL {
        guard let override = environment["MISTT_CONFIG"], !override.isEmpty else {
            return defaultURL(fileManager: fileManager)
        }
        return URL(fileURLWithPath: override).standardizedFileURL
    }

    static func load(from url: URL) throws -> [String: String] {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ConfigurationError.unavailable }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ConfigurationError.unavailable
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size <= 16_384,
              metadata.st_uid == geteuid(), (metadata.st_mode & 0o077) == 0 else {
            throw ConfigurationError.insecurePermissions
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw ConfigurationError.unavailable }
            if count == 0 { break }
            guard data.count + count <= 16_384 else { throw ConfigurationError.malformed }
            data.append(contentsOf: chunk.prefix(count))
        }
        guard (try? StrictJSONValidator.validate(data)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ConfigurationError.malformed
        }
        guard dictionary.keys.allSatisfy(environmentKeys.contains) else {
            throw ConfigurationError.unknownKey
        }
        var result = [String: String]()
        for (key, value) in dictionary {
            guard let string = value as? String, !string.isEmpty,
                  !string.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ConfigurationError.invalidValue
            }
            result[key] = string
        }
        return result
    }

    enum ConfigurationError: Error {
        case unavailable
        case insecurePermissions
        case malformed
        case unknownKey
        case invalidValue
    }
}
