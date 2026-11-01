#define _DARWIN_C_SOURCE 1

#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <removefile.h>
#include <sandbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef O_SEARCH
#error "This harness must be compiled and run on macOS"
#endif

#define UNSAFE 1
#define CONFLICT 2
#define LOST 4
#define REQUIRED_RELATIVE "Library/Application Support/ustc_assistant_v1"

enum {
  STAGE_INVALID = 0,
  STAGE_CONTAINER = 1,
  STAGE_LIBRARY = 2,
  STAGE_SUPPORT = 3,
  STAGE_ROOT = 4,
  STAGE_LOCK = 5,
  STAGE_DEMO = 6,
  STAGE_FORMAL = 7,
  STAGE_CHECK = 8,
  STAGE_READY = 9
};

typedef struct Owner Owner;
extern Owner *ustc_darwin_owner_acquire(const char *container,
                                        const char *relative, int *failure,
                                        int *stage);
extern int ustc_darwin_owner_check(Owner *owner);
extern int ustc_darwin_owner_child(Owner *owner, const char *relative,
                                   int directory, int create);
extern int ustc_darwin_owner_release(Owner *owner);
extern void ustc_darwin_owner_finalize(void *token);

static char temp_root[PATH_MAX];
static char executable_path[PATH_MAX];

static void fail_at(const char *expression, int line) {
  fprintf(stderr, "FAIL line %d: %s (errno=%d)\n", line, expression, errno);
  exit(EXIT_FAILURE);
}

