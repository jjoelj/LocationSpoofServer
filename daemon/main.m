#import <Foundation/Foundation.h>
#import "LSSDaemonController.h"
#import "LSSControlHTTPServer.h"
#import "LSSLogger.h"
#include <signal.h>
#include <execinfo.h>
#include <stdio.h>

static void handle_fatal(int sig) {
    void *bt[64];
    int n = backtrace(bt, 64);
    dprintf(2, "FATAL signal %d\n", sig);
    backtrace_symbols_fd(bt, n, 2);
    _exit(128 + sig);
}

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stderr, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGSEGV, handle_fatal);
    signal(SIGABRT, handle_fatal);
    signal(SIGBUS,  handle_fatal);
    signal(SIGILL,  handle_fatal);

    @autoreleasepool {
        [[LSSLogger shared] log:@"locationspoofd boot" tag:@"DAEMON"];

        [[LSSDaemonController shared] startServices];

        LSSControlHTTPServer *control = [[LSSControlHTTPServer alloc] init];
        [control startOnPort:31666];

        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
