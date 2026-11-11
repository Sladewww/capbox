/*
 * capbox-landlock — apply a Landlock filesystem ruleset, then exec.
 *
 * Built on the host with `gcc -static`. The binary is ro-bound into the
 * guest and must run only after bwrap has finished mount setup: a process
 * in a filesystem Landlock domain cannot mount or pivot_root, so wrapping
 * bwrap itself makes setup fail.
 *
 * usage:
 *   capbox-landlock --probe
 *   capbox-landlock --rules FILE -- CMD [ARGS...]
 *
 * Rules file, one per line, no shell: "ro /abs" or "rw /abs".
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Host-translated printf formats. The helper never loads catalogs itself.
 * Missing --messages file keeps the English fallbacks below. */
#define LL_MSG_STORE 8192
#define LL_MSG_LINE 512

struct ll_msg {
  const char *key;
  const char *fallback;
  const char *text;
};

static struct ll_msg ll_msgs[] = {
  {"reject_path", "capbox-landlock: rejected rule path %s", NULL},
  {"open_failed", "capbox-landlock: cannot open %s: %s", NULL},
  {"no_access_bits", "capbox-landlock: %s has no usable access bits", NULL},
  {"add_rule_failed", "capbox-landlock: failed to add rule %s: %s", NULL},
  {"open_rules_failed", "capbox-landlock: cannot open rules %s: %s", NULL},
  {"fdopen_rules_failed", "capbox-landlock: fdopen of rules failed: %s", NULL},
  {"rule_line_too_long", "capbox-landlock: rule line too long", NULL},
  {"rule_format", "capbox-landlock: rule format must be ro|rw followed by an absolute path", NULL},
  {"unknown_rule_type", "capbox-landlock: unknown rule type %s", NULL},
  {"too_many_rules", "capbox-landlock: too many rules", NULL},
  {"rules_empty", "capbox-landlock: rules are empty", NULL},
  {"kernel_unsupported", "capbox-landlock: kernel does not support Landlock", NULL},
  {"kernel_unsupported_lsm", "capbox-landlock: kernel does not support Landlock (needs 5.13+ with the LSM enabled)", NULL},
  {"rules_missing_path", "capbox-landlock: --rules is missing a path", NULL},
  {"create_ruleset_failed", "capbox-landlock: failed to create ruleset: %s", NULL},
  {"no_new_privs_failed", "capbox-landlock: no_new_privs failed: %s", NULL},
  {"restrict_self_failed", "capbox-landlock: restrict_self failed: %s", NULL},
  {"exec_failed", "capbox-landlock: exec %s failed: %s", NULL},
  {NULL, NULL, NULL}
};

static char ll_msg_store[LL_MSG_STORE];

static const char *ll_m(const char *key) {
  size_t i;
  for (i = 0; ll_msgs[i].key != NULL; i++) {
    if (strcmp(ll_msgs[i].key, key) == 0)
      return ll_msgs[i].text != NULL ? ll_msgs[i].text : ll_msgs[i].fallback;
  }
  return key;
}

static void ll_load_messages(const char *file) {
  int fd;
  FILE *fp;
  char line[LL_MSG_LINE];
  size_t used = 0;

  if (file == NULL || file[0] == '\0')
    return;
  fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return;
  fp = fdopen(fd, "r");
  if (fp == NULL) {
    close(fd);
    return;
  }
  while (fgets(line, sizeof(line), fp) != NULL) {
    char *eq;
    char *val;
    char *nl;
    size_t i;
    size_t n;
    nl = strchr(line, '\n');
    if (nl)
      *nl = '\0';
    if (line[0] == '\0' || line[0] == '#')
      continue;
    eq = strchr(line, '=');
    if (eq == NULL)
      continue;
    *eq = '\0';
    val = eq + 1;
    n = strlen(val) + 1;
    if (used + n > sizeof(ll_msg_store))
      break;
    memcpy(ll_msg_store + used, val, n);
    for (i = 0; ll_msgs[i].key != NULL; i++) {
      if (strcmp(ll_msgs[i].key, line) == 0) {
        ll_msgs[i].text = ll_msg_store + used;
        break;
      }
    }
    used += n;
  }
  fclose(fp);
}

