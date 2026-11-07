#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif
#ifndef F_SEAL_EXEC
#define F_SEAL_EXEC 0x0020
#endif

extern char **environ;

static void run(const char *label, const char *path) {
  pid_t pid = fork();
  int status;
  if (pid == 0) {
    char *args[] = {(char *)path, NULL};
    execve(path, args, environ);
    dprintf(2, "%s exec: %s\n", label, strerror(errno));
    _exit(127);
  }
  if (pid < 0 || waitpid(pid, &status, 0) < 0) exit(1);
  printf("%s rc=%d\n", label, WIFEXITED(status) ? WEXITSTATUS(status) : 128);
  fflush(stdout);
}

int main(void) {
  const char script[] = "#!/bin/sh\nexit 0\n";
  char path[80], disk[] = "/tmp/capbox-script-probe.XXXXXX";
  int fd = memfd_create("capbox-script-probe", MFD_EXEC | MFD_ALLOW_SEALING);
  if (fd < 0) {
    printf("memfd_create: %s\n", strerror(errno));
  } else {
    if (write(fd, script, sizeof(script) - 1) < 0) return 1;
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW |
              F_SEAL_WRITE | F_SEAL_FUTURE_WRITE | F_SEAL_EXEC) < 0)
      printf("memfd seal: %s\n", strerror(errno));
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    run("memfd-script", path);
    close(fd);
  }
  fd = mkstemp(disk);
  if (fd < 0) return 1;
  if (write(fd, script, sizeof(script) - 1) < 0 || fchmod(fd, 0700) < 0) return 1;
  close(fd);
  run("disk-script", disk);
  unlink(disk);
  return 0;
}
