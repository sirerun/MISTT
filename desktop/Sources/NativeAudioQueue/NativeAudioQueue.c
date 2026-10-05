#include "NativeAudioQueue.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define NANOS_PER_SECOND UINT64_C(1000000000)
#define MAX_CHANNELS 2

typedef struct {
    _Atomic bool ready;
    MISTTAudioBlock metadata;
    float *samples;
} AudioSlot;

struct MISTTAudioQueue {
    uint32_t slot_count;
    uint32_t maximum_block_frames;
    AudioSlot *slots;
    float *storage;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint64_t pending_frames;
    _Atomic uint64_t gate_open_ns;
    _Atomic uint64_t cutoff_ns;
    _Atomic uint32_t established_rate;
    _Atomic uint32_t callbacks_in_flight;
    _Atomic bool gate_open;
    _Atomic bool overflow;
};

MISTTAudioQueue *MISTTAudioQueueCreate(uint32_t slot_count, uint32_t maximum_block_frames) {
    if (slot_count < 2 || maximum_block_frames == 0 || maximum_block_frames > 8192) return NULL;
    MISTTAudioQueue *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->slots = calloc(slot_count, sizeof(*q->slots));
    size_t sample_count = (size_t)slot_count * maximum_block_frames * MAX_CHANNELS;
    if (sample_count / MAX_CHANNELS / maximum_block_frames != slot_count) { free(q->slots); free(q); return NULL; }
    q->storage = calloc(sample_count, sizeof(float));
    if (!q->slots || !q->storage) { free(q->storage); free(q->slots); free(q); return NULL; }
    q->slot_count = slot_count;
    q->maximum_block_frames = maximum_block_frames;
    for (uint32_t i = 0; i < slot_count; i++) {
        q->slots[i].samples = q->storage + (size_t)i * maximum_block_frames * MAX_CHANNELS;
        atomic_init(&q->slots[i].ready, false);
    }
    atomic_init(&q->write_index, 0);
    atomic_init(&q->read_index, 0);
    atomic_init(&q->pending_frames, 0);
    atomic_init(&q->gate_open_ns, 0);
    atomic_init(&q->cutoff_ns, UINT64_MAX);
    atomic_init(&q->established_rate, 0);
    atomic_init(&q->callbacks_in_flight, 0);
    atomic_init(&q->gate_open, false);
    atomic_init(&q->overflow, false);
    return q;
}

void MISTTAudioQueueDestroy(MISTTAudioQueue *q) {
    if (!q) return;
    free(q->storage);
    free(q->slots);
    free(q);
}

void MISTTAudioQueueOpenGate(MISTTAudioQueue *q, uint64_t gate_open_ns) {
    if (!q) return;
    atomic_store_explicit(&q->cutoff_ns, UINT64_MAX, memory_order_relaxed);
    atomic_store_explicit(&q->gate_open_ns, gate_open_ns, memory_order_relaxed);
    atomic_store_explicit(&q->gate_open, true, memory_order_release);
}

void MISTTAudioQueueCloseGate(MISTTAudioQueue *q, uint64_t cutoff_ns) {
    if (!q) return;
    atomic_store_explicit(&q->cutoff_ns, cutoff_ns, memory_order_release);
    atomic_store_explicit(&q->gate_open, false, memory_order_release);
}

static uint64_t first_sample_at_or_after(uint64_t delta_ns, uint32_t rate) {
    __uint128_t scaled = (__uint128_t)delta_ns * rate;
    __uint128_t result = (scaled + NANOS_PER_SECOND - 1) / NANOS_PER_SECOND;
    return result > UINT64_MAX ? UINT64_MAX : (uint64_t)result;
}

