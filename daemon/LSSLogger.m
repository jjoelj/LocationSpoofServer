#import "LSSLogger.h"

@interface LSSLogger ()
@property(nonatomic, strong) dispatch_queue_t q;
@property(nonatomic, strong) NSMutableString *buffer;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, LSSLogObserver> *observers;

// For chunk decoding per tag (handles split lines)
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableData *> *pendingByTag;

@property(nonatomic, strong) NSDateFormatter *df;
@end

@implementation LSSLogger

+ (instancetype)shared {
    static LSSLogger *g;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g = [[LSSLogger alloc] init];
    });
    return g;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.lss.logger", DISPATCH_QUEUE_SERIAL);
        _buffer = [NSMutableString string];
        _observers = [NSMutableDictionary dictionary];
        _pendingByTag = [NSMutableDictionary dictionary];
        _maxChars = 20000;

        _df = [[NSDateFormatter alloc] init];
        _df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _df.dateFormat = @"HH:mm:ss.SSS";
    }
    return self;
}

- (NSString *)_timestamp {
    return [self.df stringFromDate:[NSDate date]];
}

- (NSString *)_formatLine:(NSString *)line tag:(NSString *)tag {
    // Ensure exactly one trailing newline
    NSString *l = line ?: @"";
    if (![l hasSuffix:@"\n"]) l = [l stringByAppendingString:@"\n"];

    NSString *ts = [self _timestamp];
    return [NSString stringWithFormat:@"%@ [%@] %@", ts, tag ?: @"LOG", l];
}

- (void)_appendFormatted:(NSString *)formatted {
    [self.buffer appendString:formatted];

    // Trim to maxChars (keep tail)
    if (self.buffer.length > self.maxChars) {
        NSUInteger extra = self.buffer.length - self.maxChars;
        // Avoid cutting in middle too painfully: just drop extra from the front.
        [self.buffer deleteCharactersInRange:NSMakeRange(0, extra)];
    }

    // Notify observers (on main thread by default)
    // (Observers often update UI; they can do their own dispatch if they want.)
    NSDictionary<NSUUID *, LSSLogObserver> *obs = [self.observers copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (LSSLogObserver cb in obs.allValues) {
            cb(formatted);
        }
    });
}

- (void)log:(NSString *)message tag:(NSString *)tag {
    if (!message) return;

    dispatch_async(self.q, ^{
        // If caller passed multi-line text, split and format each line
        NSArray<NSString *> *lines = [message componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *part = lines[i];
            // componentsSeparatedByString keeps last empty component if message ends with \n
            if (part.length == 0 && i == lines.count - 1) continue;

            NSString *formatted = [self _formatLine:part tag:tag];
            [self _appendFormatted:formatted];
        }
    });
}

- (void)logChunk:(NSData *)data tag:(NSString *)tag {
    if (data.length == 0) return;
    NSString *t = tag ?: @"LOG";

    dispatch_async(self.q, ^{
        NSMutableData *pending = self.pendingByTag[t];
        if (!pending) {
            pending = [NSMutableData data];
            self.pendingByTag[t] = pending;
        }
        [pending appendData:data];

        // Try UTF-8 decode; if it fails, fall back to ISO-8859-1-ish
        NSString *s = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:pending encoding:NSISOLatin1StringEncoding];
        if (!s) return;

        // We only want to emit complete lines; keep remainder after last '\n'
        NSRange lastNL = [s rangeOfString:@"\n" options:NSBackwardsSearch];
        if (lastNL.location == NSNotFound) {
            // no full line yet
            return;
        }

        NSString *complete = [s substringToIndex:lastNL.location + 1];
        NSString *remainder = [s substringFromIndex:lastNL.location + 1];

        // Reset pending to remainder bytes
        [pending setLength:0];
        NSData *remData = [remainder dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        [pending appendData:remData];

        // Emit complete lines
        NSArray<NSString *> *lines = [complete componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *line = lines[i];
            if (line.length == 0 && i == lines.count - 1) continue;
            NSString *formatted = [self _formatLine:line tag:t];
            [self _appendFormatted:formatted];
        }
    });
}

- (NSUUID *)subscribe:(LSSLogObserver)observer {
    NSUUID *token = [NSUUID UUID];
    if (!observer) return token;

    dispatch_async(self.q, ^{
        self.observers[token] = [observer copy];
    });
    return token;
}

- (void)unsubscribe:(NSUUID *)token {
    if (!token) return;
    dispatch_async(self.q, ^{
        [self.observers removeObjectForKey:token];
    });
}

- (NSString *)snapshot {
    __block NSString *out = @"";
    dispatch_sync(self.q, ^{
        out = [self.buffer copy];
    });
    return out;
}

@end
