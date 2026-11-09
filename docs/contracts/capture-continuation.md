# Public paired capture continuation, version 1

`SessionStarted.capture_continuation` is optional. Absence preserves legacy
session-reset behavior. Version 1 is a native-ledger attestation by the trusted
configured MISTT producer; metadata does not independently authenticate capture
cryptographically. It is neither ASR semantic finality nor a speech/turn boundary.

The producer emits it only for opt-in paired-v2 rollover, after both old sources
completed successfully and terminal done released the old admission, and after
the successor negotiated v2 and retained PCM was queued using the validated
continuation mapping. Native IO has not stopped. Ordinary initial starts, v1
stop/restart, mute, failure, gap, overflow and unsettled transitions do not emit it.

| Field | Meaning |
| --- | --- |
| version | Exactly 1. Unknown versions cannot justify a fragment join. |
| previous_session_id | Immediate settled ASR predecessor, not an earlier hop. |
| native_session_id | Original physical native generation; stable across hops. |
| cutover_offset_ns | Common native-epoch-relative cut. |
| sources | Exactly microphone then call_audio, each with native-global first retained sample/offset. |

For each source, the producer verifies that the previous accepted remote sample
end plus its prior origin equals the successor's native-global start sample, and
that the corresponding native clock offsets agree. It also verifies actual
successor native PCM exists at that cursor. Source sample phase permits
`origin.capture_offset_ns` in `cutover_offset_ns + [0, 62500ns)`. Compare an old
transcript's final endpoint to its own source origin, not necessarily to the
common cut. The outer SessionStarted preserves the nonzero physical host/Unix
epoch tuple, model, language and exact canonical paired formats.

A silent source need not emit any transcript. Never manufacture microphone text
or wait for silent-source lexical output to establish physical continuity.
Consumers may use this attestation together with the successful predecessor
terminal, matching identities/formats/epochs, uninterrupted status, and available
call-prefix endpoint to retain a bounded unfinished question. They must invalidate
old assessments, reject malformed/replayed/mismatched proofs, preserve original
raw records, and never replay a completed question or silently truncate a fragment.
This contract does not promise that resetting an ASR model preserves word accuracy
across a cut; that still requires measured qualification.
