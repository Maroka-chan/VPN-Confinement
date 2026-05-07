#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/capability.h>
#include <errno.h>
#include <fcntl.h>
#define NETNS_DIR "/var/run/netns"
static void do_mount(const char *src, const char *dst, const char *type, unsigned long flags) {
    if (mount(src, dst, type, flags, NULL) != 0 && errno != ENOENT && errno != EEXIST)
        perror("mount");
}
static void drop_privileges(void) {
    // Drop bounding set while we still have CAP_SYS_ADMIN
    for (int i = 0; i <= cap_max_bits(); i++) {
        if (i == CAP_NET_RAW) continue;
        prctl(PR_CAPBSET_DROP, i, 0, 0, 0); // ignore errors silently
    }
    // Now strip everything except CAP_NET_RAW from caps
    cap_t caps = cap_get_proc();
    cap_clear(caps);
    cap_value_t keep = CAP_NET_RAW;
    cap_set_flag(caps, CAP_INHERITABLE, 1, &keep, CAP_SET);
    cap_set_flag(caps, CAP_PERMITTED, 1, &keep, CAP_SET);
    cap_set_flag(caps, CAP_EFFECTIVE, 1, &keep, CAP_SET);
    if (cap_set_proc(caps) != 0) { perror("cap_set_proc"); exit(1); }
    cap_free(caps);
    // Raise ambient so CAP_NET_RAW survives exec into any binary
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, CAP_NET_RAW, 0, 0) != 0) {
        perror("prctl PR_CAP_AMBIENT_RAISE");
        exit(1);
    }
}
int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <namespace> <command> [args...]\n", argv[0]);
        return 1;
    }
    const char *ns = argv[1];
    // Enter network namespace
    char netns_path[256];
    snprintf(netns_path, sizeof(netns_path), "%s/%s", NETNS_DIR, ns);
    int nsfd = open(netns_path, O_RDONLY);
    if (nsfd < 0) { perror("open netns"); return 1; }
    if (setns(nsfd, CLONE_NEWNET) != 0) { perror("setns"); close(nsfd); return 1; }
    close(nsfd);
    // Create private mount namespace
    if (unshare(CLONE_NEWNS) != 0) { perror("unshare CLONE_NEWNS"); return 1; }
    // Don't propagate mounts to/from parent
    if (mount("", "/", "", MS_SLAVE | MS_REC, NULL) != 0) { perror("mount --make-rslave"); return 1; }
    // Bind-mount netns-specific files (same as ip netns exec does)
    char buf[256];
    snprintf(buf, sizeof(buf), "/etc/netns/%s/resolv.conf", ns);
    do_mount(buf, "/etc/resolv.conf", NULL, MS_BIND);
    snprintf(buf, sizeof(buf), "/etc/netns/%s/nsswitch.conf", ns);
    do_mount(buf, "/etc/nsswitch.conf", NULL, MS_BIND);
    snprintf(buf, sizeof(buf), "/etc/netns/%s/hosts", ns);
    do_mount(buf, "/etc/hosts", NULL, MS_BIND);
    // DNS leak prevention (same as systemd InaccessiblePaths)
    do_mount("tmpfs", "/run/nscd", "tmpfs", 0);
    do_mount("tmpfs", "/run/resolvconf", "tmpfs", 0);
    do_mount("/dev/null", "/run/systemd/resolve/io.systemd.Resolve", NULL, MS_BIND);
    // Drop all capabilities before exec
    drop_privileges();
    execvp(argv[2], &argv[2]);
    perror("execvp");
    return 1;
}
