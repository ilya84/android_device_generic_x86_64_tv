/*
 * los-tv-kmsglog: минимальный логгер /dev/kmsg -> /data/misc/los-tv-kmsg.log
 * Freestanding (без libc), чтобы попасть в system image минимальным размером.
 */
static long sc(long n, long a, long b, long c) {
    long r;
    __asm__ volatile("syscall"
                     : "=a"(r)
                     : "a"(n), "D"(a), "S"(b), "d"(c)
                     : "rcx", "r11", "memory");
    return r;
}

static long sys_open(const char *p, long flags, long mode) {
    return sc(2, (long)p, flags, mode);
}
static long sys_read(long fd, void *buf, long n) {
    return sc(0, fd, (long)buf, n);
}
static long sys_write(long fd, const void *buf, long n) {
    return sc(1, fd, (long)buf, n);
}
static void sys_exit(long code) {
    sc(60, code, 0, 0);
    for (;;) { }
}
static void puts_fd(long fd, const char *s) {
    long n = 0;
    while (s[n]) n++;
    sys_write(fd, s, n);
}

void _start(void) {
    static char buf[8192];
    long out = sys_open("/data/misc/los_tv_kmsg/kmsg.log", 0x241 /*WRONLY|CREAT|TRUNC*/, 0644);
    if (out < 0) sys_exit(2);

    puts_fd(out, "===== los-tv-kmsglog start =====\n");
    sc(74, out, 0, 0); /* fsync */

    long in = sys_open("/dev/kmsg", 0, 0);
    if (in < 0) {
        puts_fd(out, "ERROR: cannot open /dev/kmsg\n");
        sc(74, out, 0, 0);
        sys_exit(1);
    }

    for (;;) {
        long n = sys_read(in, buf, sizeof(buf));
        if (n > 0) {
            long off = 0;
            while (off < n) {
                long w = sys_write(out, buf + off, n - off);
                if (w <= 0) break;
                off += w;
            }
            sc(74, out, 0, 0); /* fsync: пережить watchdog reset */
        }
    }
}
