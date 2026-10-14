import Foundation
import Darwin
import MISTTConversation

@MainActor final class MediaProcess {
    private let media = ConversationMedia()
    private var binding: String?
    init() { media.onEvent = { [weak self] in self?.event($0) } }
    func emit(_ value: [String: Any]) {
        do {
            var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            bytes.append(10)
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch { media.stop(); exit(74) }
    }
    func receipt(_ value: PlaybackReceipt) -> [String: Any] {
        ["generation": value.generation, "rendered_samples": value.renderedSamples, "sample_rate": value.sampleRate, "token": value.token, "state": value.state]
    }
    func event(_ event: MediaEvent) {
        switch event {
        case let .audio(sessionID, sequence, sample, bytes): emit(["type": "audio", "session_id": sessionID, "sequence": sequence, "start_sample": sample, "pcm16": bytes.base64EncodedString()])
        case let .speechStarted(sample): emit(["type": "speech_started", "capture_sample": sample])
        case let .speechStopped(sample): emit(["type": "speech_stopped", "capture_sample": sample])
        case let .wake(start, end): emit(["type": "wake", "start_sample": start, "end_sample": end])
        case .urgentStop: emit(["type": "urgent_stop"])
        case let .playback(value): emit(["type": "playback", "receipt": receipt(value)])
        case let .failure(detail): emit(["type": "failure", "detail": detail])
        case let .state(state): emit(["type": "state", "state": state])
        }
    }
    func command(_ bytes: Data) async {
        var id = ""
        do {
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let requestID = value["id"] as? String, !requestID.isEmpty, let command = value["command"] as? String else { throw MediaError.unavailable("command and request id required") }
            id = requestID
            let generation = (value["generation"] as? NSNumber)?.uint64Value ?? 0
            let token = value["token"] as? String ?? ""
            let sessionID = value["session_id"] as? String
            if ["audio", "pause", "resume", "flush", "receipt", "drain"].contains(command), binding == nil || sessionID != binding { throw MediaError.unavailable("stale media session binding") }
            var result: PlaybackReceipt?
            switch command {
            case "arm": try await media.arm(); binding = nil
            case "start":
                guard let sessionID else { throw MediaError.unavailable("session_id required") }
                try await media.start(sessionID: sessionID); binding = sessionID
            case "mute": media.mute(); binding = nil
            case "stop": media.stop(); binding = nil
            case "audio":
                guard let encoded = value["pcm16"] as? String, let pcm = Data(base64Encoded: encoded), let rate = value["sample_rate"] as? Int else { throw MediaError.invalidAudio }
                try await media.enqueueWhenReady(generation: generation, pcm16: pcm, sampleRate: rate)
                result = media.currentReceipt()
            case "pause": result = try media.pause(generation: generation, token: token)
            case "resume": result = try media.resume(generation: generation, token: token)
            case "flush": result = media.flush(generation: generation)
            case "receipt": result = media.currentReceipt()
            case "drain": result = try await media.drain(generation: generation)
            default: throw MediaError.unavailable("unknown media command")
            }
            var reply: [String: Any] = ["type": "reply", "id": id, "ok": true]
            if let result { reply["receipt"] = receipt(result) }
            emit(reply)
        } catch { emit(["type": "reply", "id": id, "ok": false, "error": String(describing: error)]) }
    }
    func finish() { media.stop(); exit(0) }
}

let process = MainActor.assumeIsolated { MediaProcess() }
DispatchQueue.global(qos: .userInitiated).async {
    var pending = Data()
    let permits = DispatchSemaphore(value: 16)
    while true {
        let chunk: Data
        do { chunk = try FileHandle.standardInput.read(upToCount: 4096) ?? Data() }
        catch { exit(74) }
        if chunk.isEmpty { Task { @MainActor in process.finish() }; return }
        pending.append(chunk)
        if pending.count > 131072 { exit(65) }
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            // Bound command ingress but allow local capture/urgent stop callbacks
            // while an admitted playback command waits for capacity.
            permits.wait()
            Task { @MainActor in await process.command(line); permits.signal() }
        }
    }
}
RunLoop.main.run()
