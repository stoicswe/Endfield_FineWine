/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Runs Wine's msync_wait_objs() (pasted in at @implementation) in WaitAll mode
 * on two objects. A competing consumer takes object 1 right before our CAS on
 * it, so the wait must roll back object 0. An observer thread sleeps on object
 * 0 with a real ulock wait and must be woken by that rollback.
 */
#include <assert.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef uint32_t DWORD;
typedef uint64_t ULONGLONG;
typedef unsigned int NTSTATUS;
typedef int BOOL;
typedef unsigned char BOOLEAN;
typedef struct {
  int64_t QuadPart;
} LARGE_INTEGER;
#define TRUE 1
#define FALSE 0
#define MAXIMUM_WAIT_OBJECTS 64
#define TIMEOUT_INFINITE INT64_MAX
#define STATUS_SUCCESS 0
#define STATUS_PENDING 0x103
#define STATUS_TIMEOUT 0x102
#define STATUS_USER_APC 0xc0
#define STATUS_ABANDONED_WAIT_0 0x80
#define STATUS_ABANDONED 0x80
#define SELECT_INTERRUPTIBLE 1
#define SELECT_ALERTABLE 2
#define ERR(...) fprintf(stderr, __VA_ARGS__)
enum {
  MSYNC_SEMAPHORE = 1,
  MSYNC_AUTO_EVENT,
  MSYNC_MANUAL_EVENT,
  MSYNC_MUTEX,
  MSYNC_AUTO_SERVER,
  MSYNC_MANUAL_SERVER
};
struct semaphore {
  int count, max;
  unsigned short msync_type, refcount;
  int multiple_waiters;
};
struct event {
  int signaled, unused;
  unsigned short msync_type, refcount;
  int multiple_waiters;
};
struct mutex {
  int tid, count;
  unsigned short msync_type, refcount;
  int multiple_waiters;
};
/* Layout shared by the three msync object types. */
struct slot {
  int state, count; /* signaled/count/tid, then unused/max/count */
  unsigned short type, refs;
  int waiters;
};
static struct slot *slots;
static int injected, inject_race, use_observer, notifications, wait_result;
static int test_tid = 100;
static pthread_t observer;
static volatile int observer_started;
#define UL_COMPARE_AND_WAIT_SHARED 3
#define ULF_WAKE_ALL 0x100
#define ULF_NO_ERRNO 0x1000000
extern int __ulock_wait2(uint32_t, void *, uint64_t, uint64_t, uint64_t);
extern int __ulock_wake(uint32_t, void *, uint64_t);

static void *observe(void *unused) {
  (void)unused;
  int value = __atomic_load_n(&slots[0].state, __ATOMIC_SEQ_CST);
  __atomic_store_n(&observer_started, 1, __ATOMIC_RELEASE);
  wait_result = __ulock_wait2(UL_COMPARE_AND_WAIT_SHARED | ULF_NO_ERRNO, &slots[0].state, value,
                              1500000000 /* ns */, 0);
  return NULL;
}

static void park_observer(void) {
  assert(!pthread_create(&observer, NULL, observe, NULL));
  int parked = 0;
  for (int i = 0; i < 5000; ++i) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (__atomic_load_n(&observer_started, __ATOMIC_ACQUIRE) &&
        thread_info(pthread_mach_thread_np(observer), THREAD_BASIC_INFO, (thread_info_t)&info,
                    &count) == KERN_SUCCESS &&
        info.run_state == TH_STATE_WAITING) {
      parked = 1;
      break;
    }
    usleep(100);
  }
  assert(parked && "observer must be asleep before the rollback");
}

