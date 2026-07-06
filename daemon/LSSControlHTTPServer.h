#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSSControlHTTPServer : NSObject
- (BOOL)startOnPort:(int)port;   // binds 127.0.0.1 only
- (void)stop;
@end

NS_ASSUME_NONNULL_END
