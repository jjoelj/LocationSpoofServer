// Standalone helper: prints Find My friends' locations as JSON, then exits.
//
//   fmfhelper            -> cached locations, returns fast (~1s)
//   fmfhelper --refresh  -> forces a live locate, waits ~up to kRefreshDeadline
//   fmfhelper --refresh <handle> -> refreshes one matched handle
//
// Lives in its own binary because reaching fmfd needs the
// com.apple.icloud.fmfd.access entitlement, and that entitlement combined with
// platform-application (which locationspoofd needs for location simulation) is
// killed by AMFI on this device. So FMF access is isolated here, entitled
// WITHOUT platform-application, and the daemon spawns us on demand.
//
// FMFCore is dlopen'd and driven purely via the ObjC runtime, so nothing links
// the private framework at build time.
//
// Notes learned the hard way:
//  - the delegate queue MUST be an NSOperationQueue (FMF dispatches via
//    -addOperationWithBlock:; a dispatch_queue crashes it),
//  - -setHandles: wants an *NSSet* (an NSArray throws in its internal -minusSet:),
//  - fmfd only *delivers* location updates to clients that also hold
//    com.apple.icloud.findmydeviced.access (bare fmfd.access lists handles but
//    never pushes fixes),
//  - cached reads (-locationForHandle:completion:) can be tens of minutes old;
//    a live locate (-forceRefresh on followed handles) pushes fixes via
//    -didReceiveLocation:.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static const NSTimeInterval kRefreshDeadline = 40.0; // hard cap for --refresh
static const NSTimeInterval kCachedDeadline  = 8.0;  // hard cap for cached reads
static const NSTimeInterval kRecentCacheWindow = 120.0;
static const NSTimeInterval kRefreshPollInterval = 0.2;

@interface FMFLocation : NSObject
@property(nonatomic) CLLocationCoordinate2D coordinate;
@property(nonatomic, strong) NSDate *timestamp;
@property(nonatomic, readonly) BOOL isValid;
@property(nonatomic) double horizontalAccuracy;
@property(nonatomic, copy) NSString *shortAddress;
@property(nonatomic, copy) NSString *longAddress;
@property(nonatomic, strong) id handle;
@end

@interface FMFHandle : NSObject
+ (instancetype)handleWithId:(NSString *)i;
- (NSString *)identifier;
@end

@interface FMFSession : NSObject
- (instancetype)initWithDelegate:(id)d delegateQueue:(id)q;
- (void)reloadDataIfNotLoaded;
- (void)forceRefresh;
- (void)setHandles:(id)handles;
- (void)locationForHandle:(id)h completion:(void (^)(FMFLocation *))c;
- (void)getHandlesSharingLocationsWithMeWithGroupId:(id)g completion:(void (^)(NSArray *))c;
@end

// Newest location per handle identifier, plus the set of handles we expect.
// Touched from delegate/completion callbacks (operation queue) and from main.
static NSMutableDictionary<NSString *, FMFLocation *> *gLatest;
static NSMutableSet<NSString *> *gExpected;
static NSMutableSet<NSString *> *gPollInFlight;
static NSMutableDictionary<NSString *, FMFHandle *> *gHandlesById;
static NSObject *gLock;
static BOOL gHandlesLoaded;
static NSTimeInterval gRefreshStart;

static BOOL IsRecentRefreshLocation(FMFLocation *loc) {
    return gRefreshStart > 0 &&
        loc.timestamp.timeIntervalSince1970 >= gRefreshStart - kRecentCacheWindow;
}

static void StoreLocation(FMFLocation *loc) {
    if (![loc isKindOfClass:objc_getClass("FMFLocation")]) return;
    NSString *hid = [loc.handle respondsToSelector:@selector(identifier)] ? [loc.handle identifier] : nil;
    if (!hid.length) return;
    @synchronized (gLock) {
        FMFLocation *prev = gLatest[hid];
        if (!prev || loc.timestamp.timeIntervalSince1970 >= prev.timestamp.timeIntervalSince1970)
            gLatest[hid] = loc;
    }
}

@interface FMFCollector : NSObject
@end
@implementation FMFCollector
- (void)didReceiveLocation:(FMFLocation *)loc {
    if (getenv("FMF_DEBUG")) fprintf(stderr, "rx didReceiveLocation class=%s\n", loc ? object_getClassName(loc) : "nil");
    StoreLocation(loc);
}
// Swallow every other delegate selector fmfd sends.
- (void)forwardInvocation:(NSInvocation *)inv {}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [NSMethodSignature signatureWithObjCTypes:"v@:@@@@"]; }
- (BOOL)respondsToSelector:(SEL)s { return YES; }
@end

// requireFresh=NO: done once every expected handle has any location.
// requireFresh=YES: done once every expected handle has a recent cache entry.
// forceRefresh often updates FMF's cache without delivering a usable
// didReceiveLocation callback to this helper, and FMF timestamps can lag
// wall-clock by several seconds.
static BOOL CoverageComplete(BOOL requireFresh) {
    @synchronized (gLock) {
        if (gHandlesLoaded && gExpected.count == 0) return YES;
        if (gExpected.count == 0) return NO;
        for (NSString *hid in gExpected) {
            FMFLocation *l = gLatest[hid];
            if (!l) return NO;
            if (requireFresh && !IsRecentRefreshLocation(l)) return NO;
        }
        return YES;
    }
}