/* Stable UAPI bits: compile with older headers, enable only after ABI probing. */
#ifndef LANDLOCK_ACCESS_FS_REFER
#define LANDLOCK_ACCESS_FS_REFER (1ULL << 13)
#endif
#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif
#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif

static int ll_create(const struct landlock_ruleset_attr *attr, size_t size, __u32 flags) {
  return (int)syscall(__NR_landlock_create_ruleset, attr, size, flags);
}

static int ll_add(int fd, const void *attr) {
  return (int)syscall(__NR_landlock_add_rule, fd, LANDLOCK_RULE_PATH_BENEATH, attr, 0);
}

static int ll_restrict(int fd) {
  return (int)syscall(__NR_landlock_restrict_self, fd, 0);
}

static int probe_abi(void) {
  return ll_create(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
}

static __u64 handled_for_abi(int abi) {
  __u64 handled = LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |
                  LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
                  LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE |
                  LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR |
                  LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SOCK |
                  LANDLOCK_ACCESS_FS_MAKE_FIFO | LANDLOCK_ACCESS_FS_MAKE_BLOCK |
                  LANDLOCK_ACCESS_FS_MAKE_SYM;
  if (abi >= 2)
    handled |= LANDLOCK_ACCESS_FS_REFER;
  if (abi >= 3)
    handled |= LANDLOCK_ACCESS_FS_TRUNCATE;
  if (abi >= 5)
    handled |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
  return handled;
}

static __u64 access_for(int rw, __u64 handled) {
  __u64 ro = LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE |
             LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_IOCTL_DEV;
  if (!rw)
    return ro & handled;
  return handled;
}

/* Directory-only rights are rejected by the kernel when the rule inode is a file. */
static __u64 mask_for_mode(mode_t mode, __u64 access) {
  if (S_ISDIR(mode))
    return access;
  access &= ~(LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_REMOVE_DIR |
              LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR |
              LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG |
              LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO |
              LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM |
              LANDLOCK_ACCESS_FS_REFER);
  return access;
}

static int add_path(int ruleset, const char *path, __u64 access) {
  int fd;
  struct stat st;
  struct landlock_path_beneath_attr beneath;

  if (path[0] != '/' || strstr(path, "..") != NULL) {
    fprintf(stderr, ll_m("reject_path"), path);
    fputc('\n', stderr);
    return -1;
  }
  fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, ll_m("open_failed"), path, strerror(errno));
    fputc('\n', stderr);
    return -1;
  }
  if (fstat(fd, &st) != 0) {
    fprintf(stderr, "capbox-landlock: fstat %s: %s\n", path, strerror(errno));
    close(fd);
    return -1;
  }
  access = mask_for_mode(st.st_mode, access);
  if (access == 0) {
    fprintf(stderr, ll_m("no_access_bits"), path);
    fputc('\n', stderr);
    close(fd);
    return -1;
  }
  memset(&beneath, 0, sizeof(beneath));
  beneath.allowed_access = access;
  beneath.parent_fd = fd;
  if (ll_add(ruleset, &beneath) != 0) {
    fprintf(stderr, ll_m("add_rule_failed"), path, strerror(errno));
    fputc('\n', stderr);
    close(fd);
    return -1;
  }
  close(fd);
  return 0;
}

