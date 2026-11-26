#import <UIKit/UIKit.h>

@interface TPSettingsViewController : UITableViewController
+ (void)present;
// The muted rules page on its own sheet (from a feed's "1 post hidden" line).
+ (void)presentMutedRules;
// Called at launch: clears Threads' caches if "Clear Cache" was confirmed last time.
+ (void)runPendingCacheClear;
@end
