#include "PreflightAtomics.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sched.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "preflight callback atomics must be lock-free");

typedef struct { uint64_t start_ns, end_ns; uint16_t level; } EnergyEntry;

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
    _Atomic uint64_t max_callback_ns;
    _Atomic uint64_t callback_overruns;
    atomic_flag callback_lock;
    EnergyEntry energy_ring[MISTT_ENERGY_RING_CAPACITY];
    _Atomic uint32_t energy_head, energy_tail;
    _Atomic uint64_t energy_overflow;
    struct {
        bool valid;
        uint64_t start_ns, frame_count;
        double sample_rate;
        uint64_t before_buffers, before_frames, before_clipped;
        uint64_t before_first, before_last, before_last_frames, before_max_gap;
    } latest;
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
        atomic_store_explicit(&m->max_callback_ns, 0, memory_order_relaxed);
        atomic_store_explicit(&m->callback_overruns, 0, memory_order_relaxed);
        atomic_store_explicit(&m->energy_head, 0, memory_order_relaxed);
        atomic_store_explicit(&m->energy_tail, 0, memory_order_relaxed);
        atomic_store_explicit(&m->energy_overflow, 0, memory_order_relaxed);
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_relaxed);
        m->latest.valid = false;
    }
}

void MISTTOpenCaptureGate(MISTTAtomicCapture *state, uint64_t epoch_ns) {
    atomic_store_explicit(&state->epoch_ns, epoch_ns, memory_order_relaxed);
    atomic_store_explicit(&state->open_ns, epoch_ns, memory_order_relaxed);
    atomic_store_explicit(&state->cutoff_ns, UINT64_MAX, memory_order_relaxed);
    for (size_t i = 0; i < 2; ++i) state->source[i].latest.valid = false;
    atomic_store_explicit(&state->gate_open, true, memory_order_release);
}

void MISTTCloseCaptureGate(MISTTAtomicCapture *state, uint64_t cutoff_ns) {
    if (state == NULL) return;
    atomic_store_explicit(&state->cutoff_ns, cutoff_ns, memory_order_seq_cst);
    atomic_store_explicit(&state->gate_open, false, memory_order_seq_cst);
    for (size_t i = 0; i < 2; ++i) {
        SourceMetrics *m = &state->source[i];
        while (atomic_flag_test_and_set_explicit(&m->callback_lock, memory_order_acquire)) sched_yield();
        if (m->latest.valid) {
            atomic_store_explicit(&m->buffers, m->latest.before_buffers, memory_order_relaxed);
            atomic_store_explicit(&m->frames, m->latest.before_frames, memory_order_relaxed);
            atomic_store_explicit(&m->clipped, m->latest.before_clipped, memory_order_relaxed);
            atomic_store_explicit(&m->first_offset, m->latest.before_first, memory_order_relaxed);
            atomic_store_explicit(&m->last_offset, m->latest.before_last, memory_order_relaxed);
            atomic_store_explicit(&m->last_frames, m->latest.before_last_frames, memory_order_relaxed);
            atomic_store_explicit(&m->max_gap, m->latest.before_max_gap, memory_order_relaxed);

            uint64_t epoch = atomic_load_explicit(&state->epoch_ns, memory_order_relaxed);
            uint64_t open_ns = atomic_load_explicit(&state->open_ns, memory_order_relaxed);
            double frame_ns = 1000000000.0 / m->latest.sample_rate;
            uint64_t first = m->latest.start_ns < open_ns ?
                (uint64_t)ceil((double)(open_ns - m->latest.start_ns) / frame_ns) : 0;
            uint64_t last = m->latest.frame_count;
            if (cutoff_ns <= m->latest.start_ns) last = 0;
            else {
                uint64_t before_stop = (uint64_t)ceil((double)(cutoff_ns - m->latest.start_ns) / frame_ns);
                if (before_stop < last) last = before_stop;
            }
            if (first > m->latest.frame_count) first = m->latest.frame_count;
            if (last > m->latest.frame_count) last = m->latest.frame_count;
            uint64_t retained = last > first ? last - first : 0;
            atomic_fetch_add_explicit(&m->clipped, m->latest.frame_count - retained, memory_order_relaxed);
            if (retained > 0) {
                uint64_t first_ns = m->latest.start_ns + (uint64_t)llround((double)first * frame_ns);
                if (first_ns >= epoch) {
                    uint64_t offset = first_ns - epoch;
                    uint64_t previous_offset = atomic_exchange_explicit(&m->last_offset, offset, memory_order_relaxed);
                    uint64_t previous_frames = atomic_exchange_explicit(&m->last_frames, retained, memory_order_relaxed);
                    uint64_t expected_first = UINT64_MAX;
                    atomic_compare_exchange_strong_explicit(&m->first_offset, &expected_first, offset, memory_order_relaxed, memory_order_relaxed);
                    if (previous_offset != UINT64_MAX) {
                        uint64_t expected_gap = (uint64_t)llround((double)previous_frames * frame_ns);
                        uint64_t actual_gap = offset > previous_offset ? offset - previous_offset : 0;
                        uint64_t gap = actual_gap > expected_gap ? actual_gap - expected_gap : 0;
                        uint64_t old_max = atomic_load_explicit(&m->max_gap, memory_order_relaxed);
                        while (gap > old_max && !atomic_compare_exchange_weak_explicit(&m->max_gap, &old_max, gap, memory_order_relaxed, memory_order_relaxed)) {}
                    }
                    atomic_fetch_add_explicit(&m->buffers, 1, memory_order_relaxed);
                    atomic_fetch_add_explicit(&m->frames, retained, memory_order_relaxed);
                }
            }
            m->latest.valid = false;
        }
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
    }
}

