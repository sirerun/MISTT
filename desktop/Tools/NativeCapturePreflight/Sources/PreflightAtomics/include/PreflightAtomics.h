#ifndef MISTT_PREFLIGHT_ATOMICS_H
#define MISTT_PREFLIGHT_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct MISTTAtomicCapture MISTTAtomicCapture;
typedef void (*MISTTPreCommitHook)(void *context);

typedef struct {
    uint64_t buffers;
    uint64_t frames;
    uint64_t clipped_or_dropped_frames;
    uint64_t invalid_timestamps;
    uint64_t first_offset_ns;
    uint64_t last_offset_ns;
    uint64_t maximum_anchor_gap_ns;
    uint64_t maximum_callback_ns;
    uint64_t callback_overruns;
} MISTTSourceSnapshot;

enum { MISTT_ENERGY_RING_CAPACITY = 256 };
typedef struct {
    uint32_t count;
    uint64_t overflow;
    uint16_t levels[MISTT_ENERGY_RING_CAPACITY];
} MISTTEnergyBatch;

enum {
    MISTT_FAILURE_NONE = 0,
    MISTT_FAILURE_INVALID_TIMESTAMP = 1,
    MISTT_FAILURE_BACKWARDS_TIMESTAMP = 2,
    MISTT_FAILURE_NEGATIVE_OFFSET = 3,
    MISTT_FAILURE_CALLBACK_OVERLAP = 4
};

MISTTAtomicCapture *MISTTCreateCaptureState(void);
void MISTTDestroyCaptureState(MISTTAtomicCapture *state);
void MISTTResetCaptureState(MISTTAtomicCapture *state);
void MISTTOpenCaptureGate(MISTTAtomicCapture *state, uint64_t epoch_ns);
void MISTTCloseCaptureGate(MISTTAtomicCapture *state, uint64_t cutoff_ns);
bool MISTTCaptureGateIsOpen(const MISTTAtomicCapture *state);
int32_t MISTTRecordBuffer(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                          uint64_t start_ns, uint64_t frame_count, double sample_rate);
// Deterministic interleave seam for tests. Production callbacks use RecordBuffer.
int32_t MISTTRecordBufferWithTestHook(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                                     uint64_t start_ns, uint64_t frame_count, double sample_rate,
                                     MISTTPreCommitHook hook, void *context);
uint32_t MISTTFirstFailure(const MISTTAtomicCapture *state);
void MISTTReadSource(const MISTTAtomicCapture *state, uint32_t source, MISTTSourceSnapshot *out);
bool MISTTEnqueueEnergy(MISTTAtomicCapture *state, uint32_t source, uint64_t start_ns, uint64_t end_ns, uint16_t rms_level);
void MISTTDrainEnergy(MISTTAtomicCapture *state, uint32_t source, MISTTEnergyBatch *out);
uint16_t MISTTEnergyBatchLevel(const MISTTEnergyBatch *batch, uint32_t index);
void MISTTRecordCallbackDuration(MISTTAtomicCapture *state, uint32_t source, uint64_t duration_ns, uint64_t overrun_threshold_ns);

#endif
