#define _DARWIN_C_SOURCE 1

#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef O_EVTONLY
#error "This harness must be compiled and run on macOS"
#endif

#define UNSAFE 1
#define CONFLICT 2
#define LOST 4

typedef struct Owner Owner;
extern Owner *ustc_darwin_owner_acquire(const char *path, int *failure);
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

static void make_root(const char *name, char *case_path, char *root_path) {
  path_join(case_path, PATH_MAX, temp_root, name);
  make_dir(case_path, 0700);
  path_join(root_path, PATH_MAX, case_path, "root");
  make_dir(root_path, 0700);
}

static Owner *acquire_ok(const char *path) {
  int failure = 0;
  Owner *owner = ustc_darwin_owner_acquire(path, &failure);
  if (!owner || failure != 0) fail_at("owner acquire succeeds", __LINE__);
  return owner;
}

static void acquire_fails(const char *path, int expected_failure) {
  int failure = 0;
  Owner *owner = ustc_darwin_owner_acquire(path, &failure);
  REQUIRE(owner == NULL);
  REQUIRE(failure == expected_failure);
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

static int child_mode(const char *mode, const char *path) {
  int failure = 0;
  Owner *owner = ustc_darwin_owner_acquire(path, &failure);
  if (strcmp(mode, "--expect-conflict") == 0) {
    if (owner) {
      (void)ustc_darwin_owner_release(owner);
      return 10;
    }
    return failure == CONFLICT ? 0 : 11;
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
  // Root itself must remain writable; make its parent searchable, not readable.
  char search_path[PATH_MAX];
  path_join(search_path, sizeof(search_path), case_path, "search");
  make_dir(search_path, 0700);
  char nested_root[PATH_MAX];
  path_join(nested_root, sizeof(nested_root), search_path, "root");
  make_dir(nested_root, 0700);
  REQUIRE(chmod(search_path, 0111) == 0);
  Owner *owner = acquire_ok(nested_root);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
  REQUIRE(chmod(search_path, 0700) == 0);
}

static void test_mutual_exclusion_and_release(void) {
  char case_path[PATH_MAX], root_path[PATH_MAX];
  make_root("lock", case_path, root_path);
  Owner *owner = acquire_ok(root_path);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(exec_child("--expect-conflict", root_path) == 0);
  REQUIRE(ustc_darwin_owner_check(owner) == 0);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
  owner = acquire_ok(root_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
  REQUIRE(exec_child("--exit-with-lock", root_path) == 0);
  owner = acquire_ok(root_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_finalizer_drains_lease(void) {
  char case_path[PATH_MAX], root_path[PATH_MAX];
  make_root("finalizer", case_path, root_path);
  Owner *owner = acquire_ok(root_path);
  ustc_darwin_owner_finalize(owner);
  owner = acquire_ok(root_path);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_softlink_and_hardlink_rejection(void) {
  char case_path[PATH_MAX], root_path[PATH_MAX];
  make_root("links", case_path, root_path);
  char target[PATH_MAX], alias[PATH_MAX], bad_path[PATH_MAX];
  path_join(target, sizeof(target), case_path, "target");
  make_dir(target, 0700);
  path_join(alias, sizeof(alias), case_path, "alias");
  REQUIRE(symlink(target, alias) == 0);
  path_join(bad_path, sizeof(bad_path), alias, "root");
  acquire_fails(bad_path, UNSAFE);

  path_join(bad_path, sizeof(bad_path), root_path, ".owner.lock");
  REQUIRE(symlink(target, bad_path) == 0);
  acquire_fails(root_path, UNSAFE);
  REQUIRE(unlink(bad_path) == 0);

  int fd = open(bad_path, O_CREAT | O_EXCL | O_RDWR, 0600);
  REQUIRE(fd >= 0);
  REQUIRE(close(fd) == 0);
  path_join(alias, sizeof(alias), case_path, "lock-hardlink");
  REQUIRE(link(bad_path, alias) == 0);
  acquire_fails(root_path, UNSAFE);
}

static void test_child_links_and_relative_paths(void) {
  char case_path[PATH_MAX], root_path[PATH_MAX];
  make_root("child-links", case_path, root_path);
  Owner *owner = acquire_ok(root_path);
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
  char case_path[PATH_MAX], root_path[PATH_MAX];
  make_root("root-replacement", case_path, root_path);
  Owner *owner = acquire_ok(root_path);
  char saved_root[PATH_MAX];
  path_join(saved_root, sizeof(saved_root), case_path, "old-root");
  REQUIRE(rename(root_path, saved_root) == 0);
  make_dir(root_path, 0700);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);

  path_join(case_path, sizeof(case_path), temp_root, "ancestor-replacement");
  make_dir(case_path, 0700);
  char parent[PATH_MAX];
  path_join(parent, sizeof(parent), case_path, "parent");
  make_dir(parent, 0700);
  path_join(root_path, sizeof(root_path), parent, "root");
  make_dir(root_path, 0700);
  owner = acquire_ok(root_path);
  char saved_parent[PATH_MAX];
  path_join(saved_parent, sizeof(saved_parent), case_path, "old-parent");
  REQUIRE(rename(parent, saved_parent) == 0);
  REQUIRE(symlink(saved_parent, parent) == 0);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);

  make_root("child-replacement", case_path, root_path);
  owner = acquire_ok(root_path);
  char demo[PATH_MAX], saved_demo[PATH_MAX];
  path_join(demo, sizeof(demo), root_path, "demo_v1");
  path_join(saved_demo, sizeof(saved_demo), root_path, "old-demo");
  REQUIRE(rename(demo, saved_demo) == 0);
  make_dir(demo, 0700);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
  REQUIRE(ustc_darwin_owner_release(owner) == 0);
}

static void test_lock_replacement(void) {
  char case_path[PATH_MAX], root_path[PATH_MAX];
  make_root("lock-replacement", case_path, root_path);
  Owner *owner = acquire_ok(root_path);
  char lock_path[PATH_MAX];
  path_join(lock_path, sizeof(lock_path), root_path, ".owner.lock");
  REQUIRE(unlink(lock_path) == 0);
  int fd = open(lock_path, O_CREAT | O_EXCL | O_RDWR, 0600);
  REQUIRE(fd >= 0);
  REQUIRE(close(fd) == 0);
  REQUIRE(ustc_darwin_owner_check(owner) == LOST);
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
  test_child_links_and_relative_paths();
  test_path_replacement();
  test_lock_replacement();

  struct stat metadata;
  REQUIRE(lstat(temp_root, &metadata) == 0 && S_ISDIR(metadata.st_mode));
  REQUIRE(removefile(temp_root, NULL, REMOVEFILE_RECURSIVE) == 0);
  puts("Darwin owner synthetic tests passed");
  return 0;
}
