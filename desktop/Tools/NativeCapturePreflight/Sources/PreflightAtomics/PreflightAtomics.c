#include "PreflightAtomics.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sched.h>
#include <limits.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "preflight callback atomics must be lock-free");

typedef struct { uint64_t start_ns, end_ns; uint16_t level; } EnergyEntry;

typedef struct {
    _Atomic uint64_t buffers;
    _Atomic uint64_t frames;
    _Atomic uint64_t clipped;
    _Atomic uint64_t invalid;
    _Atomic uint64_t first_offset;
    _Atomic uint64_t last_offset;
    _Atomic uint64_t last_sample_offset;
    _Atomic uint64_t max_gap;
    _Atomic uint64_t max_overlap;
    long double expected_next_offset_ns;
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
        uint64_t before_first, before_last, before_last_sample, before_max_gap, before_max_overlap;
        long double before_expected_next_offset_ns;
    } latest;
} SourceMetrics;

typedef enum {
    CAPTURE_PHASE_INITIAL = 0,
    CAPTURE_PHASE_OPENING = 1,
    CAPTURE_PHASE_OPEN = 2,
    CAPTURE_PHASE_CLOSED = 3
} CapturePhase;

struct MISTTAtomicCapture {
    _Atomic uint32_t phase;
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
    atomic_store_explicit(&state->phase, CAPTURE_PHASE_CLOSED, memory_order_release);
}

static void atomic_min_u64(_Atomic uint64_t *value, uint64_t candidate) {
    uint64_t current = atomic_load_explicit(value, memory_order_relaxed);
    while (candidate < current &&
           !atomic_compare_exchange_weak_explicit(value, &current, candidate,
                                                  memory_order_seq_cst, memory_order_relaxed)) {
    }
}

static bool try_add_counter(_Atomic uint64_t *counter, uint64_t amount) {
    uint64_t current = atomic_load_explicit(counter, memory_order_relaxed);
    for (;;) {
        if (amount > UINT64_MAX - current) return false;
        if (atomic_compare_exchange_weak_explicit(counter, &current, current + amount,
                                                  memory_order_relaxed, memory_order_relaxed)) return true;
    }
}

static bool rounded_frame_offset(uint64_t frames, long double frame_ns, uint64_t *out) {
    long double value = (long double)frames * frame_ns;
    // All callers enforce the buffer bound, but keep the conversion checked at
    // the boundary where floating point becomes an integer timestamp.
    if (!isfinite(value) || value < 0.0L || value >= 0x1p64L) return false;
    long double rounded = roundl(value);
    if (rounded < 0.0L || rounded >= 0x1p64L) return false;
    *out = (uint64_t)rounded;
    return true;
}

static bool checked_add_u64(uint64_t left, uint64_t right, uint64_t *out) {
    if (right > UINT64_MAX - left) return false;
    *out = left + right;
    return true;
}

// Return the first frame index whose nearest-nanosecond sample instant is at
// or after boundary_ns. This is conservative at a fractional-ns edge: it may
// clip a pre-cutoff sample that rounds to the cutoff, but cannot retain one
// whose actual instant is at or after the integer-ns cutoff.
static bool first_frame_at_or_after(uint64_t boundary_ns, long double frame_ns,
                                    uint64_t frame_count, uint64_t *out) {
    if (boundary_ns == 0) { *out = 0; return true; }
    long double estimate = ceill((long double)boundary_ns / frame_ns);
    if (!isfinite(estimate) || estimate < 0.0L) return false;
    uint64_t index = estimate >= (long double)frame_count ? frame_count : (uint64_t)estimate;
    uint64_t anchor = 0;
    while (index > 0) {
        if (!rounded_frame_offset(index - 1, frame_ns, &anchor)) return false;
        if (anchor < boundary_ns) break;
        --index;
    }
    while (index < frame_count) {
        if (!rounded_frame_offset(index, frame_ns, &anchor)) return false;
        if (anchor >= boundary_ns) break;
        ++index;
    }
    *out = index;
    return true;
}

