#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum raw_event_kind {
  PATH_CHANGED = 0,
  ITEM_RENAMED = 1,
  MUST_SCAN_SUBDIRS = 2,
  KERNEL_DROPPED = 3,
  USER_DROPPED = 4,
  CLIENT_OVERFLOW = 5,
  EVENT_IDS_WRAPPED = 6,
  ROOT_CHANGED = 7,
  UNMOUNTED = 8,
};

enum { MAX_PENDING_EVENTS = 4096, MAX_PENDING_PATH_BYTES = 1048576 };

struct pending_event {
  int kind;
  char *path;
  struct pending_event *next;
};

struct watcher {
  FSEventStreamRef stream;
  dispatch_queue_t queue;
  int wake_read;
  int wake_write;
  char *root;
  size_t root_length;
  pthread_mutex_t mutex;
  struct pending_event *events;
  size_t event_count;
  size_t path_bytes;
  int client_overflow;
  int closed;
  int mutex_initialized;
};

#define Watcher_val(handle) (*((struct watcher **)Data_custom_val(handle)))

static void free_events(struct pending_event *event) {
  while (event != NULL) {
    struct pending_event *next = event->next;
    free(event->path);
    free(event);
    event = next;
  }
}

static void discard_events(struct watcher *watcher) {
  free_events(watcher->events);
  watcher->events = NULL;
  watcher->event_count = 0;
  watcher->path_bytes = 0;
}

static void wake(struct watcher *watcher) {
  char byte = 1;
  if (watcher->wake_write >= 0) {
    ssize_t ignored = write(watcher->wake_write, &byte, 1);
    (void)ignored;
  }
}

static int metadata_path(struct watcher *watcher, const char *path) {
  const char *relative;
  if (path == NULL || strncmp(path, watcher->root, watcher->root_length) != 0)
    return 0;
  if (path[watcher->root_length] == '\0') return 0;
  if (watcher->root_length != 1 && path[watcher->root_length] != '/') return 0;
  relative = path + watcher->root_length;
  if (watcher->root_length != 1) relative++;
  else if (*relative == '/') relative++;
  return (strncmp(relative, ".yeokcham", 9) == 0 &&
          (relative[9] == '\0' || relative[9] == '/')) ||
         (strncmp(relative, ".git", 4) == 0 &&
          (relative[4] == '\0' || relative[4] == '/'));
}

static void record_client_overflow(struct watcher *watcher) {
  discard_events(watcher);
  watcher->client_overflow = 1;
  wake(watcher);
}

static void enqueue(struct watcher *watcher, int kind, const char *path) {
  struct pending_event *event;
  size_t path_length = path == NULL ? 0 : strlen(path);
  pthread_mutex_lock(&watcher->mutex);
  if (watcher->closed) {
    pthread_mutex_unlock(&watcher->mutex);
    return;
  }
  if (kind == PATH_CHANGED && path != NULL && metadata_path(watcher, path)) {
    pthread_mutex_unlock(&watcher->mutex);
    return;
  }
  if (watcher->event_count >= MAX_PENDING_EVENTS ||
      path_length > MAX_PENDING_PATH_BYTES ||
      watcher->path_bytes > MAX_PENDING_PATH_BYTES - path_length) {
    record_client_overflow(watcher);
    pthread_mutex_unlock(&watcher->mutex);
    return;
  }
  event = malloc(sizeof(*event));
  if (event == NULL) {
    record_client_overflow(watcher);
    pthread_mutex_unlock(&watcher->mutex);
    return;
  }
  event->kind = kind;
  event->path = NULL;
  if (path != NULL) {
    event->path = malloc(path_length + 1);
    if (event->path == NULL) {
      free(event);
      record_client_overflow(watcher);
      pthread_mutex_unlock(&watcher->mutex);
      return;
    }
    memcpy(event->path, path, path_length + 1);
  }
  event->next = watcher->events;
  watcher->events = event;
  watcher->event_count++;
  watcher->path_bytes += path_length;
  wake(watcher);
  pthread_mutex_unlock(&watcher->mutex);
}

