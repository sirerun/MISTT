#include "PreflightAtomics.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "preflight callback atomics must be lock-free");

typedef struct {
    _Atomic uint64_t buffers;
    _Atomic uint64_t frames;
    _Atomic uint64_t clipped;
    _Atomic uint64_t invalid;
    _Atomic uint64_t first_offset;
    _Atomic uint64_t last_offset;
    _Atomic uint64_t max_gap;
    _Atomic uint64_t last_start;
    _Atomic uint64_t last_frames;
} SourceMetrics;

struct MISTTAtomicCapture {
    _Atomic bool gate_open;
    _Atomic uint64_t epoch_ns;
    _Atomic uint64_t open_ns;
    _Atomic uint64_t cutoff_ns;
    _Atomic uint32_t first_failure;
    SourceMetrics source[2];
};

static void fail_once(MISTTAtomicCapture *state, uint32_t reason) {
    uint32_t expected = MISTT_FAILURE_NONE;
    atomic_compare_exchange_strong_explicit(&state->first_failure, &expected, reason,
                                            memory_order_acq_rel, memory_order_relaxed);
    atomic_store_explicit(&state->gate_open, false, memory_order_release);
}

MISTTAtomicCapture *MISTTCreateCaptureState(void) {
    MISTTAtomicCapture *state = calloc(1, sizeof(*state));
    if (state == NULL) return NULL;
    MISTTResetCaptureState(state);
    return state;
}

void MISTTDestroyCaptureState(MISTTAtomicCapture *state) { free(state); }

void MISTTResetCaptureState(MISTTAtomicCapture *state) {
    if (state == NULL) return;
    atomic_store_explicit(&state->gate_open, false, memory_order_release);
    atomic_store_explicit(&state->epoch_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&state->open_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&state->cutoff_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&state->first_failure, MISTT_FAILURE_NONE, memory_order_relaxed);
    for (uint32_t i = 0; i < 2; ++i) {
        SourceMetrics *m = &state->source[i];
        atomic_store_explicit(&m->buffers, 0, memory_order_relaxed);
        atomic_store_explicit(&m->frames, 0, memory_order_relaxed);
        atomic_store_explicit(&m->clipped, 0, memory_order_relaxed);
        atomic_store_explicit(&m->invalid, 0, memory_order_relaxed);
        atomic_store_explicit(&m->first_offset, UINT64_MAX, memory_order_relaxed);
        atomic_store_explicit(&m->last_offset, UINT64_MAX, memory_order_relaxed);
        atomic_store_explicit(&m->max_gap, 0, memory_order_relaxed);
        atomic_store_explicit(&m->last_start, 0, memory_order_relaxed);
        atomic_store_explicit(&m->last_frames, 0, memory_order_relaxed);
    }
}

void MISTTOpenCaptureGate(MISTTAtomicCapture *state, uint64_t epoch_ns) {
    atomic_store_explicit(&state->epoch_ns, epoch_ns, memory_order_relaxed);
    atomic_store_explicit(&state->open_ns, epoch_ns, memory_order_relaxed);
    atomic_store_explicit(&state->cutoff_ns, UINT64_MAX, memory_order_relaxed);
    atomic_store_explicit(&state->gate_open, true, memory_order_release);
}

void MISTTCloseCaptureGate(MISTTAtomicCapture *state, uint64_t cutoff_ns) {
    atomic_store_explicit(&state->cutoff_ns, cutoff_ns, memory_order_relaxed);
    atomic_store_explicit(&state->gate_open, false, memory_order_release);
}

bool MISTTCaptureGateIsOpen(const MISTTAtomicCapture *state) {
    return atomic_load_explicit(&state->gate_open, memory_order_acquire);
}

