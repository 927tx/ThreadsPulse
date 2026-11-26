#import <UIKit/UIKit.h>

// Author info (location / join date / new-account badge) shown next to names in the feed.
// Data comes from Threads' "About this profile" Bloks action, fetched one at a time with a
// delay, cached on disk, and paused for an hour when Threads signals a rate limit.
// Approach draws on lee-su-threads by meettomorrow (MIT); see ThirdPartyLicenses/lee-su-threads.txt

extern NSString *const TPAuthorInfoDidUpdateNotification; // userInfo @{ @"pk": pk }
extern void (^TPAuthorOpenProfile)(NSString *username);    // set by the tweak: opens @username in Threads

@interface TPAuthorInfo : NSObject
+ (BOOL)enabled;                                   // master switch on and at least one item on
+ (NSDictionary *)infoForPk:(NSString *)pk;        // cached @{ @"location", @"joined" } or nil
+ (void)requestPk:(NSString *)pk;                  // queue a fetch if not cached / not paused
+ (BOOL)isNewAccount:(NSString *)joined;           // joined within the last 2 months
+ (BOOL)isDefaultUsername:(NSString *)username;    // never changed from the sign-up default, e.g. camel.253044

+ (void)noteObjectSet:(id)objectSet source:(NSString *)source;
+ (void)noteUserSession:(id)session;
+ (void)noteService:(id)obj kind:(NSString *)kind;   // pando / consistency / analytics
+ (void)log:(NSString *)line;

+ (NSTimeInterval)pausedRemaining;
+ (void)resume;
+ (void)clearCache;
// For settings backup: the cached authors that were read successfully and haven't expired,
// and merging a backup in (an entry replaces one that expires sooner). Returns how many merged.
+ (NSDictionary *)exportCache;
+ (NSInteger)importCache:(NSDictionary *)entries;
+ (NSUInteger)cachedCount;
+ (NSArray<NSDictionary *> *)allEntries;          // cached authors: pk, location / hidden, joined, number, u, n
+ (NSString *)flagForCountry:(NSString *)name;
+ (NSUInteger)sessionRequestCount;
+ (NSString *)diagnostics;

// Feed header integration: call from the header content view's layoutSubviews.
+ (void)layoutBadgeInHeader:(UIView *)contentView;
// A feed post header's author and post: author, via (debug), code, mediaId (any may be missing).
+ (NSDictionary *)postInfoInHeader:(UIView *)contentView;
+ (NSString *)authorForPostCode:(NSString *)code;
+ (NSString *)usernameForPk:(NSString *)pk;
+ (NSString *)locationForUsername:(NSString *)username;   // cached country/region, or nil
+ (NSString *)pkForHeader:(UIView *)contentView;
+ (BOOL)isNewAccountForPk:(NSString *)pk;
+ (CGFloat)extraHeaderHeight;                     // added under the name in "own line" mode, else 0
@end