static void PollRefreshCache(FMFSession *s) {
    NSArray<NSString *> *ids;
    @synchronized (gLock) {
        ids = [gExpected allObjects];
    }
    for (NSString *hid in ids) {
        FMFHandle *h;
        @synchronized (gLock) {
            if (IsRecentRefreshLocation(gLatest[hid])) continue;
            if ([gPollInFlight containsObject:hid]) continue;
            h = gHandlesById[hid];
            if (h) [gPollInFlight addObject:hid];
        }
        if (!h) continue;
        [s locationForHandle:h completion:^(FMFLocation *loc) {
            StoreLocation(loc);
            @synchronized (gLock) { [gPollInFlight removeObject:hid]; }
        }];
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL refresh = (argc > 1 && strcmp(argv[1], "--refresh") == 0);
        NSString *targetHandle = (refresh && argc > 2) ? [NSString stringWithUTF8String:argv[2]] : nil;
        NSTimeInterval deadline = refresh ? kRefreshDeadline : kCachedDeadline;

        gLatest = [NSMutableDictionary dictionary];
        gExpected = [NSMutableSet set];
        gPollInFlight = [NSMutableSet set];
        gHandlesById = [NSMutableDictionary dictionary];
        gLock = [NSObject new];
        gHandlesLoaded = NO;
        gRefreshStart = 0;

        if (!dlopen("/System/Library/PrivateFrameworks/FMFCore.framework/FMFCore", RTLD_NOW)) {
            printf("{\"ok\":false,\"message\":\"FMFCore unavailable\"}\n");
            return 1;
        }
        Class HandleCls = objc_getClass("FMFHandle");

        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        FMFSession *s = [[objc_getClass("FMFSession") alloc] initWithDelegate:[FMFCollector new]
                                                                 delegateQueue:delegateQueue];
        [s reloadDataIfNotLoaded];

        [s getHandlesSharingLocationsWithMeWithGroupId:nil completion:^(NSArray *ids) {
            NSArray *idArray = [ids respondsToSelector:@selector(allObjects)] ? [(id)ids allObjects] : ids;
            NSMutableArray *handles = [NSMutableArray array];
            for (id x in idArray) {
                NSString *identifier = [x isKindOfClass:NSString.class] ? x : [x description];
                if (!identifier.length) continue;
                if (targetHandle.length && ![identifier isEqualToString:targetHandle]) continue;
                FMFHandle *h = [HandleCls handleWithId:identifier];
                if (!h) continue;
                [handles addObject:h];
                @synchronized (gLock) {
                    [gExpected addObject:identifier];
                    gHandlesById[identifier] = h;
                }
            }
            @synchronized (gLock) { gHandlesLoaded = YES; }
            if (refresh) {
                [s setHandles:[NSSet setWithArray:handles]]; // follow (NSSet required)
                @synchronized (gLock) { gRefreshStart = [NSDate date].timeIntervalSince1970; }
                [s forceRefresh];                            // triggers live locates
            } else {
                for (FMFHandle *h in handles)
                    [s locationForHandle:h completion:^(FMFLocation *loc) { StoreLocation(loc); }];
            }
        }];

        // Pump the runloop until coverage is complete or the deadline hits.
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:deadline];
        while ([end timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kRefreshPollInterval]];
            if (refresh && gHandlesLoaded) PollRefreshCache(s);
            if (CoverageComplete(refresh)) break;
        }

        // Emit one row per expected handle (missing/never-located -> valid:false).
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        BOOL handlesLoaded;
        @synchronized (gLock) {
            handlesLoaded = gHandlesLoaded;
            for (NSString *hid in gExpected) {
                FMFLocation *loc = gLatest[hid];
                BOOL known = loc && loc.isValid &&
                    CLLocationCoordinate2DIsValid(loc.coordinate) &&
                    !(loc.coordinate.latitude == 0 && loc.coordinate.longitude == 0);
                // handle (phone/email) is the key the Android side matches against
                // its own contacts — we deliberately do NOT send this device's
                // contact name. address/fullAddress are the place, not the person.
                [out addObject:@{
                    @"handle": hid,
                    @"lat": known ? @(loc.coordinate.latitude) : [NSNull null],
                    @"lon": known ? @(loc.coordinate.longitude) : [NSNull null],
                    @"accuracy": known ? @(loc.horizontalAccuracy) : [NSNull null],
                    @"address": loc.shortAddress.length ? loc.shortAddress : [NSNull null],
                    @"fullAddress": loc.longAddress.length ? loc.longAddress : [NSNull null],
                    @"timestamp": loc.timestamp ? @((long long)loc.timestamp.timeIntervalSince1970) : [NSNull null],
                    @"valid": @(known),
                }];
            }
        }

        if (targetHandle.length && out.count == 0) {
            NSDictionary *err = @{
                @"ok": @NO,
                @"message": handlesLoaded ? @"friend handle not found" : @"timed out loading friend handles",
                @"handle": targetHandle
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:err options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return handlesLoaded ? 2 : 3;
        }

        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES, @"friends": out} options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
