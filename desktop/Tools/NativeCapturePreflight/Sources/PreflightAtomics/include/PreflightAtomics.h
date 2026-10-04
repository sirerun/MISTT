#ifndef MISTT_PREFLIGHT_ATOMICS_H
#define MISTT_PREFLIGHT_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct MISTTAtomicCapture MISTTAtomicCapture;

typedef struct {
    uint64_t buffers;
    uint64_t frames;
    uint64_t clipped_or_dropped_frames;
    uint64_t invalid_timestamps;
    uint64_t first_offset_ns;
    uint64_t last_offset_ns;
    uint64_t maximum_anchor_gap_ns;
} MISTTSourceSnapshot;

enum {
    MISTT_FAILURE_NONE = 0,
    MISTT_FAILURE_INVALID_TIMESTAMP = 1,
    MISTT_FAILURE_BACKWARDS_TIMESTAMP = 2,
    MISTT_FAILURE_NEGATIVE_OFFSET = 3
};

MISTTAtomicCapture *MISTTCreateCaptureState(void);
void MISTTDestroyCaptureState(MISTTAtomicCapture *state);
void MISTTResetCaptureState(MISTTAtomicCapture *state);
void MISTTOpenCaptureGate(MISTTAtomicCapture *state, uint64_t epoch_ns);
void MISTTCloseCaptureGate(MISTTAtomicCapture *state, uint64_t cutoff_ns);
bool MISTTCaptureGateIsOpen(const MISTTAtomicCapture *state);
int32_t MISTTRecordBuffer(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                          uint64_t start_ns, uint64_t frame_count, double sample_rate);
uint32_t MISTTFirstFailure(const MISTTAtomicCapture *state);
void MISTTReadSource(const MISTTAtomicCapture *state, uint32_t source, MISTTSourceSnapshot *out);

#endif
