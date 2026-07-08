#import "LSSDaemonController.h"
#import "LSSLogger.h"
#import "LSSLocalHTTPServer.h"
#import "LSSLocSimController.h"
#import <CoreLocation/CoreLocation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <spawn.h>
#include <math.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static NSString *const kFMFHelperPath = @"/usr/libexec/fmfhelper";

// Random per-device token, persisted so it survives daemon restarts (otherwise
// the external pusher's saved token would break on every relaunch). Not in git.
static NSString *const kTokenPath = @"/var/mobile/Library/LocationSpoofServer/set-token";

static NSString *GenerateToken(void) {
    uint8_t b[16];
    arc4random_buf(b, sizeof(b));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (size_t i = 0; i < sizeof(b); i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static void SaveToken(NSString *tok) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[kTokenPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [tok writeToFile:kTokenPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *LoadOrCreateToken(void) {
    NSString *existing = [NSString stringWithContentsOfFile:kTokenPath encoding:NSUTF8StringEncoding error:nil];
    existing = [existing stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (existing.length > 0) return existing;

    NSString *tok = GenerateToken();
    SaveToken(tok);
    return tok;
}

static NSString *FriendsSummary(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) return @"invalid json";

    if (![obj[@"ok"] boolValue]) {
        NSString *message = [obj[@"message"] isKindOfClass:[NSString class]] ? obj[@"message"] : @"unknown error";
        return [NSString stringWithFormat:@"failed: %@", message];
    }

    NSArray *friends = [obj[@"friends"] isKindOfClass:[NSArray class]] ? obj[@"friends"] : @[];
    NSUInteger valid = 0;
    for (NSDictionary *f in friends) {
        if (![f isKindOfClass:[NSDictionary class]]) continue;
        if ([f[@"valid"] boolValue]) valid++;
    }
    return [NSString stringWithFormat:@"ok: %lu friends, %lu valid locations",
            (unsigned long)friends.count, (unsigned long)valid];
}

static NSDictionary *ReadBatteryStatus(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return @{@"ok": @NO, @"message": @"battery info unavailable"};

    CFArrayRef sources = IOPSCopyPowerSourcesList(info);
    if (!sources) {
        CFRelease(info);
        return @{@"ok": @NO, @"message": @"battery source unavailable"};
    }

    NSMutableDictionary *battery = nil;
    CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef source = CFArrayGetValueAtIndex(sources, i);
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(info, source);
        if (!desc) continue;

        NSDictionary *d = (__bridge NSDictionary *)desc;
        NSString *currentKey = @(kIOPSCurrentCapacityKey);
        NSString *maxKey = @(kIOPSMaxCapacityKey);
        NSString *stateKey = @(kIOPSPowerSourceStateKey);
        NSString *chargingKey = @(kIOPSIsChargingKey);

        NSNumber *current = [d[currentKey] isKindOfClass:[NSNumber class]] ? d[currentKey] : nil;
        NSNumber *max = [d[maxKey] isKindOfClass:[NSNumber class]] ? d[maxKey] : nil;
        if (!current || !max || max.integerValue <= 0) continue;

        NSInteger percent = (NSInteger)llround(((double)current.integerValue * 100.0) / (double)max.integerValue);
        percent = MAX((NSInteger)0, MIN((NSInteger)100, percent));

        NSString *state = [d[stateKey] isKindOfClass:[NSString class]] ? d[stateKey] : @"";
        NSNumber *isCharging = [d[chargingKey] isKindOfClass:[NSNumber class]] ? d[chargingKey] : nil;
        BOOL externalPower = [state isEqualToString:@kIOPSACPowerValue];
        BOOL charging = isCharging ? isCharging.boolValue : externalPower;

        battery = [@{
            @"ok": @YES,
            @"batteryPercent": @(percent),
            @"batteryLevel": @((double)percent / 100.0),
            @"charging": @(charging),
            @"externalPower": @(externalPower),
        } mutableCopy];
        break;
    }

    CFRelease(sources);
    CFRelease(info);

    return battery ?: @{@"ok": @NO, @"message": @"battery not found"};
}

@interface LSSDaemonController ()
@property(nonatomic, strong) LSSLocalHTTPServer *publicServer;
@property(nonatomic, assign) BOOL refreshFriendsInProgress;
@end

@implementation LSSDaemonController

+ (instancetype)shared {
    static LSSDaemonController *g;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g = [[LSSDaemonController alloc] init];
    });
    return g;
}

- (instancetype)init {
    if ((self = [super init])) {
        _publicPort = 8080;

        NSDictionary *env = NSProcessInfo.processInfo.environment;
        _setEndpointToken = env[@"LSS_SET_TOKEN"] ?: LoadOrCreateToken();
    }
    return self;
}

- (void)startServices {
    [[LSSLogger shared] log:@"daemon starting services" tag:@"DAEMON"];

    (void)[LSSLocSimController shared];

    self.publicServer = [[LSSLocalHTTPServer alloc] init];
    self.publicServer.authToken = self.setEndpointToken;

    self.publicServer.locationSink = ^(double lat, double lon) {
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat, lon);
        if (!CLLocationCoordinate2DIsValid(c)) {
            [[LSSLogger shared] log:[NSString stringWithFormat:@"reject invalid lat/lon %.6f %.6f", lat, lon] tag:@"LOCSIM"];
            return;
        }

        CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
        [[LSSLocSimController shared] pushLocation:loc];
        [[LSSLogger shared] log:[NSString stringWithFormat:@"applied lat=%.6f lon=%.6f", lat, lon] tag:@"LOCSIM"];
    };

    [self.publicServer startOnPort:self.publicPort];
    [[LSSLogger shared] log:[NSString stringWithFormat:@"public server on 127.0.0.1:%d", self.publicPort] tag:@"DAEMON"];
}

