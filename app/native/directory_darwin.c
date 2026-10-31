#define _DARWIN_C_SOURCE 1

#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef O_SEARCH
#error "directory_darwin.c requires Darwin O_SEARCH"
#endif

#define API __attribute__((visibility("default")))
#define UNSAFE 1
#define CONFLICT 2
#define STORAGE 3
#define LOST 4
#define MAX_PINS (PATH_MAX / 2 + 2)
// Search-only ancestors need no directory-listing permission. O_EVTONLY still
// requests read access on Darwin and fails for sandbox/container ancestors.
#define DIRECTORY_FLAGS (O_SEARCH | O_CLOEXEC | O_NOFOLLOW)

typedef struct {
  int fd;
  dev_t device;
  ino_t inode;
  int parent_index;
  int require_owner;
  char component[NAME_MAX + 1];
  char *path;
} Pin;

typedef struct Owner {
  Pin pins[MAX_PINS];
  int count;
  int root_index;
  int lock_fd;
  dev_t lock_device;
  ino_t lock_inode;
  int lost;
} Owner;

static int safe_component(const char *component, size_t length) {
  if (!component || length == 0 || length > NAME_MAX ||
      (length == 1 && component[0] == '.') ||
      (length == 2 && component[0] == '.' && component[1] == '.')) {
    return 0;
  }
  for (size_t i = 0; i < length; ++i) {
    const unsigned char c = (unsigned char)component[i];
    if (c == '\\' || c < 32 || c == 127) return 0;
  }
  return 1;
}

static int safe_absolute_path(const char *path) {
  if (!path) return 0;
  const size_t length = strnlen(path, PATH_MAX);
  if (length < 2 || length >= PATH_MAX || path[0] != '/' ||
      path[1] == '/' || path[length - 1] == '/') {
    return 0;
  }

  const char *part = path + 1;
  for (const char *cursor = part;; ++cursor) {
    if (*cursor == '/' || *cursor == '\0') {
      const size_t part_length = (size_t)(cursor - part);
      if (!safe_component(part, part_length)) return 0;
      if (*cursor == '\0') return 1;
      part = cursor + 1;
    }
  }
}

static int safe_relative_path(const char *path) {
  if (!path) return 0;
  const size_t length = strnlen(path, PATH_MAX);
  if (length == 0 || length >= PATH_MAX || path[0] == '/' ||
      path[length - 1] == '/') {
    return 0;
  }

  const char *part = path;
  for (const char *cursor = path;; ++cursor) {
    if (*cursor == '/' || *cursor == '\0') {
      const size_t part_length = (size_t)(cursor - part);
      if (!safe_component(part, part_length)) return 0;
      if (*cursor == '\0') return 1;
      part = cursor + 1;
    }
  }
}

static int unsafe_path_errno(int error) {
  return error == EACCES || error == ELOOP || error == ENAMETOOLONG ||
         error == ENOENT || error == ENOTDIR;
}

static char *joined_path(const char *parent, const char *component) {
  char buffer[PATH_MAX];
  const int written = strcmp(parent, "/") == 0
      ? snprintf(buffer, sizeof(buffer), "/%s", component)
      : snprintf(buffer, sizeof(buffer), "%s/%s", parent, component);
  if (written < 0 || (size_t)written >= sizeof(buffer)) return NULL;
  return strdup(buffer);
}

static int add_pin(Owner *owner, int fd, int parent_index,
                   const char *component, const char *path,
                   const struct stat *metadata, int require_owner) {
  if (owner->count >= MAX_PINS) return UNSAFE;
  Pin *pin = &owner->pins[owner->count];
  const size_t component_length = component ? strlen(component) : 0;
  if (component_length > NAME_MAX) return UNSAFE;
  pin->path = strdup(path);
  if (!pin->path) return STORAGE;
  pin->fd = fd;
  pin->device = metadata->st_dev;
  pin->inode = metadata->st_ino;
  pin->parent_index = parent_index;
  pin->require_owner = require_owner;
  if (component_length != 0) {
    memcpy(pin->component, component, component_length);
  }
  pin->component[component_length] = '\0';
  owner->count++;
  return 0;
}

