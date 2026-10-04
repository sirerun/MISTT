import Foundation

/// Per-source wire ledger. Sequence numbers start at one; sample indexes start
/// at zero, while capture offsets retain that source's initial delay after the
/// shared epoch.
struct PCMFrameLedger: Equatable {
    struct Entry: Equatable {
        let sequence: UInt64
        let startSample: UInt64
        let captureOffsetNanoseconds: UInt64
        let sampleCount: UInt32
    }

    let baseOffsetNanoseconds: UInt64
    private(set) var totalSamples: UInt64 = 0
    private(set) var nextSequence: UInt64 = 1

    mutating func accept(sampleCount: UInt32) throws -> Entry {
        guard (1...1600).contains(sampleCount) else { throw Failure.invalidSampleCount }
        let offset = try AudioSampleInstant.offsetNanoseconds(sampleIndex: totalSamples, rate: 16_000)
        let offsetSum = baseOffsetNanoseconds.addingReportingOverflow(offset)
        let nextTotal = totalSamples.addingReportingOverflow(UInt64(sampleCount))
        let nextSeq = nextSequence.addingReportingOverflow(1)
        guard !offsetSum.overflow, !nextTotal.overflow, !nextSeq.overflow else { throw Failure.overflow }
        let entry = Entry(sequence: nextSequence, startSample: totalSamples,
                          captureOffsetNanoseconds: offsetSum.partialValue, sampleCount: sampleCount)
        totalSamples = nextTotal.partialValue
        nextSequence = nextSeq.partialValue
        return entry
    }

    var lastSequence: UInt64 { nextSequence - 1 }
    private enum Failure: Error { case invalidSampleCount, overflow }
}
