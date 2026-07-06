#import "LSSDaemonController.h"
#import "LSSLogger.h"
#import "LSSLocalHTTPServer.h"
#import "LSSLocSimController.h"
#import <CoreLocation/CoreLocation.h>

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

static NSString *LoadOrCreateToken(void) {
    NSString *existing = [NSString stringWithContentsOfFile:kTokenPath encoding:NSUTF8StringEncoding error:nil];
    existing = [existing stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (existing.length > 0) return existing;

    NSString *tok = GenerateToken();
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[kTokenPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [tok writeToFile:kTokenPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return tok;
}

@interface LSSDaemonController ()
@property(nonatomic, strong) LSSLocalHTTPServer *publicServer;
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

- (NSDictionary *)status {
    return @{
        @"ok": @YES,
        @"publicPort": @(self.publicPort),
    };
}

- (NSDictionary *)logs {
    return @{@"ok": @YES, @"logs": [[LSSLogger shared] snapshot] ?: @""};
}

@end
