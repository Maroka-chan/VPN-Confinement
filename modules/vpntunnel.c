#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/capability.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>

#define NETNS_DIR "/var/run/netns"
#define NETNS_CONF_DIR "/etc/netns"
#define NETNS_MAX_FILENAME 14  // "nsswitch.conf"

// "/etc/netns" + "/" + name + "/" + "nsswitch.conf" + '\0'
#define NETNS_PATH_MAX (sizeof(NETNS_CONF_DIR) + 1 + IFNAMSIZ + NETNS_MAX_FILENAME + 1)

static int do_mount(const char *src, const char *dst, const char *type, unsigned long flags) {
    if (mount(src, dst, type, flags, NULL) != 0) {
        fprintf(stderr, "mount failed: src=%s, dst=%s: %s\n", src, dst, strerror(errno));
        return -1;
    }
    return 0;
}

static void mask_path_if_exists(const char *path) {
    struct stat st;

    if (stat(path, &st) == 0) {
        // Path exists, so mount MUST succeed
        if (S_ISDIR(st.st_mode)) {
            if (mount("tmpfs", path, "tmpfs", 0, "size=0") != 0) {
                fprintf(stderr, "Failed to mask directory %s: %s\n", path, strerror(errno));
                exit(1);
            }
            if (mount(NULL, path, NULL, MS_REMOUNT | MS_RDONLY | MS_BIND, NULL) != 0) {
                fprintf(stderr, "Failed to remount %s read-only: %s\n", path, strerror(errno));
                exit(1);
            }
        } else {
            if (mount("/dev/null", path, NULL, MS_BIND, NULL) != 0) {
                fprintf(stderr, "Failed to mask file %s: %s\n", path, strerror(errno));
                exit(1);
            }
            if (mount(NULL, path, NULL, MS_REMOUNT | MS_RDONLY | MS_BIND, NULL) != 0) {
                fprintf(stderr, "Failed to remount %s read-only: %s\n", path, strerror(errno));
                exit(1);
            }
        }
    }
    // Path doesn't exist - OK to ignore because of MS_PRIVATE
}

static void drop_privileges(void) {
    // Drop all capabilities before exec.
    // This makes the target program run completely unprivileged inside the namespace.
    // If specific capabilities are needed (e.g., CAP_NET_BIND_SERVICE),
    // set them on the target binary with: setcap cap_name+ep /path/to/binary,
    // or with the securityWrappers option on NixOS.
    cap_t caps = cap_get_proc();
    if (caps == NULL) {
        perror("cap_get_proc");
        exit(1);
    }

    cap_clear(caps);  // Clear all capabilities - completely unprivileged

    if (cap_set_proc(caps) != 0) {
        perror("cap_set_proc");
        exit(1);
    }

    cap_free(caps);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <namespace> <command> [args...]\n", argv[0]);
        return 1;
    }

    const char *ns = argv[1];

    // Validate namespace name length
    if (strlen(ns) >= IFNAMSIZ) {
        fprintf(stderr, "Error: namespace name too long (max %d characters)\n", IFNAMSIZ - 1);
        return 1;
    }

    // Validate no path traversal
    if (strchr(ns, '/') != NULL || strcmp(ns, ".") == 0 || strcmp(ns, "..") == 0) {
        fprintf(stderr, "Error: invalid namespace name\n");
        return 1;
    }

    // Enter network namespace
    char netns_path[sizeof(NETNS_DIR) + IFNAMSIZ];
    snprintf(netns_path, sizeof(netns_path), "%s/%s", NETNS_DIR, ns);

    int nsfd = open(netns_path, O_RDONLY);
    if (nsfd < 0) {
        perror("open netns");
        return 1;
    }

    if (setns(nsfd, CLONE_NEWNET) != 0) {
        perror("setns");
        close(nsfd);
        return 1;
    }
    close(nsfd);

    // Create private mount namespace
    if (unshare(CLONE_NEWNS) != 0) {
        perror("unshare CLONE_NEWNS");
        return 1;
    }

    // Don't propagate mounts to/from parent
    if (mount("", "/", "", MS_PRIVATE | MS_REC, NULL) != 0) {
        perror("mount --make-rprivate");
        return 1;
    }

    // DNS leak prevention by masking system DNS service paths.
    // Similar to systemd InaccessiblePaths, but more robust: MS_PRIVATE
    // ensures these paths cannot become accessible even if the host adds
    // or removes mounts after we enter the namespace.
    mask_path_if_exists("/run/nscd");
    mask_path_if_exists("/run/resolvconf");
    mask_path_if_exists("/run/systemd/resolve/io.systemd.Resolve");
    mask_path_if_exists("/run/systemd/resolve/stub-resolv.conf");
    mask_path_if_exists("/run/systemd/resolve/resolv.conf");
    mask_path_if_exists("/run/systemd/resolve/netif");
    // mDNS can leak local network queries
    mask_path_if_exists("/run/avahi-daemon");
    mask_path_if_exists("/var/run/avahi-daemon");
    // If you use LDAP/enterprise authentication
    mask_path_if_exists("/var/run/nslcd");
    mask_path_if_exists("/var/run/sssd");

    // Bind-mount netns-specific files (same as ip netns exec does).
    // More strict because we exit the program if any of the files are not
    // present, as we require them for configuring DNS and preventing leaks.
    char buf[NETNS_PATH_MAX];

    snprintf(buf, sizeof(buf), "/etc/netns/%s/resolv.conf", ns);
    if (do_mount(buf, "/etc/resolv.conf", NULL, MS_BIND) != 0) {
        return 1;
    }

    snprintf(buf, sizeof(buf), "/etc/netns/%s/nsswitch.conf", ns);
    if (do_mount(buf, "/etc/nsswitch.conf", NULL, MS_BIND) != 0) {
        return 1;
    }

    snprintf(buf, sizeof(buf), "/etc/netns/%s/hosts", ns);
    if (do_mount(buf, "/etc/hosts", NULL, MS_BIND) != 0) {
        return 1;
    }

    // Drop all capabilities before exec
    drop_privileges();
    execvp(argv[2], &argv[2]);
    perror("execvp");
    return 1;
}
