# Bounded rollover terminal diagnostics

The native-global cut calculation is unchanged. The offline coordinator regression
feeds real paired100ms frames through110/220/330second cuts and checks every
native frame, remote-local end total and continuation origin. It does not qualify
model word continuity or establish the cause of a runtime stop.

`mistt run --redacted-rollover-diagnostics` is explicitly opt-in. It sends one
versioned JSON terminal diagnostic through an eight-record nonblocking channel to
stderr. No public status, native IPC, transcript protocol or UI detail changes.
Fields are fixed stage/cause enums and numeric sequence/cut/paired sample totals.
Known validator errors map by exact equality, wrapped errors are examined only to
eight levels, and WebSocket close text is discarded in favor of a fixed close
class. Unknown errors become unclassified; arbitrary error/transcript/audio,
credential values and native identifiers are never emitted. An unread/full sink
cannot delay capture closure.

Qualification driver mode diagnostic is fixed240seconds with two110second cuts.
Only this mode passes the diagnostic flag. It is not fifteen-minute transport or
semantic qualification. The driver strictly validates diagnostic fields against
its enum vocabulary, captures the first cause before cleanup errors, counts
canonical gRPC stderr codes under a64KiB inspection budget, and continues draining
stderr thereafter. After native stop it waits at most10seconds for the public
terminal record before terminating owned processes. It retains pre/post cleanup
exit codes and numeric lifecycle information, not arbitrary stderr/error bodies.
The existing optional fixed-fictional hypothesis-retention contract is unchanged;
diagnostic receipts themselves contain no hypothesis text.

A word crossing a reset may still be lost despite perfect PCM delivery: a fresh
encoder/decoder state cannot recover missing phonemes from a text join. A future
explicit semantic/model-state handoff needs separate design, fixed cache ownership,
pre-finalization state custody, budget/counter audits and mid-word qualification.
No overlap, state transfer, cap increase, model or boundary algorithm change is
part of this checkpoint. Any new ASR run requires exact owner-reviewed source,
Linux artifact and bounded execution preview approval.

## Successor ownership regression

The real supervisor regression exposed two concurrent `runPair` owners after a
successful continuous handoff: `rotatePair` started a goroutine for the successor,
then returned to `supervise`, which synchronously started that same successor.
Each owner could consume the other's first cut frame while advancing a shared
native ledger. This explains a valid global clock with an invalid per-owner cut
cursor; it is not evidence for changing the clock or weakening cursor validation.

The minimal correction leaves successor execution exclusively to `supervise`;
`rolloverPair` already installs `s.active`. The regression observes backend event
ownership before allowing either owner to consume a frame. It fails against the
old source with two owners, passes ten race-enabled repetitions with the fix,
and verifies bounded mute/native closure and supervisor shutdown after handoff.
A timer/entry barrier prevents the fixture from consuming frames before the first
cut is planned. No public protocol, sample mapping, model, cap or native UI change
is involved. Real240second and900second qualification remain separate owner gates.
