#include "PreflightAtomics.h"

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef struct {
    _Atomic bool entered;
    _Atomic bool release;
} CallbackBarrier;

typedef struct {
    MISTTAtomicCapture *capture;
    CallbackBarrier *barrier;
    _Atomic bool finished;
    int32_t result;
} CallbackJob;

typedef struct {
    MISTTAtomicCapture *capture;
    _Atomic bool finished;
} CloseJob;

static void pause_before_commit(void *context) {
    CallbackBarrier *barrier = context;
    atomic_store_explicit(&barrier->entered, true, memory_order_release);
    while (!atomic_load_explicit(&barrier->release, memory_order_acquire)) sched_yield();
}

static void *record_callback(void *context) {
    CallbackJob *job = context;
    job->result = MISTTRecordBufferWithTestHook(
        job->capture, 0, true, UINT64_C(1004000000), 160, 16000,
        pause_before_commit, job->barrier);
    atomic_store_explicit(&job->finished, true, memory_order_release);
    return NULL;
}

static void *close_gate(void *context) {
    CloseJob *job = context;
    MISTTCloseCaptureGate(job->capture, UINT64_C(1005000000));
    atomic_store_explicit(&job->finished, true, memory_order_release);
    return NULL;
}

static int wait_for(_Atomic bool *flag, const char *what) {
    const struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    for (unsigned i = 0; i < 2000; ++i) {
        if (atomic_load_explicit(flag, memory_order_acquire)) return 0;
        nanosleep(&pause, NULL);
    }
    fprintf(stderr, "timed out waiting for %s\n", what);
    return 1;
}

int main(void) {
    MISTTAtomicCapture *capture = MISTTCreateCaptureState();
    if (capture == NULL) {
        fprintf(stderr, "could not create capture state\n");
        return 1;
    }

    MISTTOpenCaptureGate(capture, UINT64_C(1000000000));
    CallbackBarrier barrier = {0};
    CallbackJob callback = {.capture = capture, .barrier = &barrier};
    CloseJob closer = {.capture = capture};
    pthread_t callback_thread, closer_thread;

    if (pthread_create(&callback_thread, NULL, record_callback, &callback) != 0) {
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "could not start callback thread\n");
        return 1;
    }
    if (wait_for(&barrier.entered, "callback to hold the C accounting lock") != 0) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        MISTTDestroyCaptureState(capture);
        return 1;
    }
    if (pthread_create(&closer_thread, NULL, close_gate, &closer) != 0) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "could not start close thread\n");
        return 1;
    }

    const struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    for (unsigned i = 0; MISTTCaptureGateIsOpen(capture) && i < 2000; ++i) nanosleep(&pause, NULL);
    if (MISTTCaptureGateIsOpen(capture)) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        pthread_join(closer_thread, NULL);
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "close did not publish the closed gate\n");
        return 1;
    }
    if (atomic_load_explicit(&closer.finished, memory_order_acquire)) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        pthread_join(closer_thread, NULL);
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "close returned while the C callback still held its accounting lock\n");
        return 1;
    }

    atomic_store_explicit(&barrier.release, true, memory_order_release);
    pthread_join(callback_thread, NULL);
    pthread_join(closer_thread, NULL);

    MISTTSourceSnapshot snapshot;
    MISTTReadSource(capture, 0, &snapshot);
    int failed = callback.result != 0 || snapshot.frames != 16 ||
                 snapshot.clipped_or_dropped_frames != 144;
    if (failed) {
        fprintf(stderr, "wrong cutoff accounting: result=%d frames=%llu clipped=%llu\n",
                callback.result, (unsigned long long)snapshot.frames,
                (unsigned long long)snapshot.clipped_or_dropped_frames);
    } else {
        puts("PASS: held-lock callback reconciles to the stop cutoff (16 retained, 144 clipped)");
    }
    MISTTDestroyCaptureState(capture);
    return failed ? 1 : 0;
}
