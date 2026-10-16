#define _GNU_SOURCE
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define API __attribute__((visibility("default")))
#define UNSAFE 1
#define CONFLICT 2
#define STORAGE 3
#define LOST 4
#define MAX_PINS 128

typedef struct {
  int fd;
  dev_t device;
  ino_t inode;
  char *path;
} Pin;
typedef struct {
  Pin pins[MAX_PINS];
  int count;
  int root_index;
  int lock_fd;
  dev_t lock_device;
  ino_t lock_inode;
  int lost;
} Owner;

static int safe_relative(const char *path) {
  if (!path || !*path || path[0] == '/' || strlen(path) >= PATH_MAX) return 0;
  const char *part = path;
  for (const char *c = path;; ++c) {
    if (*c == '\\' || (*c && (unsigned char)*c < 32)) return 0;
    if (*c == '/' || !*c) {
      size_t length = (size_t)(c - part);
      if (!length || length > NAME_MAX ||
          (length == 1 && part[0] == '.') ||
          (length == 2 && part[0] == '.' && part[1] == '.')) return 0;
      if (!*c) return 1;
      part = c + 1;
    }
  }
}

static int drain(Owner *owner) {
  int failed = 0;
  // Linux consumes the descriptor on close, including EINTR. Never retry a
  // potentially reused descriptor. Report a failed drain without claiming a lease.
  if (owner->lock_fd >= 0 && close(owner->lock_fd) != 0) failed = 1;
  for (int i = owner->count - 1; i >= 0; --i) {
    if (close(owner->pins[i].fd) != 0) failed = 1;
    free(owner->pins[i].path);
  }
  free(owner);
  return failed ? LOST : 0;
}

