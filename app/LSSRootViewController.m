#import "LSSRootViewController.h"
#import "LSSDaemonClient.h"
#import "LSSLogger.h"
#import "LSSQRGen.h"
#import <CoreGraphics/CoreGraphics.h>

// Render a QR for `string` with CoreGraphics. CoreImage's CIQRCodeGenerator
// segfaults on this device, so we encode the matrix ourselves (LSSQRGen) and
// fill black squares into a bitmap context.
static UIImage *QRImage(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t modules[29 * 29];
    int N = lss_qr_encode(data.bytes, (int)data.length, modules);
    if (N == 0) return nil;

    const int scale = 12, quiet = 4;
    int px = (N + 2 * quiet) * scale;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, px, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    CGContextSetGrayFillColor(ctx, 1.0, 1.0); CGContextFillRect(ctx, CGRectMake(0, 0, px, px)); // white
    CGContextSetGrayFillColor(ctx, 0.0, 1.0); // black modules
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++)
            if (modules[r * N + c]) {
                int x = (quiet + c) * scale;
                int y = (quiet + (N - 1 - r)) * scale; // CG origin is bottom-left
                CGContextFillRect(ctx, CGRectMake(x, y, scale, scale));
            }

    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

@interface LSSRootViewController ()
@property(nonatomic, strong) LSSDaemonClient *daemon;

@property(nonatomic, strong) UITextView *serverLogView;
@property(nonatomic, strong) UITextView *logView;

@property(nonatomic, strong) UIButton *statusBtn;
@property(nonatomic, strong) UIButton *friendsBtn;

@property(nonatomic, strong) UILabel *tokenCaption;
@property(nonatomic, strong) UILabel *tokenLabel;
@property(nonatomic, strong) UIButton *tokenEyeBtn;
@property(nonatomic, strong) UIButton *tokenEditBtn;
@property(nonatomic, strong) UIButton *tokenRegenBtn;
@property(nonatomic, strong) UIButton *tokenQRBtn;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, assign) BOOL tokenHidden;
@property(nonatomic, strong) UIImage *qrCache; // built once; math is not free

@property(nonatomic, strong) NSTimer *logTimer;
@end

@implementation LSSRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.daemon = [[LSSDaemonClient alloc] init];
    self.tokenHidden = YES;

    [self buildUI];
    [self startLogPolling];
    [self fetchToken];
}

- (void)fetchToken {
    __weak typeof(self) weakSelf = self;
    [self.daemon getToken:^(BOOL ok, NSString *token) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.token = (ok && token.length) ? token : nil;
            weakSelf.qrCache = nil; // token changed, drop cached image
            [weakSelf updateTokenDisplay];
        });
    }];
}

// Bullets when hidden, the value when revealed; keeps the eye icon in sync.
- (void)updateTokenDisplay {
    if (self.token.length == 0) {
        self.tokenLabel.text = @"(unavailable)";
    } else if (self.tokenHidden) {
        NSUInteger keep = MIN((NSUInteger)4, self.token.length);
        self.tokenLabel.text = [@"••••••••" stringByAppendingString:[self.token substringFromIndex:self.token.length - keep]];
    } else {
        self.tokenLabel.text = self.token;
    }
    NSString *icon = self.tokenHidden ? @"eye" : @"eye.slash";
    [self.tokenEyeBtn setImage:[UIImage systemImageNamed:icon] forState:UIControlStateNormal];
}

- (void)toggleTokenVisibility {
    self.tokenHidden = !self.tokenHidden;
    [self updateTokenDisplay];
}

