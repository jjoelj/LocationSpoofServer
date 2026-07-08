// Standalone helper: prints Find My friends' locations as JSON, then exits.
//
// Lives in its own binary because reaching fmfd needs the
// com.apple.icloud.fmfd.access entitlement, and that entitlement combined with
// platform-application (which locationspoofd needs for location simulation) is
// killed by AMFI on this device. So FMF access is isolated here, entitled
// WITHOUT platform-application, and the daemon spawns us on demand.
//
// FMFCore is dlopen'd and driven purely via the ObjC runtime, so nothing links
// the private framework at build time.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface FMFLocation : NSObject
@property(nonatomic) CLLocationCoordinate2D coordinate;
@property(nonatomic, strong) NSString *label;
@property(nonatomic, strong) NSDate *timestamp;
@property(nonatomic, readonly) BOOL isValid;
@property(nonatomic) double horizontalAccuracy;
@property(nonatomic, copy) NSString *shortAddress; // "San Jose, CA"
@property(nonatomic, copy) NSString *longAddress;  // full street address
@end

@interface FMFHandle : NSObject
+ (instancetype)handleWithId:(NSString *)i;
- (NSString *)prettyName;
@end

@interface FMFSession : NSObject
- (instancetype)initWithDelegate:(id)d;
- (void)reloadDataIfNotLoaded;
- (void)forceRefresh;
- (void)locationForHandle:(id)h completion:(void (^)(FMFLocation *))c;
- (void)getHandlesSharingLocationsWithMeWithGroupId:(id)g completion:(void (^)(NSArray *))c;
@end

// FMFSession needs a delegate; it sends model-update selectors we don't care
// about, so accept every selector and no-op.
@interface FMFStubDelegate : NSObject
@end
@implementation FMFStubDelegate
- (void)forwardInvocation:(NSInvocation *)inv {}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [NSMethodSignature signatureWithObjCTypes:"v@:@"]; }
- (BOOL)respondsToSelector:(SEL)s { return YES; }
@end

int main(void) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/FMFCore.framework/FMFCore", RTLD_NOW)) {
            printf("{\"ok\":false,\"message\":\"FMFCore unavailable\"}\n");
            return 1;
        }

        Class HandleCls = objc_getClass("FMFHandle");
        FMFSession *s = [[objc_getClass("FMFSession") alloc] initWithDelegate:[FMFStubDelegate new]];
        [s reloadDataIfNotLoaded];
        [s forceRefresh];

        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        __block NSInteger outstanding = -1; // set once we know the friend count

        [s getHandlesSharingLocationsWithMeWithGroupId:nil completion:^(NSArray *ids) {
            outstanding = (NSInteger)ids.count;
            if (outstanding == 0) return;
            for (id x in ids) {
                NSString *identifier = [x isKindOfClass:NSString.class] ? x : [x description];
                FMFHandle *h = [HandleCls handleWithId:identifier];
                [s locationForHandle:h completion:^(FMFLocation *loc) {
                    @synchronized (out) {
                        BOOL known = loc && loc.isValid &&
                            CLLocationCoordinate2DIsValid(loc.coordinate) &&
                            !(loc.coordinate.latitude == 0 && loc.coordinate.longitude == 0);
                        // handle (phone/email) is the key the Android side matches
                        // against its contacts. name is this device's contact
                        // resolution (FMFHandle.prettyName) — best-effort only; note
                        // FMFLocation.label/subtitle are the *place*, never the person.
                        NSString *name = [h respondsToSelector:@selector(prettyName)] ? h.prettyName : nil;
                        if (!name.length) name = identifier;
                        [out addObject:@{
                            @"handle": identifier ?: @"",
                            @"name": name ?: @"?",
                            @"lat": known ? @(loc.coordinate.latitude) : [NSNull null],
                            @"lon": known ? @(loc.coordinate.longitude) : [NSNull null],
                            @"accuracy": known ? @(loc.horizontalAccuracy) : [NSNull null],
                            @"address": loc.shortAddress.length ? loc.shortAddress : [NSNull null],
                            @"fullAddress": loc.longAddress.length ? loc.longAddress : [NSNull null],
                            @"timestamp": loc.timestamp ? @((long long)loc.timestamp.timeIntervalSince1970) : [NSNull null],
                            @"valid": @(known),
                        }];
                        outstanding--;
                    }
                }];
            }
        }];

        // Wait for all per-handle completions, capped so we never hang the daemon.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
        while ([deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            @synchronized (out) { if (outstanding == 0) break; }
        }

        NSDictionary *result = @{@"ok": @YES, @"friends": out};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
