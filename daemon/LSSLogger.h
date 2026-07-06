#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LSSLogObserver)(NSString *formattedLine);

@interface LSSLogger : NSObject

+ (instancetype)shared;

/// Set max in-memory log size (characters). Default: 20000.
@property(nonatomic, assign) NSUInteger maxChars;

/// Append a single log line (you can include or omit trailing "\n")
- (void)log:(NSString *)message tag:(NSString *)tag;

/// Append raw chunks (useful for tailscale logfd pipe). This will split into lines.
- (void)logChunk:(NSData *)data tag:(NSString *)tag;

/// Subscribe to future log lines. Returns a token you can use to unsubscribe.
- (NSUUID *)subscribe:(LSSLogObserver)observer;

/// Unsubscribe.
- (void)unsubscribe:(NSUUID *)token;

/// Snapshot of current buffer (already formatted lines).
- (NSString *)snapshot;

@end

NS_ASSUME_NONNULL_END