- (void)editToken {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Set Token"
                                                                   message:@"8-128 chars of A-Za-z0-9._~-"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"new token";
        tf.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *tok = alert.textFields.firstObject.text ?: @"";
        [weakSelf.daemon setToken:tok completion:^(BOOL ok, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    [weakSelf log:@"token updated"];
                    [weakSelf fetchToken];
                } else {
                    [weakSelf log:[NSString stringWithFormat:@"set token failed: %@", message]];
                }
            });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)regenerateToken {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Regenerate Token?"
                                                                   message:@"Clients using the current token will stop working."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Regenerate" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [weakSelf.daemon regenerateToken:^(BOOL ok, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) {
                    [weakSelf log:@"token regenerated"];
                    [weakSelf fetchToken];
                } else {
                    [weakSelf log:[NSString stringWithFormat:@"regenerate failed: %@", message]];
                }
            });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showQR {
    if (self.token.length == 0) return;
    if (!self.qrCache) self.qrCache = QRImage(self.token); // cache: encode once
    UIImage *img = self.qrCache;
    if (!img) return;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.layer.magnificationFilter = kCAFilterNearest; // keep QR pixels crisp
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"Scan in the Android app · tap to dismiss";
    hint.font = [UIFont systemFontOfSize:14];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    [vc.view addSubview:iv];
    [vc.view addSubview:hint];
    UILayoutGuide *g = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [iv.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [iv.widthAnchor constraintEqualToAnchor:g.widthAnchor multiplier:0.8],
        [iv.heightAnchor constraintEqualToAnchor:iv.widthAnchor],
        [hint.topAnchor constraintEqualToAnchor:iv.bottomAnchor constant:16],
        [hint.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    ]];

    [vc.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissQR)]];
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)dismissQR {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [self.logTimer invalidate];
    self.logTimer = nil;
}

#pragma mark - UI

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor systemGray4Color].CGColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildUI {
    self.statusBtn = [self makeButton:@"Status" action:@selector(statusPressed)];
    self.friendsBtn = [self makeButton:@"Friends" action:@selector(friendsPressed)];

    self.tokenCaption = [[UILabel alloc] init];
    self.tokenCaption.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.tokenCaption.textColor = [UIColor tertiaryLabelColor];
    self.tokenCaption.text = @"TOKEN";

    self.tokenLabel = [[UILabel alloc] init];
    self.tokenLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.tokenLabel.textColor = [UIColor secondaryLabelColor];
    self.tokenLabel.adjustsFontSizeToFitWidth = YES;
    self.tokenLabel.minimumScaleFactor = 0.6;
    self.tokenLabel.text = @"loading token…";

    self.tokenEyeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.tokenEyeBtn setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    [self.tokenEyeBtn addTarget:self action:@selector(toggleTokenVisibility) forControlEvents:UIControlEventTouchUpInside];

    self.tokenEditBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.tokenEditBtn setImage:[UIImage systemImageNamed:@"pencil"] forState:UIControlStateNormal];
    [self.tokenEditBtn addTarget:self action:@selector(editToken) forControlEvents:UIControlEventTouchUpInside];

    self.tokenRegenBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.tokenRegenBtn setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    [self.tokenRegenBtn addTarget:self action:@selector(regenerateToken) forControlEvents:UIControlEventTouchUpInside];

    self.tokenQRBtn = [self makeButton:@"QR" action:@selector(showQR)];

    self.serverLogView = [[UITextView alloc] init];
    self.serverLogView.editable = NO;
    self.serverLogView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.serverLogView.layer.cornerRadius = 12;
    self.serverLogView.layer.borderWidth = 1.0;
    self.serverLogView.layer.borderColor = [UIColor systemGray4Color].CGColor;

    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.layer.cornerRadius = 12;
    self.logView.layer.borderWidth = 1.0;
    self.logView.layer.borderColor = [UIColor systemGray4Color].CGColor;

    UIView *container = [[UIView alloc] init];
    [self.view addSubview:container];
    [container addSubview:self.statusBtn];
    [container addSubview:self.friendsBtn];
    [container addSubview:self.tokenCaption];
    [container addSubview:self.tokenLabel];
    [container addSubview:self.tokenEyeBtn];
    [container addSubview:self.tokenEditBtn];
    [container addSubview:self.tokenRegenBtn];
    [container addSubview:self.tokenQRBtn];
    [container addSubview:self.serverLogView];
    [container addSubview:self.logView];

    container.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.friendsBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.tokenCaption.translatesAutoresizingMaskIntoConstraints = NO;
    self.tokenLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.tokenEyeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.tokenEditBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.tokenRegenBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.tokenQRBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.serverLogView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tokenQRBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.tokenEyeBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.tokenEditBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.tokenRegenBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [container.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [container.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [container.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],

        [self.statusBtn.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.statusBtn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.statusBtn.trailingAnchor constraintEqualToAnchor:container.centerXAnchor constant:-6],

        [self.friendsBtn.topAnchor constraintEqualToAnchor:self.statusBtn.topAnchor],
        [self.friendsBtn.leadingAnchor constraintEqualToAnchor:container.centerXAnchor constant:6],
        [self.friendsBtn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [self.tokenCaption.topAnchor constraintEqualToAnchor:self.statusBtn.bottomAnchor constant:12],
        [self.tokenCaption.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [self.tokenQRBtn.topAnchor constraintEqualToAnchor:self.tokenCaption.bottomAnchor constant:4],
        [self.tokenQRBtn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [self.tokenRegenBtn.centerYAnchor constraintEqualToAnchor:self.tokenQRBtn.centerYAnchor],
        [self.tokenRegenBtn.trailingAnchor constraintEqualToAnchor:self.tokenQRBtn.leadingAnchor constant:-12],

        [self.tokenEditBtn.centerYAnchor constraintEqualToAnchor:self.tokenQRBtn.centerYAnchor],
        [self.tokenEditBtn.trailingAnchor constraintEqualToAnchor:self.tokenRegenBtn.leadingAnchor constant:-12],

        [self.tokenEyeBtn.centerYAnchor constraintEqualToAnchor:self.tokenQRBtn.centerYAnchor],
        [self.tokenEyeBtn.trailingAnchor constraintEqualToAnchor:self.tokenEditBtn.leadingAnchor constant:-12],

        [self.tokenLabel.centerYAnchor constraintEqualToAnchor:self.tokenQRBtn.centerYAnchor],
        [self.tokenLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.tokenLabel.trailingAnchor constraintEqualToAnchor:self.tokenEyeBtn.leadingAnchor constant:-8],

        [self.serverLogView.topAnchor constraintEqualToAnchor:self.tokenQRBtn.bottomAnchor constant:12],
        [self.serverLogView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.serverLogView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [self.logView.topAnchor constraintEqualToAnchor:self.serverLogView.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],

        [self.serverLogView.heightAnchor constraintEqualToAnchor:self.logView.heightAnchor],
        [self.serverLogView.heightAnchor constraintGreaterThanOrEqualToConstant:120],
        [self.logView.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
}

#pragma mark - Log helpers

- (void)log:(NSString *)line {
    [[LSSLogger shared] log:line tag:@"UI"];
    self.logView.text = [[LSSLogger shared] snapshot];
    NSRange bottom = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:bottom];
}

- (void)startLogPolling {
    __weak typeof(self) weakSelf = self;
    [self.daemon getLogs:^(BOOL ok, NSString *logs) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) return;
            weakSelf.serverLogView.text = logs ?: @"";
            NSRange bottom = NSMakeRange(weakSelf.serverLogView.text.length - 1, 1);
            [weakSelf.serverLogView scrollRangeToVisible:bottom];
            [weakSelf log:@"log polling started"];
        });
    }];

    self.logTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *t) {
        if (weakSelf.token.length == 0) [weakSelf fetchToken]; // daemon may start after us
        [weakSelf.daemon getLogs:^(BOOL ok, NSString *logs) {
            if (!ok || !logs) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.serverLogView.text = logs ?: @"";
                NSRange bottom = NSMakeRange(weakSelf.serverLogView.text.length - 1, 1);
                [weakSelf.serverLogView scrollRangeToVisible:bottom];
            });
        }];
    }];
}

