#import <Foundation/Foundation.h>

extern NSString *const TPKeyBlockAds;
extern NSString *const TPKeyStripTracking;
extern NSString *const TPKeyShowDownloadBtn;
extern NSString *const TPKeyDebugToast;
extern NSString *const TPKeyOriginalAvatar;
extern NSString *const TPKeyOriginalImage;
extern NSString *const TPKeyVideoQuality;   // 0 highest, 1 720p, 2 ask
extern NSString *const TPKeyVideoFormat;    // 0 keep HDR, 1 compatible (H.264 SDR)
extern NSString *const TPKeySaveToAlbum;
extern NSString *const TPKeyKeepDownloadCopies;
extern NSString *const TPKeyThreadDownloadBtn;
extern NSString *const TPKeyHideInCaptures;
extern NSString *const TPKeyAuthorInfo;
extern NSString *const TPKeyAuthorLocation;
extern NSString *const TPKeyAuthorJoined;
extern NSString *const TPKeyAuthorNewBadge;
extern NSString *const TPKeyAuthorOwnLine;
extern NSString *const TPKeyAuthorJoinNumber;
extern NSString *const TPKeyAuthorDefaultName;
extern NSString *const TPKeyClipboardLinks;
extern NSString *const TPKeyConfirmLike;
extern NSString *const TPKeyHideFollowSuggest;
extern NSString *const TPKeyHideIGConnections;
extern NSString *const TPKeyNoAutoplay;
extern NSString *const TPKeyNoMusicAutoplay;
extern NSString *const TPKeyHideFeedSuggest;
extern NSString *const TPKeyBlockScreenshotDetect;
extern NSString *const TPKeyBlockAnalytics;
extern NSString *const TPKeyExternalBrowser;
extern NSString *const TPKeyHideIGButton;
extern NSString *const TPKeyNoSeen;
extern NSString *const TPKeyKeepUnsent;
extern NSString *const TPKeyNoTyping;
extern NSString *const TPKeyHideProfileSearch;
extern NSString *const TPKeyHideSearchSuggest;
extern NSString *const TPKeyHidePostFeedback;
extern NSString *const TPKeySeenOnReply;
extern NSString *const TPKeyHomeLongPress;
extern NSString *const TPKeyAutoUpdateCheck;
extern NSString *const TPKeyTheme;
extern NSString *const TPKeyLanguage;   // 0 follow system · 1 English · 2 繁體中文 · 3 简体中文 · 4 日本語 · 5 한국어
extern NSString *const TPKeySideloadFix;
extern NSString *const TPKeyCopyProfile;
extern NSString *const TPKeyPinTabBar;
extern NSString *const TPKeyKeepFeed;
extern NSString *const TPKeyNoPullRefresh;
extern NSString *const TPKeyMuteRefreshSound;
extern NSString *const TPKeyTabNoScrollTop;
extern NSString *const TPKeyTabNoRefresh;

extern NSString *const TPKeyPlaySpeed;
extern NSString *const TPKeyClipboardMode;
extern NSString *const TPKeyBannerPosition;
extern NSString *const TPKeyKeepFeedLimit;
extern NSString *const TPKeyDownloadHistoryLimit;
extern NSString *const TPKeyHideNewAccounts;
extern NSString *const TPKeyBackupMutedRules;
extern NSString *const TPKeyBackupAuthors;
extern NSString *const TPKeyFilterKeywords;
extern NSString *const TPKeyAlbumByAuthor;
extern NSString *const TPKeyDuplicateWarn;
extern NSString *const TPKeyNameFromPost;
extern NSString *const TPKeyNameParts;       // e.g. "author,date,time,code,index,!country,!threads" (! = off)
extern NSString *const TPKeyNameSeparator;   // 0 "_", 1 "-", 2 space
extern NSString *const TPKeyNameDateStyle;   // 0 20261126_153012, 1 2026-11-26_15-30-12
extern NSString *const TPKeyPostDate;
extern NSString *const TPKeyTimeParts;       // e.g. "relative,!weekday,date,time" (! = off); only "relative" on = Threads' own time
extern NSString *const TPKeyTimeSeparator;   // 0 " · ", 1 " - ", 2 " | ", 3 space
extern NSString *const TPKeyTimeYear;        // 0 never, 1 only for earlier years, 2 always
extern NSString *const TPKeyTimeSeconds;
extern NSString *const TPKeyTimeWeekdayFull;   // "星期六" instead of "週六"

// Posted after setBool:/setInteger:, with userInfo @{ @"key": key }.
extern NSString *const TPPrefsDidChangeNotification;

@interface TPPrefs : NSObject
+ (BOOL)boolForKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (NSInteger)integerForKey:(NSString *)key;
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key;
+ (NSString *)stringForKey:(NSString *)key;
+ (void)setString:(NSString *)value forKey:(NSString *)key;
// Muted rules (keywords, @authors, /regex/). Rules are separated by "," "，" "、" or new lines, except
// that a /regex/ runs to its closing slash, so a regex may contain commas.
+ (NSArray<NSString *> *)parseMutedRules:(NSString *)raw;
// Rules whose time limit has passed are left out (and forgotten on the next save).
+ (NSArray<NSString *> *)mutedRules;
+ (void)setMutedRules:(NSArray<NSString *> *)rules;
// When a temporary rule ends (nil: permanent). Pass nil to make a rule permanent.
+ (NSDate *)expiryForMutedRule:(NSString *)rule;
+ (void)setExpiry:(NSDate *)date forMutedRule:(NSString *)rule;
// Today's filter count: one call per post hidden, with the reason shown on its "hidden" line.
+ (void)recordFilteredPostWithReason:(NSString *)reason;
// @{ count: NSNumber, top: reason or missing } for today.
+ (NSDictionary *)filterStatsToday;
// Ads kept out of the feed and replies today (sponsored items dropped or not inserted), shown on
// the settings card.
+ (void)recordBlockedAds:(NSInteger)count;
+ (NSInteger)blockedAdsToday;
+ (void)resetAll;
// Post time format: parts as @{ id, on } in order (relative, weekday, date, time).
+ (NSArray<NSDictionary *> *)timeParts;
+ (void)setTimeParts:(NSArray<NSDictionary *> *)parts;   // nil resets
// The post time as set in Post Time Format, or nil when it's Threads' own relative time.
// `relative` is Threads' own text ("3h"), used for the relative part.
+ (NSString *)postTimeForDate:(NSDate *)date relative:(NSString *)relative;
// Turns the old 4-option Post Time Format (tp_exact_time) into parts, once.
+ (void)migrateExactTime;
+ (NSUserDefaults *)defaults;

+ (NSData *)exportJSONData;
// Returns how many settings were applied (-1: not a settings file). Muted rules and cached
// authors in the file are merged in; their counts come back in *extra, if given.
+ (NSInteger)importJSONData:(NSData *)data;
+ (NSInteger)importJSONData:(NSData *)data mutedRules:(NSInteger *)rules authors:(NSInteger *)authors;
@end