static bool counter_can_add(_Atomic uint64_t *counter, uint64_t amount) {
    return amount <= UINT64_MAX - atomic_load_explicit(counter, memory_order_relaxed);
}

static void update_max(_Atomic uint64_t *counter, uint64_t value) {
    uint64_t old = atomic_load_explicit(counter, memory_order_relaxed);
    while (value > old && !atomic_compare_exchange_weak_explicit(counter, &old, value,
                                                                  memory_order_relaxed, memory_order_relaxed)) {}
}

// Called with this source's callback_lock held. Validate the entire transaction
// before changing counters so a failure cannot leave partially-accounted PCM.
static int32_t commit_buffer_locked(MISTTAtomicCapture *state, SourceMetrics *m,
                                    uint64_t start_ns, uint64_t frame_count,
                                    long double frame_ns, uint64_t first, uint64_t last) {
    if (first > frame_count) first = frame_count;
    if (last > frame_count) last = frame_count;
    uint64_t retained = last > first ? last - first : 0;
    uint64_t clipped_add = frame_count - retained;
    if (retained == 0) {
        if (!counter_can_add(&m->clipped, clipped_add)) {
            m->latest.valid = false;
            fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
            return MISTT_FAILURE_COUNTER_OVERFLOW;
        }
        atomic_fetch_add_explicit(&m->clipped, clipped_add, memory_order_relaxed);
        return 0;
    }

    uint64_t first_delta, first_ns;
    if (!rounded_frame_offset(first, frame_ns, &first_delta) ||
        !checked_add_u64(start_ns, first_delta, &first_ns)) {
        m->latest.valid = false;
        fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
        return MISTT_FAILURE_COUNTER_OVERFLOW;
    }
    uint64_t epoch = atomic_load_explicit(&state->epoch_ns, memory_order_relaxed);
    if (first_ns < epoch) {
        if (!counter_can_add(&m->invalid, 1)) {
            m->latest.valid = false;
            fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
            return MISTT_FAILURE_COUNTER_OVERFLOW;
        }
        atomic_fetch_add_explicit(&m->invalid, 1, memory_order_relaxed);
        m->latest.valid = false;
        fail_once(state, MISTT_FAILURE_NEGATIVE_OFFSET);
        return MISTT_FAILURE_NEGATIVE_OFFSET;
    }

    uint64_t offset = first_ns - epoch;
    uint64_t last_index = first + retained - 1;
    uint64_t last_delta, last_ns;
    if (!rounded_frame_offset(last_index, frame_ns, &last_delta) ||
        !checked_add_u64(start_ns, last_delta, &last_ns) || last_ns < epoch) {
        m->latest.valid = false;
        fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
        return MISTT_FAILURE_COUNTER_OVERFLOW;
    }
    uint64_t last_sample_offset = last_ns - epoch;

    uint64_t previous_sample_offset = atomic_load_explicit(&m->last_sample_offset, memory_order_relaxed);
    long double next_expected_offset = (long double)offset + (long double)retained * frame_ns;
    if (!isfinite(next_expected_offset) || next_expected_offset >= 0x1p64L) {
        m->latest.valid = false;
        fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
        return MISTT_FAILURE_COUNTER_OVERFLOW;
    }

    if (previous_sample_offset != UINT64_MAX) {
        long double residual = (long double)offset - m->expected_next_offset_ns;
        if (!isfinite(residual) || fabsl(residual) >= 0x1p64L) {
            m->latest.valid = false;
            fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
            return MISTT_FAILURE_COUNTER_OVERFLOW;
        }
        uint64_t gap = residual > 0.0L ? (uint64_t)ceill(residual) : 0;
        uint64_t overlap = residual < 0.0L ? (uint64_t)ceill(-residual) : 0;
        update_max(&m->max_gap, gap);
        update_max(&m->max_overlap, overlap);

        // Host timestamps can drift from the nominal ASBD line. Reject only
        // a repeated or backward sample anchor; preserve line residuals above.
        if (offset <= previous_sample_offset) {
            if (!counter_can_add(&m->clipped, frame_count)) {
                m->latest.valid = false;
                fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
                return MISTT_FAILURE_COUNTER_OVERFLOW;
            }
            atomic_fetch_add_explicit(&m->clipped, frame_count, memory_order_relaxed);
            m->latest.valid = false;
            fail_once(state, MISTT_FAILURE_BUFFER_OVERLAP);
            return MISTT_FAILURE_BUFFER_OVERLAP;
        }
    }

    if (!counter_can_add(&m->clipped, clipped_add) ||
        !counter_can_add(&m->buffers, 1) ||
        !counter_can_add(&m->frames, retained)) {
        m->latest.valid = false;
        fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
        return MISTT_FAILURE_COUNTER_OVERFLOW;
    }
    atomic_fetch_add_explicit(&m->clipped, clipped_add, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->buffers, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->frames, retained, memory_order_relaxed);
    uint64_t expected_first = UINT64_MAX;
    atomic_compare_exchange_strong_explicit(&m->first_offset, &expected_first, offset,
                                            memory_order_relaxed, memory_order_relaxed);
    atomic_store_explicit(&m->last_offset, offset, memory_order_relaxed);
    atomic_store_explicit(&m->last_sample_offset, last_sample_offset, memory_order_relaxed);
    m->expected_next_offset_ns = next_expected_offset;
    return 0;
}

