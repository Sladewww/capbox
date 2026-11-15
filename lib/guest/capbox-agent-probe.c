/* Trusted command gate for a locked Agent sandbox. Built statically on the host. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/magic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Stable Linux UAPI bit for close_range(2). */
#define CLOSE_RANGE_CLOEXEC (1U << 2)

static int readonly_mount(const char *path)
{
    struct statvfs fs;
    return statvfs(path, &fs) == 0 && (fs.f_flag & ST_RDONLY) != 0;
}

static const char *check_protection(void)
{
    struct statfs proc;
    if (statfs("/proc", &proc) != 0 || proc.f_type != PROC_SUPER_MAGIC ||
        !readonly_mount("/proc"))
        return "procfs_read_only";

    const char *guarded[] = {
        "/proc/sys", "/proc/sysrq-trigger", "/proc/irq", "/proc/bus"
    };
    for (size_t i = 0; i < sizeof(guarded) / sizeof(guarded[0]); i++) {
        errno = 0;
        if (!readonly_mount(guarded[i]) && errno != ENOENT)
            return "procfs_submount";
    }
    if (!readonly_mount("/"))
        return "rootfs_read_only";
    const char *readonly = getenv("CAPBOX_AGENT_WORKSPACE_READONLY");
    if (readonly != NULL && strcmp(readonly, "1") == 0 && !readonly_mount("/workspace"))
        return "workspace_read_only";

    struct __user_cap_header_struct header = {
        .version = _LINUX_CAPABILITY_VERSION_3, .pid = 0
    };
    struct __user_cap_data_struct caps[2] = {0};
    if (syscall(SYS_capget, &header, caps) != 0 ||
        (caps[0].permitted & (1U << CAP_SYS_ADMIN)) != 0)
        return "capabilities";
    if (getuid() != 0 || geteuid() != 0 || getgid() != 0 || getegid() != 0)
        return "guest_identity";
    return "ready";
}

int main(int argc, char **argv)
{
    if (argc < 3)
        return 5;
    char *end;
    long number = strtol(argv[1], &end, 10);
    if (*end != '\0' || number < 3 || number > 2147483647)
        return 5;
    int fd = (int)number;
    const char *result = check_protection();
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 3U, ~0U, CLOSE_RANGE_CLOEXEC) != 0)
        result = "file_descriptors";
#else
    result = "file_descriptors";
#endif
    if (write(fd, result, strlen(result)) != (ssize_t)strlen(result) ||
        strcmp(result, "ready") != 0)
        return 5;

    /* Release only follows host verification. Close the private channel and any
       other inherited setup FDs before invoking code from the guest rootfs. */
    char ack;
    if (read(fd, &ack, 1) != 1 || ack != '1')
        return 5;
    close(fd);
    unsetenv("CAPBOX_AGENT_WORKSPACE_READONLY");
    execvp(argv[2], &argv[2]);
    return errno == ENOENT ? 127 : 126;
}
