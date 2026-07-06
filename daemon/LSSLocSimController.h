#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LSSLogSink)(NSString *line);

@interface LSSLocSimController : NSObject

+ (instancetype)shared;

- (void)start;
- (void)stop;
- (void)pushLocation:(CLLocation *)location;

@end

NS_ASSUME_NONNULL_END