MISTTAtomicCapture *MISTTCreateCaptureState(void) {
    MISTTAtomicCapture *state = calloc(1, sizeof(*state));
    if (state == NULL) return NULL;
    atomic_init(&state->phase, CAPTURE_PHASE_INITIAL);
    atomic_init(&state->epoch_ns, 0);
    atomic_init(&state->open_ns, 0);
    atomic_init(&state->cutoff_ns, UINT64_MAX);
    atomic_init(&state->first_failure, MISTT_FAILURE_NONE);
    for (uint32_t i = 0; i < 2; ++i) {
        SourceMetrics *m = &state->source[i];
        atomic_init(&m->buffers, 0);
        atomic_init(&m->frames, 0);
        atomic_init(&m->clipped, 0);
        atomic_init(&m->invalid, 0);
        atomic_init(&m->first_offset, UINT64_MAX);
        atomic_init(&m->last_offset, UINT64_MAX);
        atomic_init(&m->last_sample_offset, UINT64_MAX);
        atomic_init(&m->max_gap, 0);
        atomic_init(&m->max_overlap, 0);
        atomic_init(&m->max_callback_ns, 0);
        atomic_init(&m->callback_overruns, 0);
        atomic_init(&m->energy_head, 0);
        atomic_init(&m->energy_tail, 0);
        atomic_init(&m->energy_overflow, 0);
        atomic_flag_clear(&m->callback_lock);
        m->expected_next_offset_ns = 0.0L;
        m->latest.valid = false;
    }
    return state;
}

void MISTTDestroyCaptureState(MISTTAtomicCapture *state) { free(state); }

void MISTTResetCaptureState(MISTTAtomicCapture *state) {
    // Capture state is single-use. Keep this ABI-compatible entry point inert:
    // a retired generation must never clear its cutoff or counters.
    (void)state;
}

void MISTTOpenCaptureGate(MISTTAtomicCapture *state, uint64_t epoch_ns) {
    if (state == NULL) return;
    uint32_t expected = CAPTURE_PHASE_INITIAL;
    if (!atomic_compare_exchange_strong_explicit(&state->phase, &expected, CAPTURE_PHASE_OPENING,
                                                 memory_order_acq_rel, memory_order_acquire)) return;
    atomic_store_explicit(&state->epoch_ns, epoch_ns, memory_order_relaxed);
    atomic_store_explicit(&state->open_ns, epoch_ns, memory_order_relaxed);
    expected = CAPTURE_PHASE_OPENING;
    atomic_compare_exchange_strong_explicit(&state->phase, &expected, CAPTURE_PHASE_OPEN,
                                            memory_order_acq_rel, memory_order_acquire);
}