#pragma mark - Button actions

- (void)friendsPressed {
    [self log:@"fetching Find My friends… (may take ~10s)"];
    __weak typeof(self) weakSelf = self;
    [self.daemon getFriends:^(BOOL ok, NSArray *friends) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { [weakSelf log:@"friends: FAIL"]; return; }
            NSMutableString *s = [NSMutableString stringWithFormat:@"friends (%lu):\n", (unsigned long)friends.count];
            for (NSDictionary *f in friends) {
                if ([f[@"valid"] boolValue]) {
                    [s appendFormat:@"  %@  %.5f, %.5f\n", f[@"handle"], [f[@"lat"] doubleValue], [f[@"lon"] doubleValue]];
                } else {
                    [s appendFormat:@"  %@  (no location)\n", f[@"handle"]];
                }
            }
            [weakSelf log:s];
        });
    }];
}

- (void)statusPressed {
    [self log:@"status pressed"];
    __weak typeof(self) weakSelf = self;
    [self.daemon getStatus:^(BOOL ok, NSDictionary *resp) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                [weakSelf log:@"status: FAIL"];
                return;
            }
            NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:NSJSONWritingPrettyPrinted error:nil];
            NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : resp.description;
            [weakSelf log:[NSString stringWithFormat:@"status:\n%@\n", s]];
        });
    }];
}

@end