static int race_cas(int *ptr, int expected, int desired) {
  if (ptr == &slots[1].state && inject_race && !injected) {
    injected = 1;
    __atomic_store_n(ptr, 0, __ATOMIC_SEQ_CST);
    if (use_observer)
      park_observer();
  }
  __atomic_compare_exchange_n(ptr, &expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  return expected;
}
#define __sync_val_compare_and_swap(ptr, old, value) race_cas(ptr, old, value)

static void *get_shm(int obj) { return &slots[obj]; }
static int GetCurrentThreadId(void) { return test_tid; }
static void NtQuerySystemTime(LARGE_INTEGER *t) { t->QuadPart = 0; }
static void signal_all(void *shm, unsigned int obj) {
  (void)obj;
  ++notifications;
  __ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL, shm, 0);
}
static NTSTATUS msync_wait_single(int obj, void *shm, ULONGLONG *end, int tid) {
  (void)obj;
  (void)shm;
  (void)end;
  (void)tid;
  return STATUS_TIMEOUT;
}
static NTSTATUS msync_wait_multiple(const int *objs, void **shm, int alert, void *alert_shm,
                                    int count, ULONGLONG *end, int tid) {
  (void)objs;
  (void)shm;
  (void)alert;
  (void)alert_shm;
  (void)count;
  (void)end;
  (void)tid;
  return STATUS_TIMEOUT;
}
/* Only an abandoned mutex (tid -1) is waited on; it is immediately available. */
static NTSTATUS do_single_wait(int obj, void *shm, int alert, void *alert_shm, ULONGLONG *end,
                               int tid) {
  (void)shm;
  (void)alert;
  (void)alert_shm;
  (void)end;
  (void)tid;
  return slots[obj].state == -1 ? STATUS_SUCCESS : STATUS_TIMEOUT;
}
static NTSTATUS server_wait(void *a, int b, int c, const LARGE_INTEGER *d) {
  (void)a;
  (void)b;
  (void)c;
  (void)d;
  return STATUS_TIMEOUT;
}

/* @implementation */

static int rollback_case(const char *name, int type, int initial, int owned_count, int expect_notify) {
  memset(slots, 0, 2 * sizeof(*slots));
  slots[0] = (struct slot){initial, owned_count, type, 1, 0};
  slots[1] = (struct slot){1, 0, MSYNC_AUTO_EVENT, 1, 0};
  injected = notifications = observer_started = 0;
  inject_race = 1;
  wait_result = -999;
  use_observer = expect_notify;
  const int objects[] = {0, 1};
  NTSTATUS result = msync_wait_objs(2, objects, FALSE, 0, NULL);
  if (use_observer)
    pthread_join(observer, NULL);
  int pass = injected && result == STATUS_TIMEOUT && slots[0].state == initial &&
             slots[0].count == owned_count && notifications == expect_notify &&
             (!use_observer || wait_result == 0);
  printf("%s: %s state=%d count=%d notifications=%d waiter_result=%d\n", name,
         pass ? "PASS" : "FAIL", slots[0].state, slots[0].count, notifications, wait_result);
  return !pass;
}

static int success_case(const char *name, int type, int initial, int count, int final,
                        int final_count, NTSTATUS expected) {
  slots[0] = (struct slot){initial, count, type, 1, 0};
  slots[1] = (struct slot){1, 0, MSYNC_AUTO_EVENT, 1, 0};
  inject_race = notifications = 0;
  const int objects[] = {0, 1};
  NTSTATUS result = msync_wait_objs(2, objects, FALSE, 0, NULL);
  int pass = result == expected && slots[0].state == final && slots[0].count == final_count &&
             slots[1].state == 0 && !notifications;
  printf("%s: %s state=%d count=%d result=%u\n", name, pass ? "PASS" : "FAIL", slots[0].state,
         slots[0].count, result);
  return !pass;
}

int main(void) {
  slots = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  assert(slots != MAP_FAILED);
  int failures = 0;
  failures += rollback_case("auto-event rollback wakes sleeper", MSYNC_AUTO_EVENT, 1, 0, 1);
  failures += rollback_case("semaphore rollback wakes sleeper", MSYNC_SEMAPHORE, 1, 1, 1);
  failures += rollback_case("mutex rollback wakes sleeper", MSYNC_MUTEX, 0, 0, 1);
  failures += rollback_case("owned mutex remains owned", MSYNC_MUTEX, test_tid, 3, 0);
  failures += rollback_case("abandoned mutex stays abandoned", MSYNC_MUTEX, -1, 0, 1);
  failures += rollback_case("manual event remains signaled", MSYNC_MANUAL_EVENT, 1, 0, 0);
  failures += success_case("event success", MSYNC_AUTO_EVENT, 1, 0, 0, 0, STATUS_SUCCESS);
  failures += success_case("semaphore success", MSYNC_SEMAPHORE, 1, 1, 0, 1, STATUS_SUCCESS);
  failures += success_case("mutex success", MSYNC_MUTEX, 0, 0, test_tid, 1, STATUS_SUCCESS);
  failures += success_case("recursive mutex success", MSYNC_MUTEX, test_tid, 3, test_tid, 4,
                           STATUS_SUCCESS);
  failures +=
      success_case("abandoned mutex success", MSYNC_MUTEX, -1, 0, test_tid, 1, STATUS_ABANDONED);
  munmap(slots, 4096);
  return failures ? 1 : 0;
}