static int close_once(int fd) {
  return fd < 0 || close(fd) == 0 ? 0 : LOST;
}

static int drain(Owner *owner) {
  int failed = 0;
  if (!owner) return LOST;
  if (owner->lock_fd >= 0 && close_once(owner->lock_fd) != 0) failed = 1;
  for (int i = owner->count - 1; i >= 0; --i) {
    if (close_once(owner->pins[i].fd) != 0) failed = 1;
    free(owner->pins[i].path);
  }
  free(owner);
  return failed ? LOST : 0;
}

static int pin_is_current(Owner *owner, int index) {
  Pin *pin = &owner->pins[index];
  struct stat held, named;
  if (fstat(pin->fd, &held) != 0 || !S_ISDIR(held.st_mode) ||
      held.st_dev != pin->device || held.st_ino != pin->inode ||
      (pin->require_owner && held.st_uid != geteuid())) {
    return 0;
  }

  int status;
  if (pin->parent_index < 0) {
    status = fstatat(AT_FDCWD, pin->path, &named, AT_SYMLINK_NOFOLLOW);
  } else {
    status = fstatat(owner->pins[pin->parent_index].fd, pin->component,
                     &named, AT_SYMLINK_NOFOLLOW);
  }
  return status == 0 && S_ISDIR(named.st_mode) &&
         named.st_dev == pin->device && named.st_ino == pin->inode &&
         (!pin->require_owner || named.st_uid == geteuid());
}

static int lock_is_current(Owner *owner) {
  struct stat held, named;
  const int root_fd = owner->pins[owner->root_index].fd;
  if (owner->lock_fd < 0 || fstat(owner->lock_fd, &held) != 0 ||
      fstatat(root_fd, ".owner.lock", &named, AT_SYMLINK_NOFOLLOW) != 0) {
    return 0;
  }
  if (!S_ISREG(held.st_mode) || !S_ISREG(named.st_mode) ||
      held.st_nlink != 1 || named.st_nlink != 1 ||
      (held.st_mode & 0777) != 0600 || (named.st_mode & 0777) != 0600 ||
      held.st_uid != geteuid() || named.st_uid != geteuid() ||
      held.st_dev != owner->lock_device || held.st_ino != owner->lock_inode ||
      named.st_dev != owner->lock_device || named.st_ino != owner->lock_inode) {
    return 0;
  }
  return flock(owner->lock_fd, LOCK_EX | LOCK_NB) == 0;
}

API int ustc_darwin_owner_check(Owner *owner) {
  if (!owner || owner->lost) return LOST;
  for (int i = 0; i < owner->count; ++i) {
    if (!pin_is_current(owner, i)) goto lost;
  }
  if (!lock_is_current(owner)) goto lost;
  return 0;

lost:
  owner->lost = 1;
  return LOST;
}

static void close_and_record(int fd, int *failure) {
  if (close_once(fd) != 0) *failure = LOST;
}