int32_t MISTTRecordBuffer(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                          uint64_t start_ns, uint64_t frame_count, double sample_rate) {
    if (source > 1 || frame_count == 0 || !isfinite(sample_rate) || sample_rate <= 0) return -1;
    if (!atomic_load_explicit(&state->gate_open, memory_order_acquire)) return 0;
    SourceMetrics *m = &state->source[source];
    if (!host_time_valid || start_ns == 0) {
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        fail_once(state, MISTT_FAILURE_INVALID_TIMESTAMP);
        return MISTT_FAILURE_INVALID_TIMESTAMP;
    }
    uint64_t previous = atomic_exchange_explicit(&m->last_start, start_ns, memory_order_relaxed);
    if (previous != 0 && start_ns < previous) {
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        fail_once(state, MISTT_FAILURE_BACKWARDS_TIMESTAMP);
        return MISTT_FAILURE_BACKWARDS_TIMESTAMP;
    }

    uint64_t epoch = atomic_load_explicit(&state->epoch_ns, memory_order_relaxed);
    uint64_t open_ns = atomic_load_explicit(&state->open_ns, memory_order_relaxed);
    uint64_t stop_ns = atomic_load_explicit(&state->cutoff_ns, memory_order_relaxed);
    double frame_ns = 1000000000.0 / sample_rate;
    uint64_t first = 0;
    if (start_ns < open_ns) first = (uint64_t)ceil((double)(open_ns - start_ns) / frame_ns);
    uint64_t last = frame_count;
    if (stop_ns != UINT64_MAX) {
        if (stop_ns <= start_ns) last = 0;
        else {
            uint64_t before_stop = (uint64_t)floor((double)(stop_ns - start_ns) / frame_ns);
            if (before_stop < last) last = before_stop;
        }
    }
    if (first > frame_count) first = frame_count;
    if (last > frame_count) last = frame_count;
    uint64_t retained = last > first ? last - first : 0;
    atomic_fetch_add_explicit(&m->clipped, frame_count - retained, memory_order_relaxed);
    if (retained == 0) return 0;

    uint64_t first_ns = start_ns + (uint64_t)llround((double)first * frame_ns);
    if (first_ns < epoch) {
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        fail_once(state, MISTT_FAILURE_NEGATIVE_OFFSET);
        return MISTT_FAILURE_NEGATIVE_OFFSET;
    }
    uint64_t offset = first_ns - epoch;
    uint64_t expected_first = UINT64_MAX;
    atomic_compare_exchange_strong_explicit(&m->first_offset, &expected_first, offset,
                                            memory_order_relaxed, memory_order_relaxed);
    uint64_t previous_offset = atomic_exchange_explicit(&m->last_offset, offset, memory_order_relaxed);
    uint64_t previous_frames = atomic_exchange_explicit(&m->last_frames, retained, memory_order_relaxed);
    if (previous_offset != UINT64_MAX) {
        uint64_t expected_gap = (uint64_t)llround((double)previous_frames * frame_ns);
        uint64_t actual_gap = offset > previous_offset ? offset - previous_offset : 0;
        uint64_t gap = actual_gap > expected_gap ? actual_gap - expected_gap : 0;
        uint64_t old_max = atomic_load_explicit(&m->max_gap, memory_order_relaxed);
        while (gap > old_max && !atomic_compare_exchange_weak_explicit(&m->max_gap, &old_max, gap,
                                                                        memory_order_relaxed, memory_order_relaxed)) {}
    }
    atomic_fetch_add_explicit(&m->buffers, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->frames, retained, memory_order_relaxed);
    return 0;
}

uint32_t MISTTFirstFailure(const MISTTAtomicCapture *state) {
    return atomic_load_explicit(&state->first_failure, memory_order_acquire);
}

void MISTTReadSource(const MISTTAtomicCapture *state, uint32_t source, MISTTSourceSnapshot *out) {
    if (state == NULL || out == NULL || source > 1) return;
    const SourceMetrics *m = &state->source[source];
    out->buffers = atomic_load_explicit(&m->buffers, memory_order_relaxed);
    out->frames = atomic_load_explicit(&m->frames, memory_order_relaxed);
    out->clipped_or_dropped_frames = atomic_load_explicit(&m->clipped, memory_order_relaxed);
    out->invalid_timestamps = atomic_load_explicit(&m->invalid, memory_order_relaxed);
    out->first_offset_ns = atomic_load_explicit(&m->first_offset, memory_order_relaxed);
    out->last_offset_ns = atomic_load_explicit(&m->last_offset, memory_order_relaxed);
    out->maximum_anchor_gap_ns = atomic_load_explicit(&m->max_gap, memory_order_relaxed);
}
