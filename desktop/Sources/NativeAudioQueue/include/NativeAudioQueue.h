#ifndef MISTT_NATIVE_AUDIO_QUEUE_H
#define MISTT_NATIVE_AUDIO_QUEUE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef struct MISTTAudioQueue MISTTAudioQueue;

typedef struct {
    uint64_t host_start_ns;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t frame_count;
} MISTTAudioBlock;

MISTTAudioQueue *MISTTAudioQueueCreate(uint32_t slot_count, uint32_t maximum_block_frames);
void MISTTAudioQueueDestroy(MISTTAudioQueue *queue);
void MISTTAudioQueueOpenGate(MISTTAudioQueue *queue, uint64_t gate_open_ns);
void MISTTAudioQueueCloseGate(MISTTAudioQueue *queue, uint64_t cutoff_ns);
bool MISTTAudioQueuePushFloat32(MISTTAudioQueue *queue, const float *left, const float *right,
                                uint32_t frames, uint32_t channels, uint32_t sample_rate,
                                uint64_t host_start_ns);
bool MISTTAudioQueuePop(MISTTAudioQueue *queue, float *left, float *right,
                        uint32_t destination_capacity_frames, MISTTAudioBlock *block);
bool MISTTAudioQueueIsOpen(const MISTTAudioQueue *queue);
bool MISTTAudioQueueOverflowed(const MISTTAudioQueue *queue);
uint64_t MISTTAudioQueuePendingFrames(const MISTTAudioQueue *queue);
uint32_t MISTTAudioQueueCallbacksInFlight(const MISTTAudioQueue *queue);
#endif
