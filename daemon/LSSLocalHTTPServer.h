#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LSSLogSink)(NSString *line);
typedef void (^LSSLocationSink)(double lat, double lon);

@interface LSSLocalHTTPServer : NSObject
@property(nonatomic, assign, readonly) int port;
@property(nonatomic, copy) NSString *authToken;
@property(nonatomic, copy) LSSLocationSink locationSink;

- (BOOL)startOnPort:(int)port;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
