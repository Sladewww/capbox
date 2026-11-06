/*
 * capbox-drop-priv — numeric uid/gid drop then exec.
 *
 * Built on the host with `gcc -static` (or cc -static) so the binary can run
 * inside Alpine/musl guests without depending on guest util-linux/python/su
 * passwd entries. Source of truth is this file; never commit the binary.
 *
 * usage: capbox-drop-priv UID GID PROG [ARGS...]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char *end = NULL;
  uid_t uid;
  gid_t gid;
  gid_t gids[1];

  if (argc < 4) {
    fprintf(stderr, "usage: capbox-drop-priv UID GID PROG [ARGS...]\n");
    return 2;
  }

  errno = 0;
  {
    unsigned long long raw = strtoull(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' || raw > 0xFFFFFFFFull) {
      fprintf(stderr, "capbox-drop-priv: invalid uid: %s\n", argv[1]);
      return 2;
    }
    uid = (uid_t)raw;
  }
  errno = 0;
  {
    unsigned long long raw = strtoull(argv[2], &end, 10);
    if (errno != 0 || end == argv[2] || *end != '\0' || raw > 0xFFFFFFFFull) {
      fprintf(stderr, "capbox-drop-priv: invalid gid: %s\n", argv[2]);
      return 2;
    }
    gid = (gid_t)raw;
  }

  if (setgid(gid) != 0) {
    fprintf(stderr, "capbox-drop-priv: setgid(%u): %s\n",
            (unsigned)gid, strerror(errno));
    return 1;
  }
  gids[0] = gid;
  /* Keep going only when no supplementary group other than the target remains.
     setgroups is denied in some user namespaces; leftover gid 0 is not a drop. */
  if (setgroups(1, gids) != 0) {
    gid_t cur[64];
    int n = getgroups(64, cur);
    int i;
    if (n < 0) {
      fprintf(stderr, "capbox-drop-priv: getgroups: %s\n", strerror(errno));
      return 1;
    }
    for (i = 0; i < n; i++) {
      if (cur[i] != gid) {
        fprintf(stderr, "capbox-drop-priv: setgroups(%u) failed and other groups remain\n",
                (unsigned)gid);
        return 1;
      }
    }
  }
  if (setuid(uid) != 0) {
    fprintf(stderr, "capbox-drop-priv: setuid(%u): %s\n",
            (unsigned)uid, strerror(errno));
    return 1;
  }

  execvp(argv[3], &argv[3]);
  fprintf(stderr, "capbox-drop-priv: execvp(%s): %s\n", argv[3], strerror(errno));
  return 127;
}
