#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSSDaemonClient : NSObject

- (void)getStatus:(void (^)(BOOL ok, NSDictionary *resp))completion;
- (void)getLogs:(void (^)(BOOL ok, NSString *logs))completion;
- (void)getToken:(void (^)(BOOL ok, NSString *token))completion;
@end

NS_ASSUME_NONNULL_END
