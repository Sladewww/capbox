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
  uid = (uid_t)strtoul(argv[1], &end, 10);
  if (errno != 0 || end == argv[1] || *end != '\0') {
    fprintf(stderr, "capbox-drop-priv: invalid uid: %s\n", argv[1]);
    return 2;
  }
  errno = 0;
  gid = (gid_t)strtoul(argv[2], &end, 10);
  if (errno != 0 || end == argv[2] || *end != '\0') {
    fprintf(stderr, "capbox-drop-priv: invalid gid: %s\n", argv[2]);
    return 2;
  }

  if (setgid(gid) != 0) {
    fprintf(stderr, "capbox-drop-priv: setgid(%u): %s\n",
            (unsigned)gid, strerror(errno));
    return 1;
  }
  gids[0] = gid;
  /* Best-effort clear+set supplementary groups (matches setpriv --clear-groups). */
  if (setgroups(1, gids) != 0) {
    /* Some profiles deny setgroups; continue with primary gid only. */
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
