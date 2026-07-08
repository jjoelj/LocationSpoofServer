#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSSDaemonClient : NSObject

- (void)getLogs:(void (^)(BOOL ok, NSString *logs))completion;
- (void)getToken:(void (^)(BOOL ok, NSString *token))completion;
- (void)setToken:(NSString *)token completion:(void (^)(BOOL ok, NSString *message))completion;
- (void)regenerateToken:(void (^)(BOOL ok, NSString *message))completion;
@end

NS_ASSUME_NONNULL_END
