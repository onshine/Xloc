//
//  CrashHandler.c
//  Xloc
//
//  信号级崩溃捕获。
//
//  为什么不用 Swift 写：
//    信号处理器里只能调用 async-signal-safe 的函数。Swift 运行时、ARC、内存分配
//    都不安全，在里面做任何事都可能二次崩溃。这里只用 open/write/backtrace_symbols_fd，
//    写完就 _exit。
//
//  策略：
//    信号发生时，把栈直接追加到固定的 pending-signal.log（路径在安装时传入），
//    下次启动由 Swift 侧改名为带时间戳的崩溃记录。
//    这样处理器里不需要格式化时间，逻辑最简。
//

#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <execinfo.h>
#include <stdlib.h>
#include <time.h>

static char g_path[1024] = {0};

static const char *xloc_signal_name(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT (abort / 未捕获异常)";
        case SIGSEGV: return "SIGSEGV (非法内存访问)";
        case SIGBUS:  return "SIGBUS (总线错误)";
        case SIGILL:  return "SIGILL (非法指令)";
        case SIGFPE:  return "SIGFPE (算术错误)";
        case SIGTRAP: return "SIGTRAP (断点/陷阱)";
        case SIGSYS:  return "SIGSYS (非法系统调用)";
        default:      return "UNKNOWN";
    }
}

static void xloc_signal_handler(int sig) {
    int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const char *name = xloc_signal_name(sig);

        char num[16];
        int n = sig, i = 0;
        if (n == 0) { num[i++] = '0'; }
        while (n > 0 && i < 15) { num[i++] = (char)('0' + (n % 10)); n /= 10; }
        // 反转
        for (int a = 0, b = i - 1; a < b; a++, b--) { char t = num[a]; num[a] = num[b]; num[b] = t; }
        num[i] = '\0';

        write(fd, "\n===== SIGNAL ", 14);
        write(fd, num, strlen(num));
        write(fd, " =====", 6);
        write(fd, "\n", 1);
        write(fd, name, strlen(name));
        write(fd, "\n--- backtrace ---\n", 19);

        void *frames[128];
        int count = backtrace(frames, 128);
        backtrace_symbols_fd(frames, count, fd);

        fsync(fd);
        close(fd);
    }

    // 恢复默认处理并重新抛出，让系统也能留下自己的记录
    signal(sig, SIG_DFL);
    raise(sig);
}

void xloc_install_crash_handler(const char *path) {
    if (!path) return;
    strncpy(g_path, path, sizeof(g_path) - 1);
    g_path[sizeof(g_path) - 1] = '\0';

    int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS };
    for (unsigned long i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = xloc_signal_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESETHAND;   // 处理一次后恢复默认，避免死循环
        sigaction(sigs[i], &sa, NULL);
    }
}