API int ustc_posix_owner_check(Owner *owner) {
  if (!owner || owner->lost) return LOST;
  struct stat held, named;
  for (int i = 0; i < owner->count; ++i) {
    Pin *pin = &owner->pins[i];
    if (fstat(pin->fd, &held) != 0 || lstat(pin->path, &named) != 0 ||
        !S_ISDIR(held.st_mode) || !S_ISDIR(named.st_mode) ||
        held.st_dev != pin->device || held.st_ino != pin->inode ||
        named.st_dev != pin->device || named.st_ino != pin->inode) goto lost;
  }
  if (owner->lock_fd < 0 || fstat(owner->lock_fd, &held) != 0 ||
      fstatat(owner->pins[owner->root_index].fd, ".owner.lock", &named,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(held.st_mode) || !S_ISREG(named.st_mode) ||
      held.st_nlink != 1 || named.st_nlink != 1 || held.st_uid != geteuid() ||
      held.st_dev != owner->lock_device || held.st_ino != owner->lock_inode ||
      named.st_dev != owner->lock_device || named.st_ino != owner->lock_inode ||
      flock(owner->lock_fd, LOCK_EX | LOCK_NB) != 0) goto lost;
  return 0;
lost:
  owner->lost = 1;
  return LOST;
}

API Owner *ustc_posix_owner_acquire(const char *path, int *failure) {
  *failure = UNSAFE;
  if (!path || strlen(path) >= PATH_MAX || path[0] != '/' || !safe_relative(path + 1)) return NULL;
  Owner *owner = calloc(1, sizeof(Owner));
  if (!owner) { *failure = STORAGE; return NULL; }
  owner->lock_fd = -1;
  char prefix[PATH_MAX] = "/";
  char parts[PATH_MAX];
  strcpy(parts, path + 1);
  int parent = AT_FDCWD;
  char *remaining = NULL;
  char *part = strtok_r(parts, "/", &remaining);
  // Pin root as well as every ancestor, then compare their identities on use.
  for (;;) {
    const char *name = owner->count == 0 ? "/" : part;
    // System ancestors may grant search without directory read permission.
    // O_PATH pins identity and supports *at operations without requiring read.
    int fd = openat(parent, name, O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) goto failed;
    struct stat metadata;
    if (fstat(fd, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) {
      close(fd); goto failed;
    }
    if (owner->count != 0) {
      if (strlen(prefix) > 1) strcat(prefix, "/");
      strcat(prefix, part);
    }
    char *stored_path = strdup(prefix);
    if (!stored_path) { close(fd); *failure = STORAGE; goto failed; }
    Pin *pin = &owner->pins[owner->count++];
    pin->fd = fd; pin->device = metadata.st_dev; pin->inode = metadata.st_ino;
    pin->path = stored_path;
    parent = fd;
    if (owner->count > 1) part = strtok_r(NULL, "/", &remaining);
    if (!part) break;
    if (owner->count >= MAX_PINS) goto failed;
  }
  struct stat root;
  owner->root_index = owner->count - 1;
  if (fstat(parent, &root) != 0 || root.st_uid != geteuid()) goto failed;
  owner->lock_fd = openat(parent, ".owner.lock",
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (owner->lock_fd < 0) goto failed;
  struct stat lock;
  if (fstat(owner->lock_fd, &lock) != 0 || !S_ISREG(lock.st_mode) ||
      lock.st_nlink != 1 || lock.st_uid != geteuid() || (lock.st_mode & 077) != 0) goto failed;
  owner->lock_device = lock.st_dev; owner->lock_inode = lock.st_ino;
  if (flock(owner->lock_fd, LOCK_EX | LOCK_NB) != 0) {
    *failure = (errno == EWOULDBLOCK || errno == EAGAIN) ? CONFLICT : STORAGE;
    goto failed;
  }
  const char *children[] = {"demo_v1", "local_v1"};
  for (int i = 0; i < 2; ++i) {
    if (owner->count >= MAX_PINS ||
        (mkdirat(parent, children[i], 0700) != 0 && errno != EEXIST)) goto failed;
    int fd = openat(parent, children[i], O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) goto failed;
    struct stat metadata;
    if (fstat(fd, &metadata) != 0 || metadata.st_uid != geteuid()) { close(fd); goto failed; }
    char named[PATH_MAX];
    if (snprintf(named, sizeof(named), "%s/%s", path, children[i]) >= PATH_MAX) { close(fd); goto failed; }
    char *stored_path = strdup(named);
    if (!stored_path) { close(fd); *failure = STORAGE; goto failed; }
    Pin *pin = &owner->pins[owner->count++];
    pin->fd = fd; pin->device = metadata.st_dev; pin->inode = metadata.st_ino; pin->path = stored_path;
  }
  if (ustc_posix_owner_check(owner) != 0) { *failure = LOST; goto failed; }
  *failure = 0;
  return owner;
failed:
  if (drain(owner) != 0) *failure = LOST;
  return NULL;
}

// Existing descendants are checked relative to a pinned root. Missing leaves
// are acceptable for a checked path, but creating requires an existing parent.
API int ustc_posix_child(Owner *owner, const char *relative, int directory, int create) {
  if (ustc_posix_owner_check(owner) != 0) return LOST;
  if (!safe_relative(relative) || (create && !directory)) return UNSAFE;
  char parts[PATH_MAX];
  strcpy(parts, relative);
  char *remaining = NULL;
  char *part = strtok_r(parts, "/", &remaining);
  int root_fd = owner->pins[owner->root_index].fd;
  int parent = root_fd;
  int result = 0;
  for (;;) {
    char *next = strtok_r(NULL, "/", &remaining);
    int want_directory = next != NULL || directory;
    if (create && next == NULL && mkdirat(parent, part, 0700) != 0 && errno != EEXIST) {
      result = STORAGE; break;
    }
    struct stat item;
    if (fstatat(parent, part, &item, AT_SYMLINK_NOFOLLOW) != 0) {
      result = errno == ENOENT && !create ? 0 : UNSAFE;
      break;
    }
    if (item.st_uid != geteuid() ||
        (want_directory ? !S_ISDIR(item.st_mode) : !S_ISREG(item.st_mode) || item.st_nlink != 1)) {
      result = UNSAFE; break;
    }
    if (!next) break;
    int child = openat(parent, part, O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (child < 0) { result = UNSAFE; break; }
    if (parent != root_fd) close(parent);
    parent = child;
    part = next;
  }
  if (parent != root_fd && close(parent) != 0) result = LOST;
  if (result == LOST) owner->lost = 1;
  if (result == 0) result = ustc_posix_owner_check(owner);
  return result;
}

API int ustc_posix_owner_release(Owner *owner) {
  return owner ? drain(owner) : LOST;
}