#define REQUIRE(expression) \
  do { if (!(expression)) fail_at(#expression, __LINE__); } while (0)

static void path_join(char *out, size_t capacity, const char *left,
                      const char *right) {
  const int written = snprintf(out, capacity, "%s/%s", left, right);
  REQUIRE(written >= 0 && (size_t)written < capacity);
}

static void make_dir(const char *path, mode_t mode) {
  REQUIRE(mkdir(path, mode) == 0);
}

static void app_root(const char *container, char *root_path) {
  char library[PATH_MAX];
  char support[PATH_MAX];
  path_join(library, sizeof(library), container, "Library");
  path_join(support, sizeof(support), library, "Application Support");
  path_join(root_path, PATH_MAX, support, "ustc_assistant_v1");
}

static void make_app_tree(const char *container) {
  char library[PATH_MAX];
  char support[PATH_MAX];
  char root_path[PATH_MAX];
  path_join(library, sizeof(library), container, "Library");
  make_dir(library, 0700);
  path_join(support, sizeof(support), library, "Application Support");
  make_dir(support, 0700);
  path_join(root_path, sizeof(root_path), support, "ustc_assistant_v1");
  make_dir(root_path, 0700);
}

static void make_container(const char *name, char *case_path,
                           char *container_path, char *root_path) {
  path_join(case_path, PATH_MAX, temp_root, name);
  make_dir(case_path, 0700);
  path_join(container_path, PATH_MAX, case_path, "container");
  make_dir(container_path, 0700);
  make_app_tree(container_path);
  app_root(container_path, root_path);
}

static Owner *acquire_ok(const char *container) {
  int failure = 0;
  int stage = 0;
  Owner *owner = ustc_darwin_owner_acquire(container, REQUIRED_RELATIVE,
                                           &failure, &stage);
  if (!owner || failure != 0 || stage != STAGE_READY) {
    fail_at("owner acquire reaches ready", __LINE__);
  }
  return owner;
}

static void acquire_fails(const char *container, const char *relative,
                          int expected_failure, int expected_stage) {
  int failure = 0;
  int stage = -1;
  Owner *owner = ustc_darwin_owner_acquire(container, relative, &failure,
                                           &stage);
  REQUIRE(owner == NULL);
  REQUIRE(failure == expected_failure);
  if (expected_stage >= 0) REQUIRE(stage == expected_stage);
}

static int exec_child(const char *mode, const char *path) {
  const pid_t child = fork();
  REQUIRE(child >= 0);
  if (child == 0) {
    execl(executable_path, executable_path, mode, path, (char *)NULL);
    _exit(127);
  }
  int status = 0;
  REQUIRE(waitpid(child, &status, 0) == child);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

static void sandbox_root_open_and_metadata(void) {
  const char profile[] =
      "(version 1)\n"
      "(allow default)\n"
      "(deny file-read* (literal \"/\"))\n";
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
  const int result = sandbox_init(profile, 0, NULL);
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
  REQUIRE(result == 0);

  errno = 0;
  const int root_fd = open("/", O_SEARCH | O_CLOEXEC);
  REQUIRE(root_fd < 0);
  REQUIRE(errno == EPERM || errno == EACCES);

  struct stat metadata;
  errno = 0;
  REQUIRE(stat("/", &metadata) != 0);
  REQUIRE(errno == EPERM || errno == EACCES);
}

static int child_mode(const char *mode, const char *container) {
  if (strcmp(mode, "--sandbox-anchor") == 0) {
    sandbox_root_open_and_metadata();
    Owner *owner = acquire_ok(container);
    REQUIRE(ustc_darwin_owner_check(owner) == 0);
    REQUIRE(ustc_darwin_owner_release(owner) == 0);
    return 0;
  }

  int failure = 0;
  int stage = 0;
  Owner *owner = ustc_darwin_owner_acquire(container, REQUIRED_RELATIVE,
                                           &failure, &stage);
  if (strcmp(mode, "--expect-conflict") == 0) {
    if (owner) {
      (void)ustc_darwin_owner_release(owner);
      return 10;
    }
    return failure == CONFLICT && stage == STAGE_LOCK ? 0 : 11;
  }
  if (strcmp(mode, "--exit-with-lock") == 0) {
    if (!owner) return 12;
    // The exec'd process exits without release. Kernel close must drop flock.
    _exit(0);
  }
  return 13;
}

static void test_only_search_permission(void) {
  char case_path[PATH_MAX];
  path_join(case_path, sizeof(case_path), temp_root, "search-only");
  make_dir(case_path, 0700);
  // The container itself remains accessible; its parent is searchable, not readable.
  char search_path[PATH_MAX];
  path_join(search_path, sizeof(search_path), case_path, "search");
  make_dir(search_path, 0700);
  char container_path[PATH_MAX];
  path_join(container_path, sizeof(container_path), search_path, "container");
  make_dir(container_path, 0700);
  make_app_tree(container_path);
  REQUIRE(chmod(search_path, 0111) == 0);
  Owner *owner = acquire_ok(container_path);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
  REQUIRE(chmod(search_path, 0700) == 0);
}

static void test_mutual_exclusion_and_release(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("lock", case_path, container_path, root_path);
  Owner *owner = acquire_ok(container_path);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(exec_child("--expect-conflict", container_path) == 0);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
  owner = acquire_ok(container_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
  REQUIRE(exec_child("--exit-with-lock", container_path) == 0);
  owner = acquire_ok(container_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_finalizer_drains_lease(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("finalizer", case_path, container_path, root_path);
  Owner *owner = acquire_ok(container_path);
  ustc_darwin_owner_finalize(owner);
  owner = acquire_ok(container_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_softlink_and_hardlink_rejection(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("links", case_path, container_path, root_path);
  char target[PATH_MAX], alias[PATH_MAX], bad_path[PATH_MAX];
  path_join(target, sizeof(target), case_path, "target");
  make_dir(target, 0700);
  path_join(alias, sizeof(alias), case_path, "alias");
  REQUIRE(symlink(target, alias) == 0);
  acquire_fails(alias, REQUIRED_RELATIVE, UNSAFE, STAGE_CONTAINER);

  path_join(bad_path, sizeof(bad_path), root_path, ".owner.lock");
  REQUIRE(symlink(target, bad_path) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_LOCK);
  REQUIRE(unlink(bad_path) == 0);

  int fd = open(bad_path, O_CREAT | O_EXCL | O_RDWR, 0600);
  REQUIRE(fd >= 0);
  REQUIRE(close(fd) == 0);
  path_join(alias, sizeof(alias), case_path, "lock-hardlink");
  REQUIRE(link(bad_path, alias) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_LOCK);
}

static void test_invalid_container_relative_and_inner_links(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("invalid-paths", case_path, container_path, root_path);
  acquire_fails(container_path,
                "Library/../Application Support/ustc_assistant_v1", UNSAFE,
                STAGE_INVALID);
  acquire_fails(container_path, NULL, UNSAFE, STAGE_INVALID);
  acquire_fails(container_path, "Library/Application Support/other", UNSAFE,
                STAGE_INVALID);
  acquire_fails("relative-container", REQUIRED_RELATIVE, UNSAFE,
                STAGE_INVALID);

  char target[PATH_MAX], library[PATH_MAX], support[PATH_MAX];
  path_join(target, sizeof(target), case_path, "external");
  make_dir(target, 0700);
  path_join(library, sizeof(library), container_path, "Library");
  path_join(support, sizeof(support), library, "Application Support");

  char library_saved[PATH_MAX];
  path_join(library_saved, sizeof(library_saved), case_path, "saved-library");
  REQUIRE(rename(library, library_saved) == 0);
  REQUIRE(symlink(target, library) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_LIBRARY);
  REQUIRE(unlink(library) == 0);
  REQUIRE(rename(library_saved, library) == 0);

  char support_saved[PATH_MAX];
  path_join(support_saved, sizeof(support_saved), case_path, "saved-support");
  REQUIRE(rename(support, support_saved) == 0);
  REQUIRE(symlink(target, support) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_SUPPORT);
  REQUIRE(unlink(support) == 0);
  REQUIRE(rename(support_saved, support) == 0);

  char root_saved[PATH_MAX];
  path_join(root_saved, sizeof(root_saved), case_path, "saved-data-root");
  REQUIRE(rename(root_path, root_saved) == 0);
  REQUIRE(symlink(target, root_path) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_ROOT);
}

static void test_fixed_child_links(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("fixed-child-links", case_path, container_path, root_path);
  char target[PATH_MAX], demo[PATH_MAX], formal[PATH_MAX];
  path_join(target, sizeof(target), case_path, "external");
  make_dir(target, 0700);
  path_join(demo, sizeof(demo), root_path, "demo_v1");
  REQUIRE(symlink(target, demo) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_DEMO);
  REQUIRE(unlink(demo) == 0);

  make_dir(demo, 0700);
  path_join(formal, sizeof(formal), root_path, "local_v1");
  REQUIRE(symlink(target, formal) == 0);
  acquire_fails(container_path, REQUIRED_RELATIVE, UNSAFE, STAGE_FORMAL);
  REQUIRE(unlink(formal) == 0);
}

static void test_child_links_and_relative_paths(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("child-links", case_path, container_path, root_path);
  Owner *owner = acquire_ok(container_path);
  char local_path[PATH_MAX], target[PATH_MAX], link_path[PATH_MAX];
  path_join(local_path, sizeof(local_path), root_path, "local_v1");
  REQUIRE(ustc_darwin_owner_child(owner, "local_v1/jw.sqlite", 0, 0) == 0);
  const char *sidecars[] = {
    "jw.sqlite", "jw.sqlite-wal", "jw.sqlite-shm"
  };
  for (size_t i = 0; i < sizeof(sidecars) / sizeof(sidecars[0]); ++i) {
    path_join(link_path, sizeof(link_path), local_path, sidecars[i]);
    int sidecar_fd = open(link_path, O_CREAT | O_EXCL | O_RDWR, 0600);
    REQUIRE(sidecar_fd >= 0);
    REQUIRE(close(sidecar_fd) == 0);
    char relative[PATH_MAX];
    const int written = snprintf(relative, sizeof(relative), "local_v1/%s",
                                 sidecars[i]);
    REQUIRE(written >= 0 && (size_t)written < sizeof(relative));
    REQUIRE(ustc_darwin_owner_child(owner, relative, 0, 0) == 0);
  }
  path_join(target, sizeof(target), case_path, "target.db");
  int fd = open(target, O_CREAT | O_EXCL | O_RDWR, 0600);
  REQUIRE(fd >= 0);
  REQUIRE(close(fd) == 0);
  path_join(link_path, sizeof(link_path), local_path, "symbolic.db");
  REQUIRE(symlink(target, link_path) == 0);
  REQUIRE(ustc_darwin_owner_child(owner, "local_v1/symbolic.db", 0, 0) ==
          UNSAFE);

  path_join(link_path, sizeof(link_path), local_path, "hard.db");
  REQUIRE(link(target, link_path) == 0);
  REQUIRE(ustc_darwin_owner_child(owner, "local_v1/hard.db", 0, 0) ==
          UNSAFE);
  REQUIRE(ustc_darwin_owner_child(owner, "../outside", 0, 0) == UNSAFE);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_path_replacement(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("data-root-replacement", case_path, container_path,
                 root_path);
  Owner *owner = acquire_ok(container_path);
  char saved_root[PATH_MAX];
  path_join(saved_root, sizeof(saved_root), case_path, "old-root");
  REQUIRE(rename(root_path, saved_root) == 0);
  make_dir(root_path, 0700);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);

  make_container("container-replacement", case_path, container_path,
                 root_path);
  owner = acquire_ok(container_path);
  char saved_container[PATH_MAX];
  path_join(saved_container, sizeof(saved_container), case_path, "old-container");
  REQUIRE(rename(container_path, saved_container) == 0);
  REQUIRE(symlink(saved_container, container_path) == 0);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);

  make_container("child-replacement", case_path, container_path, root_path);
  owner = acquire_ok(container_path);
  char demo[PATH_MAX], saved_demo[PATH_MAX];
  path_join(demo, sizeof(demo), root_path, "demo_v1");
  path_join(saved_demo, sizeof(saved_demo), root_path, "old-demo");
  REQUIRE(rename(demo, saved_demo) == 0);
  make_dir(demo, 0700);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_lock_replacement(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("lock-replacement", case_path, container_path, root_path);
  Owner *owner = acquire_ok(container_path);
  char lock_path[PATH_MAX];
  path_join(lock_path, sizeof(lock_path), root_path, ".owner.lock");
  REQUIRE(unlink(lock_path) == 0);
  int fd = open(lock_path, O_CREAT | O_EXCL | O_RDWR, 0600);
  REQUIRE(fd >= 0);
  REQUIRE(close(fd) == 0);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_sandboxed_container_anchor(void) {
  char case_path[PATH_MAX], container_path[PATH_MAX], root_path[PATH_MAX];
  make_container("sandboxed-anchor", case_path, container_path, root_path);
  REQUIRE(exec_child("--sandbox-anchor", container_path) == 0);
  Owner *owner = acquire_ok(container_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

int main(int argc, char **argv) {
  if (argc == 3 && argv[1][0] == '-') return child_mode(argv[1], argv[2]);
  REQUIRE(argc == 1);
  REQUIRE(realpath(argv[0], executable_path) != NULL);
  char template_path[] = "/tmp/ios-i1-darwin-owner.XXXXXX";
  REQUIRE(mkdtemp(template_path) != NULL);
  REQUIRE(realpath(template_path, temp_root) != NULL);

  test_only_search_permission();
  test_mutual_exclusion_and_release();
  test_finalizer_drains_lease();
  test_softlink_and_hardlink_rejection();
  test_invalid_container_relative_and_inner_links();
  test_fixed_child_links();
  test_child_links_and_relative_paths();
  test_path_replacement();
  test_lock_replacement();
  test_sandboxed_container_anchor();

  struct stat metadata;
  REQUIRE(lstat(temp_root, &metadata) == 0 && S_ISDIR(metadata.st_mode));
  REQUIRE(removefile(temp_root, NULL, REMOVEFILE_RECURSIVE) == 0);
  puts("Darwin owner synthetic tests passed");
  return 0;
}