void MISTTCloseCaptureGate(MISTTAtomicCapture *state, uint64_t cutoff_ns) {
    if (state == NULL) return;
    atomic_store_explicit(&state->phase, CAPTURE_PHASE_CLOSED, memory_order_seq_cst);
    atomic_min_u64(&state->cutoff_ns, cutoff_ns);
    for (size_t i = 0; i < 2; ++i) {
        SourceMetrics *m = &state->source[i];
        while (atomic_flag_test_and_set_explicit(&m->callback_lock, memory_order_acquire)) sched_yield();
        const uint64_t effective_cutoff = atomic_load_explicit(&state->cutoff_ns, memory_order_seq_cst);
        if (m->latest.valid) {
            atomic_store_explicit(&m->buffers, m->latest.before_buffers, memory_order_relaxed);
            atomic_store_explicit(&m->frames, m->latest.before_frames, memory_order_relaxed);
            atomic_store_explicit(&m->clipped, m->latest.before_clipped, memory_order_relaxed);
            atomic_store_explicit(&m->first_offset, m->latest.before_first, memory_order_relaxed);
            atomic_store_explicit(&m->last_offset, m->latest.before_last, memory_order_relaxed);
            atomic_store_explicit(&m->last_sample_offset, m->latest.before_last_sample, memory_order_relaxed);
            m->expected_next_offset_ns = m->latest.before_expected_next_offset_ns;
            atomic_store_explicit(&m->max_gap, m->latest.before_max_gap, memory_order_relaxed);
            atomic_store_explicit(&m->max_overlap, m->latest.before_max_overlap, memory_order_relaxed);

            uint64_t open_ns = atomic_load_explicit(&state->open_ns, memory_order_relaxed);
            long double frame_ns = 1000000000.0L / (long double)m->latest.sample_rate;
            uint64_t first = 0, last = 0;
            bool valid = true;
            if (m->latest.start_ns < open_ns)
                valid = first_frame_at_or_after(open_ns - m->latest.start_ns, frame_ns,
                                                m->latest.frame_count, &first);
            if (valid && effective_cutoff > m->latest.start_ns)
                valid = first_frame_at_or_after(effective_cutoff - m->latest.start_ns, frame_ns,
                                                m->latest.frame_count, &last);
            if (valid)
                (void)commit_buffer_locked(state, m, m->latest.start_ns, m->latest.frame_count,
                                           frame_ns, first, last);
            else
                fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
            // Keep the rollback record so a repeated close with an earlier
            // cutoff can only trim this final buffer further.
        }
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
    }
}

bool MISTTCaptureGateIsOpen(const MISTTAtomicCapture *state) {
    return state != NULL && atomic_load_explicit(&state->phase, memory_order_acquire) == CAPTURE_PHASE_OPEN;
}