static int open_root_and_ancestors(Owner *owner, const char *path,
                                   int *failure) {
  struct stat metadata;
  const int root_fd = open("/", DIRECTORY_FLAGS);
  if (root_fd < 0) {
    *failure = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
    return 0;
  }
  if (fstat(root_fd, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) {
    close_and_record(root_fd, failure);
    if (*failure != LOST) *failure = STORAGE;
    return 0;
  }
  int result = add_pin(owner, root_fd, -1, "", "/", &metadata, 0);
  if (result != 0) {
    close_and_record(root_fd, failure);
    if (*failure != LOST) *failure = result;
    return 0;
  }

  int parent_index = 0;
  const char *part = path + 1;
  while (*part) {
    const char *separator = strchr(part, '/');
    const size_t component_length = separator
        ? (size_t)(separator - part)
        : strlen(part);
    char component[NAME_MAX + 1];
    memcpy(component, part, component_length);
    component[component_length] = '\0';

    const int fd = openat(owner->pins[parent_index].fd, component,
                          DIRECTORY_FLAGS);
    if (fd < 0) {
      *failure = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
      return 0;
    }
    if (fstat(fd, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) {
      close_and_record(fd, failure);
      if (*failure != LOST) *failure = STORAGE;
      return 0;
    }
    char *full_path = joined_path(owner->pins[parent_index].path, component);
    if (!full_path) {
      close_and_record(fd, failure);
      if (*failure != LOST) *failure = STORAGE;
      return 0;
    }
    result = add_pin(owner, fd, parent_index, component, full_path,
                     &metadata, 0);
    free(full_path);
    if (result != 0) {
      close_and_record(fd, failure);
      if (*failure != LOST) *failure = result;
      return 0;
    }
    parent_index = owner->count - 1;
    if (!separator) break;
    part = separator + 1;
  }

  owner->root_index = parent_index;
  if (fstat(owner->pins[owner->root_index].fd, &metadata) != 0) {
    *failure = STORAGE;
    return 0;
  }
  if (metadata.st_uid != geteuid()) {
    *failure = UNSAFE;
    return 0;
  }
  owner->pins[owner->root_index].require_owner = 1;
  return 1;
}

static int open_owner_lock(Owner *owner, int *failure) {
  const int root_fd = owner->pins[owner->root_index].fd;
  int created = 1;
  int fd = openat(root_fd, ".owner.lock",
                  O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0 && errno == EEXIST) {
    created = 0;
    fd = openat(root_fd, ".owner.lock",
                O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  }
  if (fd < 0) {
    *failure = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
    return 0;
  }
  owner->lock_fd = fd;
  if (created && fchmod(fd, 0600) != 0) {
    *failure = STORAGE;
    return 0;
  }

  struct stat metadata, named;
  if (fstat(fd, &metadata) != 0 ||
      fstatat(root_fd, ".owner.lock", &named, AT_SYMLINK_NOFOLLOW) != 0) {
    *failure = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
    return 0;
  }
  if (!S_ISREG(metadata.st_mode) || !S_ISREG(named.st_mode) ||
      metadata.st_nlink != 1 || named.st_nlink != 1 ||
      (metadata.st_mode & 0777) != 0600 || (named.st_mode & 0777) != 0600 ||
      metadata.st_uid != geteuid() || named.st_uid != geteuid() ||
      metadata.st_dev != named.st_dev || metadata.st_ino != named.st_ino) {
    *failure = UNSAFE;
    return 0;
  }
  owner->lock_device = metadata.st_dev;
  owner->lock_inode = metadata.st_ino;
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    *failure = (errno == EWOULDBLOCK || errno == EAGAIN) ? CONFLICT : STORAGE;
    return 0;
  }
  return 1;
}

static int add_fixed_child(Owner *owner, const char *component,
                           int *failure) {
  const int root_index = owner->root_index;
  const int root_fd = owner->pins[root_index].fd;
  if (mkdirat(root_fd, component, 0700) != 0 && errno != EEXIST) {
    *failure = STORAGE;
    return 0;
  }
  const int fd = openat(root_fd, component, DIRECTORY_FLAGS);
  if (fd < 0) {
    *failure = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
    return 0;
  }
  struct stat metadata, named;
  if (fstat(fd, &metadata) != 0 ||
      fstatat(root_fd, component, &named, AT_SYMLINK_NOFOLLOW) != 0) {
    const int error = errno;
    close_and_record(fd, failure);
    if (*failure != LOST) *failure = unsafe_path_errno(error) ? UNSAFE : STORAGE;
    return 0;
  }
  if (!S_ISDIR(metadata.st_mode) || !S_ISDIR(named.st_mode) ||
      metadata.st_uid != geteuid() || named.st_uid != geteuid() ||
      metadata.st_dev != named.st_dev || metadata.st_ino != named.st_ino) {
    *failure = UNSAFE;
    close_and_record(fd, failure);
    return 0;
  }
  char *full_path = joined_path(owner->pins[root_index].path, component);
  if (!full_path) {
    *failure = STORAGE;
    close_and_record(fd, failure);
    return 0;
  }
  const int result = add_pin(owner, fd, root_index, component, full_path,
                             &metadata, 1);
  free(full_path);
  if (result != 0) {
    *failure = result;
    close_and_record(fd, failure);
    return 0;
  }
  return 1;
}

API Owner *ustc_darwin_owner_acquire(const char *path, int *failure) {
  if (!failure) return NULL;
  *failure = UNSAFE;
  if (!safe_absolute_path(path)) return NULL;

  Owner *owner = calloc(1, sizeof(Owner));
  if (!owner) {
    *failure = STORAGE;
    return NULL;
  }
  owner->lock_fd = -1;
  owner->root_index = -1;

  if (!open_root_and_ancestors(owner, path, failure) ||
      !open_owner_lock(owner, failure) ||
      !add_fixed_child(owner, "demo_v1", failure) ||
      !add_fixed_child(owner, "local_v1", failure)) {
    if (drain(owner) != 0) *failure = LOST;
    return NULL;
  }
  if (ustc_darwin_owner_check(owner) != 0) {
    *failure = LOST;
    if (drain(owner) != 0) *failure = LOST;
    return NULL;
  }
  *failure = 0;
  return owner;
}

// Existing descendants are checked relative to the pinned root. A missing
// descendant is acceptable for a checked path; creation is limited to a leaf
// directory whose parent already exists.
API int ustc_darwin_owner_child(Owner *owner, const char *relative,
                               int directory, int create) {
  if (ustc_darwin_owner_check(owner) != 0) return LOST;
  if (!safe_relative_path(relative) || (create && !directory)) return UNSAFE;

  char parts[PATH_MAX];
  const size_t length = strlen(relative);
  memcpy(parts, relative, length + 1);
  char *part = parts;
  int parent_fd = owner->pins[owner->root_index].fd;
  int temporary_fd = -1;
  int result = 0;

  for (;;) {
    char *separator = strchr(part, '/');
    const int final = separator == NULL;
    if (separator) *separator = '\0';
    const int want_directory = !final || directory;

    if (create && final &&
        mkdirat(parent_fd, part, 0700) != 0 && errno != EEXIST) {
      result = STORAGE;
      break;
    }

    struct stat named;
    if (fstatat(parent_fd, part, &named, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno == ENOENT && !create) {
        result = 0;
      } else {
        result = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
      }
      break;
    }
    if (named.st_uid != geteuid() ||
        (want_directory ? !S_ISDIR(named.st_mode)
                        : !S_ISREG(named.st_mode) || named.st_nlink != 1)) {
      result = UNSAFE;
      break;
    }
    if (final) break;

    const int child_fd = openat(parent_fd, part, DIRECTORY_FLAGS);
    if (child_fd < 0) {
      result = unsafe_path_errno(errno) ? UNSAFE : STORAGE;
      break;
    }
    struct stat held;
    if (fstat(child_fd, &held) != 0) {
      result = STORAGE;
      close_and_record(child_fd, &result);
      break;
    }
    if (!S_ISDIR(held.st_mode) || held.st_uid != geteuid() ||
        held.st_dev != named.st_dev || held.st_ino != named.st_ino) {
      result = UNSAFE;
      close_and_record(child_fd, &result);
      break;
    }
    if (temporary_fd >= 0) {
      const int previous_fd = temporary_fd;
      temporary_fd = -1;
      if (close_once(previous_fd) != 0) {
        result = LOST;
        close_and_record(child_fd, &result);
        break;
      }
    }
    temporary_fd = child_fd;
    parent_fd = child_fd;
    part = separator + 1;
  }

  if (temporary_fd >= 0) {
    const int final_fd = temporary_fd;
    temporary_fd = -1;
    if (close_once(final_fd) != 0) result = LOST;
  }
  if (result == LOST) owner->lost = 1;
  if (result == 0) result = ustc_darwin_owner_check(owner);
  return result;
}

API int ustc_darwin_owner_release(Owner *owner) {
  return owner ? drain(owner) : LOST;
}

// NativeFinalizer runs without a Dart isolate. It only drains this owner's
// descriptors and memory; explicit release detaches it before consuming token.
API void ustc_darwin_owner_finalize(void *token) {
  if (token) drain((Owner *)token);
}
