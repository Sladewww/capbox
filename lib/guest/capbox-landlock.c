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

/* 用户可见文案编进二进制：两套静态中英文，不解析目录，也不读外部消息文件。 */
struct ll_msg {
  const char *reject_path;
  const char *cannot_open;
  const char *fstat_path;
  const char *no_access;
  const char *add_rule;
  const char *open_rules;
  const char *fdopen_rules;
  const char *line_too_long;
  const char *bad_format;
  const char *unknown_type;
  const char *too_many;
  const char *empty_rules;
  const char *no_landlock;
  const char *no_landlock_lsm;
  const char *rules_missing_path;
  const char *create_ruleset;
  const char *no_new_privs;
  const char *restrict_self;
  const char *exec_failed;
};

static const struct ll_msg msgs_zh = {
    "capbox-landlock: 拒绝规则路径 %s\n",
    "capbox-landlock: 打不开 %s: %s\n",
    "capbox-landlock: fstat %s: %s\n",
    "capbox-landlock: %s 没有可用的访问位\n",
    "capbox-landlock: 添加规则 %s 失败: %s\n",
    "capbox-landlock: 打不开规则 %s: %s\n",
    "capbox-landlock: fdopen 规则失败: %s\n",
    "capbox-landlock: 规则行过长\n",
    "capbox-landlock: 规则格式必须是 ro|rw 绝对路径\n",
    "capbox-landlock: 未知规则类型 %s\n",
    "capbox-landlock: 规则过多\n",
    "capbox-landlock: 规则为空\n",
    "capbox-landlock: 内核不支持 Landlock\n",
    "capbox-landlock: 内核不支持 Landlock（需要 5.13+ 且已启用 LSM）\n",
    "capbox-landlock: --rules 缺少路径\n",
    "capbox-landlock: 创建规则集失败: %s\n",
    "capbox-landlock: no_new_privs 失败: %s\n",
    "capbox-landlock: restrict_self 失败: %s\n",
    "capbox-landlock: exec %s 失败: %s\n",
};

static const struct ll_msg msgs_en = {
    "capbox-landlock: rejected rule path %s\n",
    "capbox-landlock: cannot open %s: %s\n",
    "capbox-landlock: fstat %s: %s\n",
    "capbox-landlock: %s has no usable access bits\n",
    "capbox-landlock: failed to add rule %s: %s\n",
    "capbox-landlock: cannot open rules %s: %s\n",
    "capbox-landlock: fdopen rules failed: %s\n",
    "capbox-landlock: rule line too long\n",
    "capbox-landlock: rule format must be ro|rw absolute path\n",
    "capbox-landlock: unknown rule type %s\n",
    "capbox-landlock: too many rules\n",
    "capbox-landlock: rules are empty\n",
    "capbox-landlock: kernel does not support Landlock\n",
    "capbox-landlock: kernel does not support Landlock (requires 5.13+ with LSM enabled)\n",
    "capbox-landlock: --rules is missing a path\n",
    "capbox-landlock: failed to create ruleset: %s\n",
    "capbox-landlock: no_new_privs failed: %s\n",
    "capbox-landlock: restrict_self failed: %s\n",
    "capbox-landlock: exec %s failed: %s\n",
};

/* 宿主已把 CAPBOX_UI_LANG 规范成 zh 或 en；未设置或其它值走英文。 */
static const struct ll_msg *ll_msgs(void) {
  const char *lang = getenv("CAPBOX_UI_LANG");
  if (lang != NULL && strcmp(lang, "zh") == 0)
    return &msgs_zh;
  return &msgs_en;
}

static int add_path(int ruleset, const char *path, __u64 access) {
  int fd;
  struct stat st;
  struct landlock_path_beneath_attr beneath;
  const struct ll_msg *m = ll_msgs();

  if (path[0] != '/' || strstr(path, "..") != NULL) {
    fprintf(stderr, m->reject_path, path);
    return -1;
  }
  fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, m->cannot_open, path, strerror(errno));
    return -1;
  }
  if (fstat(fd, &st) != 0) {
    fprintf(stderr, m->fstat_path, path, strerror(errno));
    close(fd);
    return -1;
  }
  access = mask_for_mode(st.st_mode, access);
  if (access == 0) {
    fprintf(stderr, m->no_access, path);
    close(fd);
    return -1;
  }
  memset(&beneath, 0, sizeof(beneath));
  beneath.allowed_access = access;
  beneath.parent_fd = fd;
  if (ll_add(ruleset, &beneath) != 0) {
    fprintf(stderr, m->add_rule, path, strerror(errno));
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
  const struct ll_msg *m = ll_msgs();

  /* O_NOFOLLOW: a swapped symlink is not a rules file. */
  fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, m->open_rules, file, strerror(errno));
    return -1;
  }
  fp = fdopen(fd, "r");
  if (fp == NULL) {
    fprintf(stderr, m->fdopen_rules, strerror(errno));
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
      fprintf(stderr, "%s", m->line_too_long);
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
      fprintf(stderr, "%s", m->bad_format);
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
      fprintf(stderr, m->unknown_type, mode);
      fclose(fp);
      return -1;
    }
    if (add_path(ruleset, path, access_for(rw, handled)) != 0) {
      fclose(fp);
      return -1;
    }
    count++;
    if (count > 4096) {
      fprintf(stderr, "%s", m->too_many);
      fclose(fp);
      return -1;
    }
  }
  fclose(fp);
  if (count == 0) {
    fprintf(stderr, "%s", m->empty_rules);
    return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  int abi;
  int ruleset;
  __u64 handled;
  const char *rules = NULL;
  int i;
  struct landlock_ruleset_attr attr;
  const struct ll_msg *m = ll_msgs();

  abi = probe_abi();
  if (argc >= 2 && strcmp(argv[1], "--probe") == 0) {
    if (abi < 1) {
      fprintf(stderr, "%s", m->no_landlock);
      return 5;
    }
    printf("%d\n", abi);
    return 0;
  }
  if (abi < 1) {
    fprintf(stderr, "%s", m->no_landlock_lsm);
    return 5;
  }

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--rules") == 0) {
      if (i + 1 >= argc) {
        fprintf(stderr, "%s", m->rules_missing_path);
        return 2;
      }
      rules = argv[++i];
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
    fprintf(stderr, m->create_ruleset, strerror(errno));
    return 1;
  }
  if (load_rules(ruleset, rules, handled) != 0) {
    close(ruleset);
    return 1;
  }
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    fprintf(stderr, m->no_new_privs, strerror(errno));
    close(ruleset);
    return 1;
  }
  if (ll_restrict(ruleset) != 0) {
    fprintf(stderr, m->restrict_self, strerror(errno));
    close(ruleset);
    return 1;
  }
  close(ruleset);
  execvp(argv[i], &argv[i]);
  fprintf(stderr, m->exec_failed, argv[i], strerror(errno));
  return 127;
}