static void callback(ConstFSEventStreamRef stream, void *context,
                     size_t event_count, void *event_paths,
                     const FSEventStreamEventFlags event_flags[],
                     const FSEventStreamEventId event_ids[]) {
  struct watcher *watcher = context;
  char **paths = event_paths;
  size_t index;
  (void)stream;
  (void)event_ids;
  for (index = 0; index < event_count; index++) {
    FSEventStreamEventFlags flags = event_flags[index];
    if (flags & kFSEventStreamEventFlagRootChanged)
      enqueue(watcher, ROOT_CHANGED, NULL);
    else if (flags & kFSEventStreamEventFlagEventIdsWrapped)
      enqueue(watcher, EVENT_IDS_WRAPPED, NULL);
    else if (flags & kFSEventStreamEventFlagUnmount)
      enqueue(watcher, UNMOUNTED, NULL);
    else if (flags & kFSEventStreamEventFlagKernelDropped)
      enqueue(watcher, KERNEL_DROPPED, NULL);
    else if (flags & kFSEventStreamEventFlagUserDropped)
      enqueue(watcher, USER_DROPPED, NULL);
    else if (flags & kFSEventStreamEventFlagMustScanSubDirs)
      enqueue(watcher, MUST_SCAN_SUBDIRS, NULL);
    else if (flags & kFSEventStreamEventFlagItemRenamed)
      enqueue(watcher, ITEM_RENAMED, paths[index]);
    else
      enqueue(watcher, PATH_CHANGED, paths[index]);
  }
}

static void drain_queue(void *unused) { (void)unused; }

static void watcher_destroy(struct watcher *watcher) {
  FSEventStreamRef stream;
  dispatch_queue_t queue;
  if (watcher == NULL) return;
  if (!watcher->mutex_initialized) {
    free(watcher->root);
    free(watcher);
    return;
  }
  pthread_mutex_lock(&watcher->mutex);
  if (watcher->closed) {
    pthread_mutex_unlock(&watcher->mutex);
    return;
  }
  watcher->closed = 1;
  stream = watcher->stream;
  queue = watcher->queue;
  watcher->stream = NULL;
  watcher->queue = NULL;
  pthread_mutex_unlock(&watcher->mutex);
  if (stream != NULL) {
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
  }
  if (queue != NULL) dispatch_sync_f(queue, NULL, drain_queue);
  if (stream != NULL) FSEventStreamRelease(stream);
  if (queue != NULL) dispatch_release(queue);
  if (watcher->wake_read >= 0) close(watcher->wake_read);
  if (watcher->wake_write >= 0) close(watcher->wake_write);
  pthread_mutex_lock(&watcher->mutex);
  discard_events(watcher);
  pthread_mutex_unlock(&watcher->mutex);
  pthread_mutex_destroy(&watcher->mutex);
  free(watcher->root);
  free(watcher);
}

static void watcher_finalize(value handle) {
  struct watcher *watcher = Watcher_val(handle);
  Watcher_val(handle) = NULL;
  watcher_destroy(watcher);
}

static struct custom_operations watcher_operations = {
    "yeokcham_v1_macos_watcher",
    watcher_finalize,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default};

static int set_nonblocking(int descriptor) {
  int flags = fcntl(descriptor, F_GETFL);
  return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}

static struct watcher *watcher_create(const char *root) {
  struct watcher *watcher = calloc(1, sizeof(*watcher));
  CFStringRef root_string = NULL;
  CFArrayRef paths = NULL;
  FSEventStreamContext context = {0, NULL, NULL, NULL, NULL};
  FSEventStreamCreateFlags flags =
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot |
      kFSEventStreamCreateFlagNoDefer;
  int descriptors[2] = {-1, -1};
  if (watcher == NULL) return NULL;
  watcher->wake_read = -1;
  watcher->wake_write = -1;
  if (pthread_mutex_init(&watcher->mutex, NULL) != 0) goto failed;
  watcher->mutex_initialized = 1;
  watcher->root = malloc(strlen(root) + 1);
  if (watcher->root == NULL) goto failed;
  strcpy(watcher->root, root);
  watcher->root_length = strlen(root);
  if (pipe(descriptors) != 0 || !set_nonblocking(descriptors[0]) ||
      !set_nonblocking(descriptors[1]))
    goto failed;
  watcher->wake_read = descriptors[0];
  watcher->wake_write = descriptors[1];
  descriptors[0] = descriptors[1] = -1;
  root_string =
      CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, root);
  if (root_string == NULL) goto failed;
  paths = CFArrayCreate(kCFAllocatorDefault, (const void **)&root_string, 1,
                        &kCFTypeArrayCallBacks);
  if (paths == NULL) goto failed;
  context.info = watcher;
  watcher->stream = FSEventStreamCreate(
      kCFAllocatorDefault, callback, &context, paths,
      kFSEventStreamEventIdSinceNow, 0.05, flags);
  if (watcher->stream == NULL) goto failed;
  watcher->queue = dispatch_queue_create("org.yeokcham.v1.fsevents",
                                         DISPATCH_QUEUE_SERIAL);
  if (watcher->queue == NULL) goto failed;
  FSEventStreamSetDispatchQueue(watcher->stream, watcher->queue);
  if (!FSEventStreamStart(watcher->stream)) goto failed;
  CFRelease(paths);
  CFRelease(root_string);
  return watcher;

