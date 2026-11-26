#import <UIKit/UIKit.h>

// Non-blocking download progress shown at the top centre of the screen, under the Dynamic
// Island: a small pill ("Downloading 2 of 5 · 54% · 2.3 MB/s"). Tapping it expands a card that
// lists each file's state with Cancel buttons; tapping the pill again collapses it. The rest of
// the app stays usable. Several capsules stack downwards.
@interface TPCapsule : NSObject
+ (instancetype)showWithTitle:(NSString *)title cancel:(void (^)(void))cancel;
- (void)setTitle:(NSString *)title;
// progress < 0: indeterminate (spinner). subtitle: detail line under the active row.
- (void)setProgress:(CGFloat)progress subtitle:(NSString *)subtitle;
- (void)setSpeed:(NSString *)speed;
// Rows for the expanded card: @{ @"title", @"status", @"state": @(0 waiting, 1 active, 2 done, 3 failed) }.
- (void)setRows:(NSArray<NSDictionary *> *)rows;
- (void)finishSuccess:(NSString *)message;
- (void)finishFailure:(NSString *)message;
- (void)dismiss;
// Optional: number of posts queued after this one ("Cancel All" appears when > 0).
@property (nonatomic, copy) NSInteger (^queueCount)(void);
@property (nonatomic, copy) void (^cancelAll)(void);
// A capsule whose tag is "hosted" stays hidden: another view shows its progress instead (the
// thread page's download button). It reappears as soon as that view goes away.
@property (nonatomic, copy) NSString *tag;
+ (void)setHostedTag:(NSString *)tag hosted:(BOOL)hosted;
@end