- (NSDictionary *)applyToken:(NSString *)tok {
    tok = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Token travels as a URL query param, so restrict to unreserved URI chars.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-"];
    if (tok.length < 8 || tok.length > 128 ||
        [tok rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) {
        return @{@"ok": @NO, @"message": @"token must be 8-128 chars of A-Za-z0-9._~-"};
    }

    SaveToken(tok);
    self.setEndpointToken = tok;
    self.publicServer.authToken = tok;
    [[LSSLogger shared] log:@"set token updated manually" tag:@"DAEMON"];
    return @{@"ok": @YES, @"token": tok};
}

- (NSDictionary *)regenerateToken {
    return [self applyToken:GenerateToken()];
}

// Spawn the FMF helper and return its JSON stdout. Blocks until it exits
// (helper self-caps), so callers must not run on a shared serial path.
- (NSString *)friendsJSONWithRefresh:(BOOL)refresh handle:(NSString *)handle {
    int fds[2];
    if (pipe(fds) != 0) {
        if (refresh) [[LSSLogger shared] log:@"friends refresh failed before spawn: pipe failed" tag:@"FMF"];
        return @"{\"ok\":false,\"message\":\"pipe failed\"}";
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);

    char *argv[] = {
        (char *)kFMFHelperPath.UTF8String,
        refresh ? "--refresh" : NULL,
        (refresh && handle.length) ? (char *)handle.UTF8String : NULL,
        NULL
    };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);

    if (rc != 0) {
        close(fds[0]);
        [[LSSLogger shared] log:[NSString stringWithFormat:@"fmfhelper spawn failed rc=%d", rc] tag:@"FMF"];
        return @"{\"ok\":false,\"message\":\"helper spawn failed\"}";
    }

    if (refresh) {
        NSString *target = handle.length ? [NSString stringWithFormat:@" handle=%@", handle] : @"";
        [[LSSLogger shared] log:[NSString stringWithFormat:@"friends refresh helper started pid=%d%@", pid, target] tag:@"FMF"];
    }

    NSMutableData *out = [NSMutableData data];
    uint8_t buf[4096];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof(buf))) > 0) [out appendBytes:buf length:(size_t)n];
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    if (refresh && status != 0) {
        [[LSSLogger shared] log:[NSString stringWithFormat:@"friends refresh helper exited status=%d", status] tag:@"FMF"];
    }

    if (out.length == 0) {
        if (refresh) [[LSSLogger shared] log:@"friends refresh failed: helper produced no output" tag:@"FMF"];
        return @"{\"ok\":false,\"message\":\"helper produced no output\"}";
    }
    NSString *s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    if (!s && refresh) [[LSSLogger shared] log:@"friends refresh failed: helper output not utf8" tag:@"FMF"];
    return s ?: @"{\"ok\":false,\"message\":\"helper output not utf8\"}";
}

- (NSString *)friendsJSON {
    return [self friendsJSONWithRefresh:NO handle:nil];
}

- (NSString *)refreshFriendsJSONForHandle:(NSString *)handle ifStarted:(BOOL *)started {
    @synchronized (self) {
        if (self.refreshFriendsInProgress) {
            if (started) *started = NO;
            [[LSSLogger shared] log:@"friends refresh rejected: already in progress" tag:@"FMF"];
            return @"{\"ok\":false,\"message\":\"friends refresh already in progress\"}";
        }
        self.refreshFriendsInProgress = YES;
    }

    if (started) *started = YES;
    NSDate *start = [NSDate date];
    NSString *target = handle.length ? [NSString stringWithFormat:@" for handle=%@", handle] : @"";
    [[LSSLogger shared] log:[NSString stringWithFormat:@"friends refresh started%@", target] tag:@"FMF"];
    @try {
        NSString *json = [self friendsJSONWithRefresh:YES handle:handle];
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start];
        [[LSSLogger shared] log:[NSString stringWithFormat:@"friends refresh finished in %.1fs (%@)", elapsed, FriendsSummary(json)] tag:@"FMF"];
        return json;
    } @finally {
        @synchronized (self) {
            self.refreshFriendsInProgress = NO;
        }
    }
}

- (NSDictionary *)batteryStatus {
    return ReadBatteryStatus();
}

- (NSDictionary *)logs {
    return @{@"ok": @YES, @"logs": [[LSSLogger shared] snapshot] ?: @""};
}

@end