bool MISTTAudioQueuePushFloat32(MISTTAudioQueue *q, const float *left, const float *right,
                                uint32_t frames, uint32_t channels, uint32_t sample_rate,
                                uint64_t host_start_ns) {
    if (!q || !left || frames == 0 || frames > q->maximum_block_frames ||
        channels == 0 || channels > MAX_CHANNELS || (channels == 2 && !right) ||
        sample_rate < 8000 || sample_rate > 384000) {
        if (q) atomic_store_explicit(&q->overflow, true, memory_order_release);
        return false;
    }
    atomic_fetch_add_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
    if (!atomic_load_explicit(&q->gate_open, memory_order_acquire)) {
        atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
        return true;
    }
    uint32_t expected_rate = 0;
    if (!atomic_compare_exchange_strong_explicit(&q->established_rate, &expected_rate, sample_rate,
                                                 memory_order_acq_rel, memory_order_acquire) && expected_rate != sample_rate) {
        atomic_store_explicit(&q->overflow, true, memory_order_release);
        atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
        return false;
    }
    uint64_t gate = atomic_load_explicit(&q->gate_open_ns, memory_order_acquire);
    uint64_t cutoff = atomic_load_explicit(&q->cutoff_ns, memory_order_acquire);
    uint32_t first = 0;
    if (gate > host_start_ns) {
        uint64_t offset = first_sample_at_or_after(gate - host_start_ns, sample_rate);
        first = offset > frames ? frames : (uint32_t)offset;
    }
    uint32_t last = frames;
    if (cutoff != UINT64_MAX) {
        if (cutoff <= host_start_ns) last = 0;
        else {
            uint64_t offset = first_sample_at_or_after(cutoff - host_start_ns, sample_rate);
            last = offset > frames ? frames : (uint32_t)offset;
        }
    }
    if (last <= first) {
        atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
        return true;
    }
    uint32_t kept = last - first;
    uint64_t pending = atomic_load_explicit(&q->pending_frames, memory_order_relaxed);
    if (pending > sample_rate || kept > sample_rate - pending) {
        atomic_store_explicit(&q->overflow, true, memory_order_release);
        atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
        return false;
    }
    uint64_t write = atomic_load_explicit(&q->write_index, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&q->read_index, memory_order_acquire);
    if (write - read >= q->slot_count) {
        atomic_store_explicit(&q->overflow, true, memory_order_release);
        atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
        return false;
    }
    atomic_fetch_add_explicit(&q->pending_frames, kept, memory_order_acq_rel);
    AudioSlot *slot = &q->slots[write % q->slot_count];
    if (channels == 1) {
        for (uint32_t i = 0; i < kept; i++) {
            slot->samples[i * 2] = left[first + i];
            slot->samples[i * 2 + 1] = left[first + i];
        }
    } else {
        for (uint32_t i = 0; i < kept; i++) {
            slot->samples[i * 2] = left[first + i];
            slot->samples[i * 2 + 1] = right[first + i];
        }
    }
    __uint128_t start_delta = (__uint128_t)first * NANOS_PER_SECOND / sample_rate;
    uint64_t start_ns = host_start_ns;
    if (start_delta > UINT64_MAX || UINT64_MAX - host_start_ns < (uint64_t)start_delta) {
        atomic_fetch_sub_explicit(&q->pending_frames, kept, memory_order_acq_rel);
        atomic_store_explicit(&q->overflow, true, memory_order_release);
        atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
        return false;
    }
    start_ns += (uint64_t)start_delta;
    slot->metadata = (MISTTAudioBlock){ .host_start_ns = start_ns, .sample_rate = sample_rate,
                                        .channels = channels, .frame_count = kept };
    atomic_store_explicit(&slot->ready, true, memory_order_release);
    atomic_store_explicit(&q->write_index, write + 1, memory_order_release);
    atomic_fetch_sub_explicit(&q->callbacks_in_flight, 1, memory_order_acq_rel);
    return true;
}

bool MISTTAudioQueuePop(MISTTAudioQueue *q, float *left, float *right,
                        uint32_t capacity, MISTTAudioBlock *block) {
    if (!q || !left || !right || !block) return false;
    for (;;) {
        uint64_t read = atomic_load_explicit(&q->read_index, memory_order_relaxed);
        uint64_t write = atomic_load_explicit(&q->write_index, memory_order_acquire);
        if (read == write) return false;
        AudioSlot *slot = &q->slots[read % q->slot_count];
        uint32_t stored_frames = slot->metadata.frame_count;
        if (!atomic_load_explicit(&slot->ready, memory_order_acquire) || stored_frames > capacity) return false;

        uint32_t first = 0;
        uint32_t last = stored_frames;
        uint64_t gate = atomic_load_explicit(&q->gate_open_ns, memory_order_acquire);
        uint64_t cutoff = atomic_load_explicit(&q->cutoff_ns, memory_order_acquire);
        if (gate > slot->metadata.host_start_ns) {
            uint64_t offset = first_sample_at_or_after(gate - slot->metadata.host_start_ns, slot->metadata.sample_rate);
            first = offset > stored_frames ? stored_frames : (uint32_t)offset;
        }
        if (cutoff != UINT64_MAX) {
            if (cutoff <= slot->metadata.host_start_ns) last = 0;
            else {
                uint64_t offset = first_sample_at_or_after(cutoff - slot->metadata.host_start_ns, slot->metadata.sample_rate);
                last = offset > stored_frames ? stored_frames : (uint32_t)offset;
            }
        }
        if (last > stored_frames) last = stored_frames;
        if (first > last) first = last;
        uint32_t kept = last - first;
        *block = slot->metadata;
        if (kept > 0) {
            __uint128_t start_delta = (__uint128_t)first * NANOS_PER_SECOND / slot->metadata.sample_rate;
            if (start_delta > UINT64_MAX || UINT64_MAX - block->host_start_ns < (uint64_t)start_delta) {
                atomic_store_explicit(&q->overflow, true, memory_order_release);
                kept = 0;
            } else {
                block->host_start_ns += (uint64_t)start_delta;
                block->frame_count = kept;
                for (uint32_t i = 0; i < kept; i++) {
                    left[i] = slot->samples[(first + i) * 2];
                    right[i] = slot->samples[(first + i) * 2 + 1];
                }
            }
        }
        atomic_store_explicit(&slot->ready, false, memory_order_release);
        atomic_store_explicit(&q->read_index, read + 1, memory_order_release);
        atomic_fetch_sub_explicit(&q->pending_frames, stored_frames, memory_order_acq_rel);
        if (kept == 0) continue;
        return true;
    }
}

bool MISTTAudioQueueIsOpen(const MISTTAudioQueue *q) { return q && atomic_load_explicit(&q->gate_open, memory_order_acquire); }
bool MISTTAudioQueueOverflowed(const MISTTAudioQueue *q) { return q && atomic_load_explicit(&q->overflow, memory_order_acquire); }
uint64_t MISTTAudioQueuePendingFrames(const MISTTAudioQueue *q) { return q ? atomic_load_explicit(&q->pending_frames, memory_order_acquire) : 0; }
uint32_t MISTTAudioQueueCallbacksInFlight(const MISTTAudioQueue *q) { return q ? atomic_load_explicit(&q->callbacks_in_flight, memory_order_acquire) : 0; }