static int load_rules(int ruleset, const char *file, __u64 handled) {
  FILE *fp;
  char line[8192];
  int count = 0;
  int fd;

  /* O_NOFOLLOW: a swapped symlink is not a rules file. */
  fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, ll_m("open_rules_failed"), file, strerror(errno));
    fputc('\n', stderr);
    return -1;
  }
  fp = fdopen(fd, "r");
  if (fp == NULL) {
    fprintf(stderr, ll_m("fdopen_rules_failed"), strerror(errno));
    fputc('\n', stderr);
    close(fd);
    return -1;
  }

  while (fgets(line, sizeof(line), fp) != NULL) {
    char *p = line;
    char *mode;
    char *path;
    size_t n;
    int rw;

    n = strlen(p);
    if (n > 0 && p[n - 1] != '\n' && !feof(fp)) {
      fprintf(stderr, "%s\n", ll_m("rule_line_too_long"));
      fclose(fp);
      return -1;
    }
    while (*p == ' ' || *p == '\t')
      p++;
    n = strlen(p);
    while (n > 0 && (p[n - 1] == '\n' || p[n - 1] == '\r' || p[n - 1] == ' ' || p[n - 1] == '\t')) {
      p[--n] = '\0';
    }
    if (p[0] == '\0' || p[0] == '#')
      continue;
    mode = p;
    path = strpbrk(p, " \t");
    if (path == NULL) {
      fprintf(stderr, "%s\n", ll_m("rule_format"));
      fclose(fp);
      return -1;
    }
    *path++ = '\0';
    while (*path == ' ' || *path == '\t')
      path++;
    if (strcmp(mode, "ro") == 0)
      rw = 0;
    else if (strcmp(mode, "rw") == 0)
      rw = 1;
    else {
      fprintf(stderr, ll_m("unknown_rule_type"), mode);
      fputc('\n', stderr);
      fclose(fp);
      return -1;
    }
    if (add_path(ruleset, path, access_for(rw, handled)) != 0) {
      fclose(fp);
      return -1;
    }
    count++;
    if (count > 4096) {
      fprintf(stderr, "%s\n", ll_m("too_many_rules"));
      fclose(fp);
      return -1;
    }
  }
  fclose(fp);
  if (count == 0) {
    fprintf(stderr, "%s\n", ll_m("rules_empty"));
    return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  int abi;
  int ruleset;
  __u64 handled;
  const char *rules = NULL;
  const char *messages = NULL;
  int i;
  struct landlock_ruleset_attr attr;

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--messages") == 0 && i + 1 < argc) {
      messages = argv[i + 1];
      break;
    }
  }
  ll_load_messages(messages);

  abi = probe_abi();
  if (argc >= 2 && strcmp(argv[1], "--probe") == 0) {
    if (abi < 1) {
      fprintf(stderr, "%s\n", ll_m("kernel_unsupported"));
      return 5;
    }
    printf("%d\n", abi);
    return 0;
  }
  if (abi < 1) {
    fprintf(stderr, "%s\n", ll_m("kernel_unsupported_lsm"));
    return 5;
  }

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--rules") == 0) {
      if (i + 1 >= argc) {
        fprintf(stderr, "%s\n", ll_m("rules_missing_path"));
        return 2;
      }
      rules = argv[++i];
      continue;
    }
    if (strcmp(argv[i], "--messages") == 0) {
      if (i + 1 >= argc) {
        fprintf(stderr, "usage: capbox-landlock --rules FILE -- CMD [ARGS...]\n");
        return 2;
      }
      i++;
      continue;
    }
    if (strcmp(argv[i], "--") == 0) {
      i++;
      break;
    }
    fprintf(stderr, "usage: capbox-landlock --rules FILE -- CMD [ARGS...]\n");
    return 2;
  }
  if (rules == NULL || i >= argc) {
    fprintf(stderr, "usage: capbox-landlock --rules FILE -- CMD [ARGS...]\n");
    return 2;
  }

  handled = handled_for_abi(abi);
  memset(&attr, 0, sizeof(attr));
  attr.handled_access_fs = handled;
  ruleset = ll_create(&attr, sizeof(attr), 0);
  if (ruleset < 0) {
    fprintf(stderr, ll_m("create_ruleset_failed"), strerror(errno));
    fputc('\n', stderr);
    return 1;
  }
  if (load_rules(ruleset, rules, handled) != 0) {
    close(ruleset);
    return 1;
  }
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    fprintf(stderr, ll_m("no_new_privs_failed"), strerror(errno));
    fputc('\n', stderr);
    close(ruleset);
    return 1;
  }
  if (ll_restrict(ruleset) != 0) {
    fprintf(stderr, ll_m("restrict_self_failed"), strerror(errno));
    fputc('\n', stderr);
    close(ruleset);
    return 1;
  }
  close(ruleset);
  execvp(argv[i], &argv[i]);
  fprintf(stderr, ll_m("exec_failed"), argv[i], strerror(errno));
  fputc('\n', stderr);
  return 127;
}