static int32_t record_buffer(MISTTAtomicCapture *state, uint32_t source, bool host_time_valid,
                             uint64_t start_ns, uint64_t frame_count, double sample_rate,
                             MISTTPreCommitHook hook, void *context) {
    if (state == NULL) return -1;
    if (source > 1) {
        fail_once(state, MISTT_FAILURE_INVALID_BUFFER);
        return MISTT_FAILURE_INVALID_BUFFER;
    }
    if (frame_count == 0 || frame_count > MISTT_MAX_FRAMES_PER_BUFFER ||
        !isfinite(sample_rate) || sample_rate < MISTT_MIN_SAMPLE_RATE_HZ ||
        sample_rate > MISTT_MAX_SAMPLE_RATE_HZ ||
        (long double)frame_count > (long double)sample_rate * MISTT_MAX_CALLBACK_DURATION_SECONDS) {
        fail_once(state, MISTT_FAILURE_INVALID_BUFFER);
        return MISTT_FAILURE_INVALID_BUFFER;
    }
    if (!MISTTCaptureGateIsOpen(state)) return 0;
    SourceMetrics *m = &state->source[source];
    // Core Audio callbacks never wait on another callback or control work. A
    // same-source overlap is unexpected; fail the pair closed instead.
    if (atomic_flag_test_and_set_explicit(&m->callback_lock, memory_order_acquire)) {
        fail_once(state, MISTT_FAILURE_CALLBACK_OVERLAP);
        return MISTT_FAILURE_CALLBACK_OVERLAP;
    }
    if (!MISTTCaptureGateIsOpen(state)) {
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return 0;
    }
    if (!host_time_valid || start_ns == 0) {
        if (!try_add_counter(&m->invalid, 1)) {
            fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
            atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
            return MISTT_FAILURE_COUNTER_OVERFLOW;
        }
        fail_once(state, MISTT_FAILURE_INVALID_TIMESTAMP);
        atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
        return MISTT_FAILURE_INVALID_TIMESTAMP;
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
    m->latest.before_last_sample = atomic_load_explicit(&m->last_sample_offset, memory_order_relaxed);
    m->latest.before_expected_next_offset_ns = m->expected_next_offset_ns;
    m->latest.before_max_gap = atomic_load_explicit(&m->max_gap, memory_order_relaxed);
    m->latest.before_max_overlap = atomic_load_explicit(&m->max_overlap, memory_order_relaxed);

    uint64_t open_ns = atomic_load_explicit(&state->open_ns, memory_order_relaxed);
    uint64_t stop_ns = atomic_load_explicit(&state->cutoff_ns, memory_order_relaxed);
    if (hook != NULL) hook(context);
    long double frame_ns = 1000000000.0L / (long double)sample_rate;
    uint64_t first = 0;
    uint64_t last = frame_count;
    bool valid = true;
    if (start_ns < open_ns)
        valid = first_frame_at_or_after(open_ns - start_ns, frame_ns, frame_count, &first);
    if (valid && stop_ns != UINT64_MAX) {
        last = 0;
        if (stop_ns > start_ns)
            valid = first_frame_at_or_after(stop_ns - start_ns, frame_ns, frame_count, &last);
    }
    int32_t result;
    if (valid) {
        result = commit_buffer_locked(state, m, start_ns, frame_count, frame_ns, first, last);
    } else {
        m->latest.valid = false;
        fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
        result = MISTT_FAILURE_COUNTER_OVERFLOW;
    }
    atomic_flag_clear_explicit(&m->callback_lock, memory_order_release);
    return result;
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
    out->maximum_anchor_overlap_ns = atomic_load_explicit(&m->max_overlap, memory_order_relaxed);
    out->maximum_callback_ns = atomic_load_explicit(&m->max_callback_ns, memory_order_relaxed);
    out->callback_overruns = atomic_load_explicit(&m->callback_overruns, memory_order_relaxed);
}

bool MISTTEnqueueEnergy(MISTTAtomicCapture *state, uint32_t source, uint64_t start_ns, uint64_t end_ns, uint16_t rms_level) {
    if (state == NULL || source > 1 || start_ns == 0 || end_ns < start_ns) return false;
    SourceMetrics *m = &state->source[source];
    if (atomic_flag_test_and_set_explicit(&m->callback_lock, memory_order_acquire)) {
        if (!try_add_counter(&m->energy_overflow, 1)) fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
        return false;
    }
    if (!MISTTCaptureGateIsOpen(state)) {
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
        if (!try_add_counter(&m->energy_overflow, 1)) fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
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
    if (duration_ns > overrun_threshold_ns && !try_add_counter(&m->callback_overruns, 1))
        fail_once(state, MISTT_FAILURE_COUNTER_OVERFLOW);
}
