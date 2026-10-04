#define _POSIX_C_SOURCE 200809L

#include "PreflightAtomics.h"

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TEST_WATCHDOG_SECONDS 5

static _Atomic bool tests_complete;

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

static int finish(int status) {
    atomic_store_explicit(&tests_complete, true, memory_order_release);
    return status;
}

static void *watch_tests(void *context) {
    (void)context;
    struct timespec started;
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) _Exit(125);
    while (!atomic_load_explicit(&tests_complete, memory_order_acquire)) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) _Exit(125);
        int64_t elapsed_ns = (int64_t)(now.tv_sec - started.tv_sec) * INT64_C(1000000000) +
                             (int64_t)now.tv_nsec - (int64_t)started.tv_nsec;
        if (elapsed_ns >= TEST_WATCHDOG_SECONDS * INT64_C(1000000000)) {
            const char message[] = "test watchdog expired while a test or cleanup was blocked\n";
            (void)write(STDERR_FILENO, message, sizeof(message) - 1);
            _Exit(124);
        }
        const struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    return NULL;
}

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

int main(int argc, char **argv) {
    pthread_t watchdog_thread;
    if (pthread_create(&watchdog_thread, NULL, watch_tests, NULL) != 0) {
        fprintf(stderr, "could not start test watchdog\n");
        return 1;
    }
    pthread_detach(watchdog_thread);
    if (argc == 2 && strcmp(argv[1], "--watchdog-probe") == 0) {
        for (;;) sched_yield();
    }

    MISTTAtomicCapture *capture = MISTTCreateCaptureState();
    if (capture == NULL) {
        fprintf(stderr, "could not create capture state\n");
        return finish(1);
    }

    MISTTOpenCaptureGate(capture, UINT64_C(1000000000));
    CallbackBarrier barrier = {0};
    CallbackJob callback = {.capture = capture, .barrier = &barrier};
    CloseJob closer = {.capture = capture};
    pthread_t callback_thread, closer_thread;

    if (pthread_create(&callback_thread, NULL, record_callback, &callback) != 0) {
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "could not start callback thread\n");
        return finish(1);
    }
    if (wait_for(&barrier.entered, "callback to hold the C accounting lock") != 0) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        MISTTDestroyCaptureState(capture);
        return finish(1);
    }
    if (pthread_create(&closer_thread, NULL, close_gate, &closer) != 0) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "could not start close thread\n");
        return finish(1);
    }

    const struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
    for (unsigned i = 0; MISTTCaptureGateIsOpen(capture) && i < 2000; ++i) nanosleep(&pause, NULL);
    if (MISTTCaptureGateIsOpen(capture)) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        pthread_join(closer_thread, NULL);
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "close did not publish the closed gate\n");
        return finish(1);
    }
    if (atomic_load_explicit(&closer.finished, memory_order_acquire)) {
        atomic_store_explicit(&barrier.release, true, memory_order_release);
        pthread_join(callback_thread, NULL);
        pthread_join(closer_thread, NULL);
        MISTTDestroyCaptureState(capture);
        fprintf(stderr, "close returned while the C callback still held its accounting lock\n");
        return finish(1);
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
    if (failed) return finish(1);

    MISTTAtomicCapture *fractional = MISTTCreateCaptureState();
    if (fractional == NULL) {
        fprintf(stderr, "could not create fractional-cutoff capture state\n");
        return finish(1);
    }
    const uint64_t epoch_ns = UINT64_C(1000000000);
    const uint64_t cutoff_ns = UINT64_C(1000041666);
    MISTTOpenCaptureGate(fractional, epoch_ns);
    if (MISTTRecordBuffer(fractional, 0, true, epoch_ns, 3, 48000) != 0) {
        MISTTDestroyCaptureState(fractional);
        fprintf(stderr, "fractional-cutoff buffer was rejected before stop\n");
        return finish(1);
    }
    MISTTCloseCaptureGate(fractional, cutoff_ns);
    if (MISTTRecordBuffer(fractional, 0, true, cutoff_ns, 1, 48000) != 0) {
        MISTTDestroyCaptureState(fractional);
        fprintf(stderr, "post-cutoff record did not fail closed\n");
        return finish(1);
    }
    if (MISTTEnqueueEnergy(fractional, 0, cutoff_ns, cutoff_ns + 1, 123)) {
        MISTTDestroyCaptureState(fractional);
        fprintf(stderr, "post-cutoff energy append was accepted\n");
        return finish(1);
    }
    MISTTSourceSnapshot fractional_snapshot;
    MISTTReadSource(fractional, 0, &fractional_snapshot);
    MISTTEnergyBatch energy_batch;
    MISTTDrainEnergy(fractional, 0, &energy_batch);
    int fractional_failed = fractional_snapshot.frames != 2 ||
                            fractional_snapshot.clipped_or_dropped_frames != 1 ||
                            energy_batch.count != 0;
    MISTTDestroyCaptureState(fractional);
    if (fractional_failed) {
        fprintf(stderr, "wrong fractional cutoff accounting: frames=%llu clipped=%llu energy=%u\n",
                (unsigned long long)fractional_snapshot.frames,
                (unsigned long long)fractional_snapshot.clipped_or_dropped_frames,
                energy_batch.count);
        return finish(1);
    }
    puts("PASS: fractional cutoff retains only pre-cutoff samples and rejects later record/energy append");
    return finish(0);
}
