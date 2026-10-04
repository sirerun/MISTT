import CoreAudio
import Darwin

struct HostClock: Sendable {
    let epochTicks: UInt64
    let epochNanoseconds: UInt64
    private let convert: @Sendable (UInt64) -> UInt64

    static var timebaseDescription: String {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return "Unavailable" }
        return "\(info.numer)/\(info.denom) ns/tick"
    }

    init(epochTicks: UInt64, convert: @escaping @Sendable (UInt64) -> UInt64 = AudioConvertHostTimeToNanos) {
        self.epochTicks = epochTicks
        self.convert = convert
        self.epochNanoseconds = convert(epochTicks)
    }

    func nanoseconds(for ticks: UInt64) -> UInt64 {
        convert(ticks)
    }

    func offsetNanoseconds(for ticks: UInt64) -> Int64? {
        let anchor = convert(ticks)
        guard anchor >= epochNanoseconds else { return nil }
        let difference = anchor - epochNanoseconds
        guard difference <= UInt64(Int64.max) else { return nil }
        return Int64(difference)
    }

    func elapsedNanoseconds(from startTicks: UInt64, to endTicks: UInt64) -> Int64? {
        let start = convert(startTicks)
        let end = convert(endTicks)
        guard end >= start, end - start <= UInt64(Int64.max) else { return nil }
        return Int64(end - start)
    }
}

struct PairedCutoff: Sendable, Equatable {
    let ticks: UInt64
    let nanoseconds: UInt64

    init(ticks: UInt64, clock: HostClock) {
        self.ticks = ticks
        self.nanoseconds = clock.nanoseconds(for: ticks)
    }

    static func now() -> PairedCutoff {
        let ticks = AudioGetCurrentHostTime()
        return PairedCutoff(ticks: ticks, clock: HostClock(epochTicks: ticks))
    }

    static func retainedRange(
        bufferStartNanoseconds: UInt64,
        frameCount: Int,
        sampleRate: Double,
        gateOpenNanoseconds: UInt64,
        stopNanoseconds: UInt64?
    ) -> Range<Int> {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return 0..<0 }
        let frameDuration = 1_000_000_000 / sampleRate
        let lowerDelta = gateOpenNanoseconds > bufferStartNanoseconds
            ? Double(gateOpenNanoseconds - bufferStartNanoseconds)
            : 0
        let first = min(frameCount, max(0, Int((lowerDelta / frameDuration).rounded(.up))))
        let last: Int
        if let stopNanoseconds {
            guard stopNanoseconds > bufferStartNanoseconds else { return 0..<0 }
            let upperDelta = Double(stopNanoseconds - bufferStartNanoseconds)
            // Frames are retained only when their sample anchor is strictly
            // before the stop instant; fractional frame durations therefore ceil.
            last = min(frameCount, max(0, Int((upperDelta / frameDuration).rounded(.up))))
        } else {
            last = frameCount
        }
        guard last > first else { return 0..<0 }
        return first..<last
    }
}

enum CaptureGatePublication {
    static func publishBeforeLock(
        cutoff: PairedCutoff,
        closeGate: (PairedCutoff) -> Void,
        acquireLifecycleLock: () -> Void
    ) {
        closeGate(cutoff)
        acquireLifecycleLock()
    }
}

struct PairedGate: Sendable {
    private(set) var isOpen = false
    private(set) var cutoff: PairedCutoff?

    mutating func open() { isOpen = true; cutoff = nil }
    mutating func close(at cutoff: PairedCutoff) { isOpen = false; self.cutoff = cutoff }
}
