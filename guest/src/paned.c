// paned — cs-OS guest agent.
//
// Runs as PID 1 inside the microVM. Listens on AF_VSOCK; every accepted
// connection becomes one pty running /bin/sh, which is one tab in the host UI.
//
// Framed protocol (keep in lockstep with Sources/csos/VM/Frame.swift):
//
//     +--------+------------------+-----------------+
//     | type   | length (u32, BE) | payload         |
//     | 1 byte | 4 bytes          | `length` bytes  |
//     +--------+------------------+-----------------+
//
// Build: static against musl, ~40KB stripped.
//   musl-gcc -Os -static -o paned paned.c && strip paned

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <linux/vm_sockets.h>
#include <termios.h>
#include <unistd.h>

#define GUEST_VSOCK_PORT 1024
#define FRAME_DATA   1
#define FRAME_RESIZE 2
#define FRAME_EXIT   3
#define FRAME_PING   4
#define MAX_PAYLOAD  (1 << 20)
#define HDR          5

/* ------------------------------------------------------------------ util */

static ssize_t write_all(int fd, const unsigned char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return (ssize_t)off;
}

static int send_frame(int fd, unsigned char type, const unsigned char *payload, size_t len) {
    unsigned char hdr[HDR];
    hdr[0] = type;
    hdr[1] = (unsigned char)((len >> 24) & 0xff);
    hdr[2] = (unsigned char)((len >> 16) & 0xff);
    hdr[3] = (unsigned char)((len >> 8) & 0xff);
    hdr[4] = (unsigned char)(len & 0xff);
    if (write_all(fd, hdr, HDR) < 0) return -1;
    if (len && write_all(fd, payload, len) < 0) return -1;
    return 0;
}

/* PID 1 must reap, or every exited shell becomes a permanent zombie. */
static void reap(int sig) {
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
}

/* ------------------------------------------------------------- session */

/* Pumps one vsock connection <-> one pty until either side closes. */
static void session_loop(int sock, int master, pid_t child) {
    unsigned char inbuf[65536];
    unsigned char acc[HDR + MAX_PAYLOAD];
    size_t acc_len = 0;

    struct pollfd fds[2];
    fds[0].fd = sock;   fds[0].events = POLLIN;
    fds[1].fd = master; fds[1].events = POLLIN;

    for (;;) {
        int rc = poll(fds, 2, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* pty -> host */
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            ssize_t n = read(master, inbuf, sizeof inbuf);
            if (n <= 0) break;           /* shell exited or pty closed */
            if (send_frame(sock, FRAME_DATA, inbuf, (size_t)n) < 0) break;
        }

        /* host -> pty */
        if (fds[0].revents & POLLIN) {
            ssize_t n = read(sock, inbuf, sizeof inbuf);
            if (n <= 0) break;           /* host closed the tab */

            /* Frames straddle reads; accumulate then drain. */
            if (acc_len + (size_t)n > sizeof acc) break;  /* desync: bail */
            memcpy(acc + acc_len, inbuf, (size_t)n);
            acc_len += (size_t)n;

            size_t off = 0;
            while (acc_len - off >= HDR) {
                unsigned char type = acc[off];
                size_t len = ((size_t)acc[off + 1] << 24) | ((size_t)acc[off + 2] << 16) |
                             ((size_t)acc[off + 3] << 8)  | (size_t)acc[off + 4];
                if (len > MAX_PAYLOAD) { acc_len = off = 0; break; }
                if (acc_len - off < HDR + len) break;     /* wait for the rest */

                unsigned char *p = acc + off + HDR;
                if (type == FRAME_DATA) {
                    if (write_all(master, p, len) < 0) goto done;
                } else if (type == FRAME_RESIZE && len >= 4) {
                    struct winsize ws;
                    memset(&ws, 0, sizeof ws);
                    ws.ws_col = (unsigned short)((p[0] << 8) | p[1]);
                    ws.ws_row = (unsigned short)((p[2] << 8) | p[3]);
                    /* Resizing the master sends SIGWINCH to the foreground
                       group, which is what makes vim/htop reflow. */
                    ioctl(master, TIOCSWINSZ, &ws);
                } else if (type == FRAME_PING) {
                    send_frame(sock, FRAME_PING, NULL, 0);
                }
                off += HDR + len;
            }
            if (off > 0) {
                memmove(acc, acc + off, acc_len - off);
                acc_len -= off;
            }
        }

        if (fds[0].revents & (POLLERR | POLLHUP)) break;
    }

done:
    /* Report the shell's status so the host can print it in the tab. */
    {
        int status = 0;
        unsigned char code = 0;
        kill(child, SIGHUP);
        if (waitpid(child, &status, WNOHANG) == child && WIFEXITED(status))
            code = (unsigned char)WEXITSTATUS(status);
        send_frame(sock, FRAME_EXIT, &code, 1);
    }
    close(master);
    close(sock);
}

static void handle_connection(int sock) {
    int master;
    struct winsize ws = { .ws_row = 24, .ws_col = 80 };

    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) { close(sock); return; }

    if (pid == 0) {
        /* Child: a login shell on the slave side of the pty. */
        setenv("TERM", "xterm-256color", 1);
        setenv("HOME", "/root", 1);
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
        setenv("PS1", "\\w \\$ ", 1);
        chdir("/root");
        execl("/bin/sh", "-sh", (char *)NULL);
        _exit(127);
    }

    session_loop(sock, master, pid);
}

/* ---------------------------------------------------------------- init */

/* As PID 1 we own early userspace setup; there is no systemd here. */
static void init_mounts(void) {
    mkdir("/proc", 0555); mkdir("/sys", 0555); mkdir("/dev/pts", 0755);
    mount("proc",     "/proc",    "proc",     0, NULL);
    mount("sysfs",    "/sys",     "sysfs",    0, NULL);
    mount("devpts",   "/dev/pts", "devpts",   0, "gid=5,mode=620");
    mount("tmpfs",    "/tmp",     "tmpfs",    0, "mode=1777");
}

int main(void) {
    if (getpid() == 1) {
        init_mounts();
        signal(SIGCHLD, reap);
        signal(SIGPIPE, SIG_IGN);
    }

    int listener = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listener < 0) { perror("socket(AF_VSOCK)"); return 1; }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof addr);
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = GUEST_VSOCK_PORT;

    if (bind(listener, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind"); return 1;
    }
    if (listen(listener, 16) < 0) { perror("listen"); return 1; }

    for (;;) {
        int sock = accept(listener, NULL, NULL);
        if (sock < 0) {
            if (errno == EINTR) continue;   /* SIGCHLD from a reaped shell */
            perror("accept");
            continue;
        }
        /* One process per tab: a wedged shell can never take the agent down. */
        pid_t pid = fork();
        if (pid == 0) {
            close(listener);
            handle_connection(sock);
            _exit(0);
        }
        close(sock);
    }
}