failed:
  if (paths != NULL) CFRelease(paths);
  if (root_string != NULL) CFRelease(root_string);
  if (descriptors[0] >= 0) close(descriptors[0]);
  if (descriptors[1] >= 0) close(descriptors[1]);
  watcher_destroy(watcher);
  return NULL;
}

CAMLprim value caml_yeokcham_macos_watcher_start(value root) {
  CAMLparam1(root);
  CAMLlocal1(result);
  struct watcher *watcher;
  result = caml_alloc_custom(&watcher_operations, sizeof(struct watcher *), 0,
                             1);
  Watcher_val(result) = NULL;
  watcher = watcher_create(String_val(root));
  if (watcher == NULL) caml_failwith("could not create FSEvent stream");
  Watcher_val(result) = watcher;
  CAMLreturn(result);
}

static void drain_wakeup_pipe(int descriptor) {
  char buffer[256];
  while (read(descriptor, buffer, sizeof(buffer)) > 0) {
  }
}

CAMLprim value caml_yeokcham_macos_watcher_poll(value handle,
                                                  value timeout) {
  CAMLparam2(handle, timeout);
  CAMLlocal5(result, pair, path, option, cell);
  struct watcher *watcher = Watcher_val(handle);
  struct pending_event *events;
  struct pollfd descriptor;
  int pending;
  int milliseconds;
  int ready;
  int overflow;
  if (watcher == NULL) caml_failwith("FSEvents watcher is closed");
  pthread_mutex_lock(&watcher->mutex);
  if (watcher->closed) {
    pthread_mutex_unlock(&watcher->mutex);
    caml_failwith("FSEvents watcher is closed");
  }
  pending = watcher->events != NULL || watcher->client_overflow;
  pthread_mutex_unlock(&watcher->mutex);
  if (!pending) {
    double seconds = Double_val(timeout);
    if (seconds > (double)INT_MAX / 1000.0)
      milliseconds = INT_MAX;
    else
      milliseconds = (int)(seconds * 1000.0 + 0.999999);
    descriptor.fd = watcher->wake_read;
    descriptor.events = POLLIN;
    descriptor.revents = 0;
    caml_enter_blocking_section();
    ready = poll(&descriptor, 1, milliseconds);
    caml_leave_blocking_section();
    if (ready < 0 && errno != EINTR)
      caml_failwith("could not poll FSEvents wakeup pipe");
    if (ready > 0 && (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)))
      caml_failwith("FSEvents wakeup pipe closed");
    if (ready > 0 && (descriptor.revents & POLLIN))
      drain_wakeup_pipe(watcher->wake_read);
  }
  pthread_mutex_lock(&watcher->mutex);
  events = watcher->events;
  watcher->events = NULL;
  watcher->event_count = 0;
  watcher->path_bytes = 0;
  overflow = watcher->client_overflow;
  watcher->client_overflow = 0;
  pthread_mutex_unlock(&watcher->mutex);
  result = Val_emptylist;
  while (events != NULL) {
    struct pending_event *next = events->next;
    pair = caml_alloc_small(2, 0);
    Store_field(pair, 0, Val_int(events->kind));
    if (events->path == NULL)
      option = Val_int(0);
    else {
      path = caml_copy_string(events->path);
      option = caml_alloc_small(1, 0);
      Store_field(option, 0, path);
    }
    Store_field(pair, 1, option);
    cell = caml_alloc_small(2, 0);
    Store_field(cell, 0, pair);
    Store_field(cell, 1, result);
    result = cell;
    free(events->path);
    free(events);
    events = next;
  }
  if (overflow) {
    pair = caml_alloc_small(2, 0);
    Store_field(pair, 0, Val_int(CLIENT_OVERFLOW));
    Store_field(pair, 1, Val_int(0));
    cell = caml_alloc_small(2, 0);
    Store_field(cell, 0, pair);
    Store_field(cell, 1, result);
    result = cell;
  }
  CAMLreturn(result);
}

CAMLprim value caml_yeokcham_macos_watcher_close(value handle) {
  CAMLparam1(handle);
  struct watcher *watcher = Watcher_val(handle);
  Watcher_val(handle) = NULL;
  if (watcher != NULL) {
    caml_enter_blocking_section();
    watcher_destroy(watcher);
    caml_leave_blocking_section();
  }
  CAMLreturn(Val_unit);
}
