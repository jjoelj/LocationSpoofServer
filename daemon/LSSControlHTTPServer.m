#import "LSSControlHTTPServer.h"
#import "LSSDaemonController.h"
#import "LSSLogger.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

@interface LSSControlHTTPServer ()
@property(nonatomic, assign) int listenFD;
@property(nonatomic, strong) dispatch_source_t acceptSource;
@end

@implementation LSSControlHTTPServer

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
    }
    return self;
}

static NSString *HeaderValue(NSString *request, NSString *headerName) {
    NSArray<NSString *> *lines = [request componentsSeparatedByString:@"\r\n"];
    NSString *prefix = [[headerName lowercaseString] stringByAppendingString:@":"];
    for (NSString *line in lines) {
        NSString *lower = [line lowercaseString];
        if ([lower hasPrefix:prefix]) {
            NSString *v = [line substringFromIndex:prefix.length];
            return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return nil;
}

static void WriteJSON(int fd, int status, NSDictionary *obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json) json = [@"{\"ok\":false,\"message\":\"json encode failed\"}" dataUsingEncoding:NSUTF8StringEncoding];

    char hdr[512];
    int n = snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 %d %s\r\n"
                     "Content-Type: application/json; charset=utf-8\r\n"
                     "Content-Length: %zu\r\n"
                     "Connection: close\r\n"
                     "\r\n",
                     status, (status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")),
                     (size_t)json.length);

    (void)write(fd, hdr, (size_t)n);
    (void)write(fd, json.bytes, json.length);
}

static NSData *ReadExact(int fd, size_t n) {
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) return nil;
        got += (size_t)r;
    }
    return out;
}

- (void)handleClient:(int)cfd {
    // Read headers (simple: one read is usually enough; if not, still works for small requests)
    char buf[8192];
    ssize_t n = read(cfd, buf, sizeof(buf) - 1);
    if (n <= 0) { close(cfd); return; }
    buf[n] = 0;

    NSString *req = [NSString stringWithUTF8String:buf] ?: @"";
    NSArray<NSString *> *parts = [req componentsSeparatedByString:@"\r\n\r\n"];
    NSString *head = parts.count > 0 ? parts[0] : @"";
    NSString *bodyStr = parts.count > 1 ? parts[1] : @"";

    // Parse request line
    NSString *firstLine = [[head componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
    NSArray<NSString *> *fl = [firstLine componentsSeparatedByString:@" "];
    if (fl.count < 2) {
        WriteJSON(cfd, 400, @{@"ok": @NO, @"message": @"bad request line"});
        close(cfd);
        return;
    }
    NSString *method = fl[0];
    NSString *target = fl[1];

    if (![target isEqualToString:@"/logs"]) {
        [[LSSLogger shared] log:[NSString stringWithFormat:@"%@ %@", method, target] tag:@"HTTP"];
    }

    // Content-Length handling for POST
    NSInteger contentLength = [HeaderValue(head, @"Content-Length") integerValue];
    NSData *bodyData = [bodyStr dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];

    if (contentLength > (NSInteger)bodyData.length) {
        NSData *rest = ReadExact(cfd, (size_t)(contentLength - (NSInteger)bodyData.length));
        if (rest) {
            NSMutableData *m = [bodyData mutableCopy];
            [m appendData:rest];
            bodyData = m;
        }
    }

    // No auth: this server binds 127.0.0.1 only (single-user device). The one
    // real secret, the /set token, is returned by /token for the app to display.

    NSDictionary *json = nil;
    if ([method isEqualToString:@"POST"] && bodyData.length > 0) {
        json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;
    }

    LSSDaemonController *dc = [LSSDaemonController shared];

    if ([method isEqualToString:@"GET"] && [target isEqualToString:@"/status"]) {
        WriteJSON(cfd, 200, [dc status]);
        close(cfd);
        return;
    }

    if ([method isEqualToString:@"GET"] && [target isEqualToString:@"/logs"]) {
        WriteJSON(cfd, 200, [dc logs]);
        close(cfd);
        return;
    }

    if ([method isEqualToString:@"GET"] && [target isEqualToString:@"/token"]) {
        WriteJSON(cfd, 200, @{@"ok": @YES, @"token": dc.setEndpointToken ?: @""});
        close(cfd);
        return;
    }

    if ([method isEqualToString:@"POST"] && [target isEqualToString:@"/token/regenerate"]) {
        WriteJSON(cfd, 200, [dc regenerateToken]);
        close(cfd);
        return;
    }

    if ([method isEqualToString:@"POST"] && [target isEqualToString:@"/token"]) {
        NSString *tok = [json[@"token"] isKindOfClass:[NSString class]] ? json[@"token"] : @"";
        NSDictionary *resp = [dc applyToken:tok];
        WriteJSON(cfd, [resp[@"ok"] boolValue] ? 200 : 400, resp);
        close(cfd);
        return;
    }

    WriteJSON(cfd, 404, @{@"ok": @NO, @"message": @"not found"});
    close(cfd);
}

- (BOOL)startOnPort:(int)port {
    if (self.listenFD >= 0) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1 only

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return NO; }
    if (listen(fd, 16) != 0) { close(fd); return NO; }

    self.listenFD = fd;

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, q);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.acceptSource, ^{
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        int cfd = accept(self.listenFD, NULL, NULL);
        if (cfd < 0) return;
        [self handleClient:cfd];
    });

    dispatch_resume(self.acceptSource);
    [[LSSLogger shared] log:[NSString stringWithFormat:@"control API on http://127.0.0.1:%d", port] tag:@"DAEMON"];
    return YES;
}

- (void)stop {
    if (self.acceptSource) {
        dispatch_source_cancel(self.acceptSource);
        self.acceptSource = nil;
    }
    if (self.listenFD >= 0) {
        close(self.listenFD);
        self.listenFD = -1;
    }
}

- (void)dealloc { [self stop]; }

@end