bool MISTTCaptureGateIsOpen(const MISTTAtomicCapture *state) {
    return atomic_load_explicit(&state->gate_open, memory_order_acquire);
}

static int32_t record_buffer(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                             uint64_t start_ns, uint64_t frame_count, double sample_rate,
                             MISTTPreCommitHook hook, void *context) {
    if (source > 1 || frame_count == 0 || !isfinite(sample_rate) || sample_rate <= 0) return -1;
    if (!atomic_load_explicit(&state->gate_open, memory_order_acquire)) return 0;
    SourceMetrics *m = &state->source[source];
    // Core Audio callbacks never wait on another callback or control work. A
    // same-source overlap is unexpected; fail the pair closed instead.
    if (atomic_flag_test_and_set_explicit(&m->callback_lock, memory_order_acquire)) {
        fail_once(state, MISTT_FAILURE_CALLBACK_OVERLAP);
        return MISTT_FAILURE_CALLBACK_OVERLAP;
    }
    if (!atomic_load_explicit(&state->gate_open, memory_order_seq_cst)) {
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return 0;
    }
    if (!host_time_valid || start_ns == 0) {
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        fail_once(state, MISTT_FAILURE_INVALID_TIMESTAMP);
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return MISTT_FAILURE_INVALID_TIMESTAMP;
    }
    uint64_t previous = atomic_exchange_explicit(&m->last_start, start_ns, memory_order_relaxed);
    if (previous != 0 && start_ns < previous) {
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        fail_once(state, MISTT_FAILURE_BACKWARDS_TIMESTAMP);
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return MISTT_FAILURE_BACKWARDS_TIMESTAMP;
    }

    m->latest.valid = true;
    m->latest.start_ns = start_ns;
    m->latest.frame_count = frame_count;
    m->latest.sample_rate = sample_rate;
    m->latest.before_buffers = atomic_load_explicit(&m->buffers, memory_order_relaxed);
    m->latest.before_frames = atomic_load_explicit(&m->frames, memory_order_relaxed);
    m->latest.before_clipped = atomic_load_explicit(&m->clipped, memory_order_relaxed);
    m->latest.before_first = atomic_load_explicit(&m->first_offset, memory_order_relaxed);
    m->latest.before_last = atomic_load_explicit(&m->last_offset, memory_order_relaxed);
    m->latest.before_last_frames = atomic_load_explicit(&m->last_frames, memory_order_relaxed);
    m->latest.before_max_gap = atomic_load_explicit(&m->max_gap, memory_order_relaxed);

    uint64_t epoch = atomic_load_explicit(&state->epoch_ns, memory_order_relaxed);
    uint64_t open_ns = atomic_load_explicit(&state->open_ns, memory_order_relaxed);
    uint64_t stop_ns = atomic_load_explicit(&state->cutoff_ns, memory_order_relaxed);
    if (hook != NULL) hook(context);
    double frame_ns = 1000000000.0 / sample_rate;
    uint64_t first = 0;
    if (start_ns < open_ns) first = (uint64_t)ceil((double)(open_ns - start_ns) / frame_ns);
    uint64_t last = frame_count;
    if (stop_ns != UINT64_MAX) {
        if (stop_ns <= start_ns) last = 0;
        else {
            uint64_t before_stop = (uint64_t)ceil((double)(stop_ns - start_ns) / frame_ns);
            if (before_stop < last) last = before_stop;
        }
    }
    if (first > frame_count) first = frame_count;
    if (last > frame_count) last = frame_count;
    uint64_t retained = last > first ? last - first : 0;
    atomic_fetch_add_explicit(&m->clipped, frame_count - retained, memory_order_relaxed);
    if (retained == 0) {
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return 0;
    }

    uint64_t first_ns = start_ns + (uint64_t)llround((double)first * frame_ns);
    if (first_ns < epoch) {
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        fail_once(state, MISTT_FAILURE_NEGATIVE_OFFSET);
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
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
    atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
    return 0;
}

int32_t MISTTRecordBuffer(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                          uint64_t start_ns, uint64_t frame_count, double sample_rate) {
    return record_buffer(state, source, host_time_valid, start_ns, frame_count, sample_rate, NULL, NULL);
}

int32_t MISTTRecordBufferWithTestHook(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                                     uint64_t start_ns, uint64_t frame_count, double sample_rate,
                                     MISTTPreCommitHook hook, void *context) {
    return record_buffer(state, source, host_time_valid, start_ns, frame_count, sample_rate, hook, context);
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
    out->maximum_callback_ns = atomic_load_explicit(&m->max_callback_ns, memory_order_relaxed);
    out->callback_overruns = atomic_load_explicit(&m->callback_overruns, memory_order_relaxed);
}

bool MISTTEnqueueEnergy(MISTTAtomicCapture *state, uint32_t source, uint64_t start_ns, uint64_t end_ns, uint16_t rms_level) {
    if (state == NULL || source > 1 || start_ns == 0 || end_ns < start_ns) return false;
    SourceMetrics *m = &state->source[source];
    if (atomic_flag_test_and_set_explicit(&m->callback_lock, memory_order_acquire)) {
        atomic_fetch_add_explicit(&m->energy_overflow, 1, memory_order_relaxed);
        return false;
    }
    if (!atomic_load_explicit(&state->gate_open, memory_order_seq_cst)) {
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return false;
    }
    uint64_t cutoff = atomic_load_explicit(&state->cutoff_ns, memory_order_seq_cst);
    if (end_ns > cutoff) {
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return false;
    }
    uint32_t head = atomic_load_explicit(&m->energy_head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&m->energy_tail, memory_order_acquire);
    if ((uint32_t)(head - tail) >= MISTT_ENERGY_RING_CAPACITY) {
        atomic_fetch_add_explicit(&m->energy_overflow, 1, memory_order_relaxed);
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return false;
    }
    m->energy_ring[head & (MISTT_ENERGY_RING_CAPACITY - 1)] = (EnergyEntry){start_ns, end_ns, rms_level};
    atomic_store_explicit(&m->energy_head, head + 1, memory_order_release);
    atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
    return true;
}

void MISTTDrainEnergy(MISTTAtomicCapture *state, uint32_t source, MISTTEnergyBatch *out) {
    if (state == NULL || source > 1 || out == NULL) return;
    out->count = 0;
    out->overflow = 0;
    SourceMetrics *m = &state->source[source];
    uint32_t tail = atomic_load_explicit(&m->energy_tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&m->energy_head, memory_order_acquire);
    uint64_t cutoff = atomic_load_explicit(&state->cutoff_ns, memory_order_acquire);
    while (tail != head && out->count < MISTT_ENERGY_RING_CAPACITY) {
        EnergyEntry item = m->energy_ring[tail & (MISTT_ENERGY_RING_CAPACITY - 1)];
        if (item.end_ns <= cutoff) out->levels[out->count++] = item.level;
        ++tail;
    }
    atomic_store_explicit(&m->energy_tail, tail, memory_order_release);
    out->overflow = atomic_exchange_explicit(&m->energy_overflow, 0, memory_order_relaxed);
}

uint16_t MISTTEnergyBatchLevel(const MISTTEnergyBatch *batch, uint32_t index) {
    return batch != NULL && index < batch->count ? batch->levels[index] : 0;
}

void MISTTRecordCallbackDuration(MISTTAtomicCapture *state, uint32_t source, uint64_t duration_ns, uint64_t overrun_threshold_ns) {
    if (state == NULL || source > 1) return;
    SourceMetrics *m = &state->source[source];
    uint64_t previous = atomic_load_explicit(&m->max_callback_ns, memory_order_relaxed);
    while (duration_ns > previous &&
           !atomic_compare_exchange_weak_explicit(&m->max_callback_ns, &previous, duration_ns,
                                                  memory_order_relaxed, memory_order_relaxed)) {}
    if (duration_ns > overrun_threshold_ns) atomic_fetch_add_explicit(&m->callback_overruns, 1, memory_order_relaxed);
}
