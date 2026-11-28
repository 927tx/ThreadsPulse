#import "TPPrefs.h"
#import "TPAuthorInfo.h"
#import "TPVersion.h"

NSString *const TPKeyBlockAds        = @"tp_block_ads";
NSString *const TPKeyStripTracking   = @"tp_strip_tracking";
NSString *const TPKeyShowDownloadBtn = @"tp_show_download_btn";
NSString *const TPKeyDebugToast      = @"tp_debug_toast";
NSString *const TPKeyOriginalAvatar  = @"tp_original_avatar";
NSString *const TPKeyOriginalImage   = @"tp_original_image";
NSString *const TPKeyVideoQuality    = @"tp_video_quality";
NSString *const TPKeyVideoFormat     = @"tp_video_format";
NSString *const TPKeySaveToAlbum     = @"tp_save_to_album";
NSString *const TPKeyKeepDownloadCopies = @"tp_keep_download_copies";
NSString *const TPKeyThreadDownloadBtn = @"tp_thread_download_btn";
NSString *const TPKeyHideInCaptures  = @"tp_hide_in_captures";
NSString *const TPKeyAuthorInfo      = @"tp_author_info";
NSString *const TPKeyAuthorLocation  = @"tp_author_location";
NSString *const TPKeyAuthorJoined    = @"tp_author_joined";
NSString *const TPKeyAuthorNewBadge  = @"tp_author_new";
NSString *const TPKeyAuthorOwnLine   = @"tp_author_own_line";
NSString *const TPKeyAuthorJoinNumber = @"tp_author_join_number";
NSString *const TPKeyAuthorDefaultName = @"tp_author_default_name";
NSString *const TPKeyClipboardLinks  = @"tp_clipboard_links";
NSString *const TPKeyConfirmLike     = @"tp_confirm_like";
NSString *const TPKeyPlaySpeed       = @"tp_play_speed";
NSString *const TPKeyClipboardMode   = @"tp_clipboard_mode";
NSString *const TPKeyBannerPosition  = @"tp_banner_position";
NSString *const TPKeyKeepFeed        = @"tp_keep_feed";
NSString *const TPKeyPinTabBar       = @"tp_pin_tab_bar";
NSString *const TPKeyCopyProfile     = @"tp_copy_profile";
NSString *const TPKeySideloadFix     = @"tp_sideload_fix";
NSString *const TPKeyBlockScreenshotDetect = @"tp_block_screenshot_detect";
NSString *const TPKeyBlockAnalytics  = @"tp_block_analytics";
NSString *const TPKeyExternalBrowser = @"tp_external_browser";
NSString *const TPKeyHideIGButton    = @"tp_hide_ig_button";
NSString *const TPKeyNoSeen          = @"tp_no_seen";
NSString *const TPKeyKeepUnsent      = @"tp_keep_unsent";
NSString *const TPKeyNoTyping        = @"tp_no_typing";
NSString *const TPKeySeenOnReply     = @"tp_seen_on_reply";
NSString *const TPKeyHidePostFeedback = @"tp_hide_post_feedback";
NSString *const TPKeyHideSearchSuggest = @"tp_hide_search_suggest";
NSString *const TPKeyHideProfileSearch = @"tp_hide_profile_search";
NSString *const TPKeyHomeLongPress   = @"tp_home_long_press";
NSString *const TPKeyAutoUpdateCheck = @"tp_auto_update_check";
NSString *const TPKeyTheme           = @"tp_theme";
NSString *const TPKeyLanguage        = @"tp_language";
NSString *const TPKeyHideFeedSuggest = @"tp_hide_feed_suggest";
NSString *const TPKeyNoAutoplay      = @"tp_no_autoplay";
NSString *const TPKeyNoMusicAutoplay = @"tp_no_music_autoplay";
NSString *const TPKeyHideFollowSuggest = @"tp_hide_follow_suggest";
NSString *const TPKeyHideIGConnections = @"tp_hide_ig_connections";
NSString *const TPKeyKeepFeedLimit   = @"tp_keep_feed_limit";
NSString *const TPKeyNoPullRefresh   = @"tp_no_pull_refresh";
NSString *const TPKeyMuteRefreshSound = @"tp_mute_refresh_sound";
NSString *const TPKeyTabNoScrollTop  = @"tp_tab_no_scroll_top";
NSString *const TPKeyTabNoRefresh    = @"tp_tab_no_refresh";
NSString *const TPKeyDownloadHistoryLimit = @"tp_download_history_limit";
NSString *const TPKeyHideNewAccounts = @"tp_hide_new_accounts";
NSString *const TPKeyBackupMutedRules = @"tp_backup_muted_rules";
NSString *const TPKeyBackupAuthors  = @"tp_backup_authors";
NSString *const TPKeyFilterKeywords  = @"tp_filter_keywords";
NSString *const TPKeyAlbumByAuthor   = @"tp_album_by_author";
NSString *const TPKeyDuplicateWarn   = @"tp_duplicate_warn";
NSString *const TPKeyNameFromPost    = @"tp_name_from_post";
NSString *const TPKeyNameParts       = @"tp_name_parts";
NSString *const TPKeyNameSeparator   = @"tp_name_separator";
NSString *const TPKeyNameDateStyle   = @"tp_name_date_style";
NSString *const TPKeyPostDate        = @"tp_post_date";
NSString *const TPKeyTimeParts       = @"tp_time_parts";
NSString *const TPKeyTimeSeparator   = @"tp_time_separator";
NSString *const TPKeyTimeYear        = @"tp_time_year";
NSString *const TPKeyTimeSeconds     = @"tp_time_seconds";
NSString *const TPKeyTimeWeekdayFull = @"tp_time_weekday_full";

NSString *const TPPrefsDidChangeNotification = @"TPPrefsDidChangeNotification";

static NSString *const kSuite = @"com.example.threadspulse";

static NSArray<NSString *> *TPBoolKeys(void) {
    return @[TPKeyBlockAds, TPKeyStripTracking, TPKeyShowDownloadBtn, TPKeyDebugToast,
             TPKeyOriginalImage, TPKeySaveToAlbum, TPKeyKeepDownloadCopies, TPKeyThreadDownloadBtn, TPKeyHideInCaptures, TPKeyAuthorInfo, TPKeyAuthorLocation, TPKeyAuthorJoined, TPKeyAuthorNewBadge, TPKeyAuthorOwnLine, TPKeyAuthorJoinNumber, TPKeyAuthorDefaultName, TPKeyOriginalAvatar, TPKeyClipboardLinks, TPKeyConfirmLike, TPKeyKeepFeed, TPKeyHideFollowSuggest, TPKeyHideIGConnections, TPKeyPinTabBar, TPKeyCopyProfile, TPKeySideloadFix, TPKeyBlockScreenshotDetect, TPKeyBlockAnalytics, TPKeyExternalBrowser, TPKeyHideIGButton, TPKeyHomeLongPress, TPKeyNoSeen, TPKeyKeepUnsent, TPKeyNoTyping, TPKeySeenOnReply, TPKeyHidePostFeedback, TPKeyHideSearchSuggest, TPKeyHideProfileSearch, TPKeyHideFeedSuggest, TPKeyNoAutoplay, TPKeyNoMusicAutoplay,
             TPKeyNoPullRefresh, TPKeyTabNoScrollTop, TPKeyTabNoRefresh, TPKeyAutoUpdateCheck, TPKeyMuteRefreshSound, TPKeyHideNewAccounts, TPKeyAlbumByAuthor, TPKeyBackupMutedRules, TPKeyBackupAuthors, TPKeyDuplicateWarn, TPKeyNameFromPost, TPKeyPostDate, TPKeyTimeSeconds, TPKeyTimeWeekdayFull];
}
static NSArray<NSString *> *TPIntKeys(void) {
    return @[TPKeyVideoQuality, TPKeyVideoFormat, TPKeyPlaySpeed, TPKeyClipboardMode, TPKeyBannerPosition, TPKeyKeepFeedLimit, TPKeyDownloadHistoryLimit, TPKeyTheme, TPKeyLanguage, TPKeyNameSeparator, TPKeyNameDateStyle, TPKeyTimeSeparator, TPKeyTimeYear];
}
static NSInteger TPIntMax(NSString *key) {
    if ([key isEqualToString:TPKeyVideoQuality]) return 2;
    if ([key isEqualToString:TPKeyVideoFormat])  return 1;
    if ([key isEqualToString:TPKeyPlaySpeed])   return 3;
    if ([key isEqualToString:TPKeyLanguage])    return 6;
    if ([key isEqualToString:TPKeyClipboardMode])  return 1;
    if ([key isEqualToString:TPKeyBannerPosition]) return 2;
    if ([key isEqualToString:TPKeyKeepFeedLimit])  return 2;
    if ([key isEqualToString:TPKeyDownloadHistoryLimit]) return 3;
    if ([key isEqualToString:TPKeyTheme])          return 5;
    if ([key isEqualToString:TPKeyNameSeparator])  return 2;
    if ([key isEqualToString:TPKeyNameDateStyle])  return 1;
    if ([key isEqualToString:TPKeyTimeSeparator])  return 3;
    if ([key isEqualToString:TPKeyTimeYear])       return 2;
    return 0;
}

@implementation TPPrefs

+ (NSUserDefaults *)defaults {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
        [d registerDefaults:@{
            TPKeyBlockAds: @YES,        TPKeyStripTracking: @YES,   TPKeyShowDownloadBtn: @YES,
            TPKeyDebugToast: @NO,       TPKeyOriginalImage: @YES,  TPKeyVideoQuality: @0,  TPKeyVideoFormat: @0,  TPKeySaveToAlbum: @NO,  TPKeyKeepDownloadCopies: @NO,  TPKeyThreadDownloadBtn: @YES,  TPKeyHideInCaptures: @YES,
            TPKeyAuthorInfo: @NO, TPKeyAuthorLocation: @YES, TPKeyAuthorJoined: @YES, TPKeyAuthorNewBadge: @YES, TPKeyAuthorOwnLine: @YES, TPKeyAuthorJoinNumber: @YES, TPKeyAuthorDefaultName: @YES,
            TPKeyPlaySpeed: @0,
            TPKeyConfirmLike: @NO,      TPKeyOriginalAvatar: @YES,  TPKeyClipboardLinks: @NO,  TPKeyClipboardMode: @0,  TPKeyBannerPosition: @0,
            TPKeyHideFollowSuggest: @YES, TPKeyHideIGConnections: @YES, TPKeyPinTabBar: @NO, TPKeyCopyProfile: @YES, TPKeySideloadFix: @YES, TPKeyBlockScreenshotDetect: @YES, TPKeyBlockAnalytics: @NO, TPKeyExternalBrowser: @NO, TPKeyHideIGButton: @NO, TPKeyHomeLongPress: @YES, TPKeyNoSeen: @NO, TPKeyKeepUnsent: @NO, TPKeyNoTyping: @NO, TPKeySeenOnReply: @YES, TPKeyHidePostFeedback: @YES, TPKeyHideSearchSuggest: @YES, TPKeyHideProfileSearch: @NO, TPKeyTheme: @0, TPKeyLanguage: @0, TPKeyHideFeedSuggest: @YES, TPKeyNoAutoplay: @NO, TPKeyNoMusicAutoplay: @NO, TPKeyKeepFeed: @NO,         TPKeyKeepFeedLimit: @0,
            TPKeyNoPullRefresh: @NO,    TPKeyTabNoScrollTop: @NO,   TPKeyTabNoRefresh: @NO,     TPKeyAutoUpdateCheck: @YES,  TPKeyMuteRefreshSound: @NO,  TPKeyDownloadHistoryLimit: @0,  TPKeyHideNewAccounts: @NO,  TPKeyBackupMutedRules: @YES,  TPKeyBackupAuthors: @YES,  TPKeyFilterKeywords: @"",  TPKeyAlbumByAuthor: @NO,  TPKeyDuplicateWarn: @YES,  TPKeyNameFromPost: @YES,  TPKeyNameParts: @"",  TPKeyNameSeparator: @0,  TPKeyNameDateStyle: @0,  TPKeyPostDate: @YES,  TPKeyTimeParts: @"",  TPKeyTimeSeparator: @0,  TPKeyTimeYear: @1,  TPKeyTimeSeconds: @NO,  TPKeyTimeWeekdayFull: @NO,
        }];
    });
    return d;
}

+ (BOOL)boolForKey:(NSString *)key { return [[self defaults] boolForKey:key]; }
+ (void)setBool:(BOOL)value forKey:(NSString *)key {
    if (!key.length) return;
    [[self defaults] setBool:value forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:TPPrefsDidChangeNotification object:nil userInfo:@{ @"key": key }];
}
+ (NSInteger)integerForKey:(NSString *)key { return [[self defaults] integerForKey:key]; }
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if (!key.length) return;
    [[self defaults] setInteger:value forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:TPPrefsDidChangeNotification object:nil userInfo:@{ @"key": key }];
}
+ (NSString *)stringForKey:(NSString *)key {
    NSString *s = [[self defaults] stringForKey:key];
    return [s isKindOfClass:[NSString class]] ? s : @"";
}
+ (void)setString:(NSString *)value forKey:(NSString *)key {
    if (!key.length) return;
    [[self defaults] setObject:(value ?: @"") forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:TPPrefsDidChangeNotification object:nil userInfo:@{ @"key": key }];
}

+ (void)resetAll {
    for (NSString *k in TPBoolKeys()) [[self defaults] removeObjectForKey:k];
    for (NSString *k in TPIntKeys())  [[self defaults] removeObjectForKey:k];
    [[self defaults] removeObjectForKey:TPKeyFilterKeywords];
    [[self defaults] removeObjectForKey:TPKeyNameParts];
    [[self defaults] removeObjectForKey:TPKeyTimeParts];
    [[self defaults] removeObjectForKey:@"tp_filter_rule_expiry"];
}

+ (NSData *)exportJSONData {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (NSString *k in TPBoolKeys()) settings[k] = @([self boolForKey:k]);
    for (NSString *k in TPIntKeys())  settings[k] = @([self integerForKey:k]);
    NSString *parts = [self stringForKey:TPKeyNameParts];
    if (parts.length) settings[TPKeyNameParts] = parts;
    NSString *timeParts = [self stringForKey:TPKeyTimeParts];
    if (timeParts.length) settings[TPKeyTimeParts] = timeParts;
    NSMutableDictionary *root = [@{ @"app": @"ThreadsPulse", @"version": TP_VERSION, @"settings": settings } mutableCopy];
    // Muted rules (with their time limits) and the authors already read: after a reinstall,
    // Author Info doesn't have to read everyone again.
    NSArray *rules = [self boolForKey:TPKeyBackupMutedRules] ? [self mutedRules] : nil;
    if (rules.count) {
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *r in rules) {
            NSDate *end = [self expiryForMutedRule:r];
            [list addObject:end ? @{ @"rule": r, @"until": @(end.timeIntervalSince1970) } : @{ @"rule": r }];
        }
        root[@"mutedRules"] = list;
    }
    NSDictionary *authors = [self boolForKey:TPKeyBackupAuthors] ? [TPAuthorInfo exportCache] : nil;
    if (authors.count) root[@"authorCache"] = authors;
    return [NSJSONSerialization dataWithJSONObject:root
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:nil];
}

+ (NSInteger)importJSONData:(NSData *)data { return [self importJSONData:data mutedRules:NULL authors:NULL]; }

+ (NSInteger)importJSONData:(NSData *)data mutedRules:(NSInteger *)rulesOut authors:(NSInteger *)authorsOut {
    if (!data.length) return -1;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return -1;
    NSDictionary *settings = root[@"settings"];
    if (![settings isKindOfClass:[NSDictionary class]]) return -1;

    NSInteger applied = 0;
    for (NSString *k in TPBoolKeys()) {
        id v = settings[k];
        if ([v isKindOfClass:[NSNumber class]]) { [self setBool:[v boolValue] forKey:k]; applied++; }
    }
    for (NSString *k in TPIntKeys()) {
        id v = settings[k];
        if ([v isKindOfClass:[NSNumber class]]) {
            NSInteger n = [v integerValue];
            if (n >= 0 && n <= TPIntMax(k)) { [self setInteger:n forKey:k]; applied++; }
        }
    }
    if ([settings[TPKeyNameParts] isKindOfClass:[NSString class]] && [settings[TPKeyNameParts] length] < 200) {
        [self setString:settings[TPKeyNameParts] forKey:TPKeyNameParts];
        applied++;
    }
    if ([settings[TPKeyTimeParts] isKindOfClass:[NSString class]] && [settings[TPKeyTimeParts] length] < 200) {
        [self setString:settings[TPKeyTimeParts] forKey:TPKeyTimeParts];
        applied++;
    } else if ([settings[@"tp_exact_time"] isKindOfClass:[NSNumber class]]) {
        // A backup from before Post Time Format had parts.
        [self applyExactTimeMode:[settings[@"tp_exact_time"] integerValue]];
        applied++;
    }
    // Rules are added to the ones here (a rule already here keeps its own time limit).
    NSInteger addedRules = 0;
    if ([root[@"mutedRules"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *rules = [[self mutedRules] mutableCopy];
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        for (NSDictionary *e in root[@"mutedRules"]) {
            if (![e isKindOfClass:[NSDictionary class]] || ![e[@"rule"] isKindOfClass:[NSString class]]) continue;
            NSString *r = e[@"rule"];
            NSNumber *until = [e[@"until"] isKindOfClass:[NSNumber class]] ? e[@"until"] : nil;
            if (!r.length || [rules containsObject:r] || (until && until.doubleValue <= now)) continue;
            [rules addObject:r];
            if (until) [self setExpiry:[NSDate dateWithTimeIntervalSince1970:until.doubleValue] forMutedRule:r];
            addedRules++;
        }
        if (addedRules) [self setMutedRules:rules];
    }
    NSInteger authors = [TPAuthorInfo importCache:root[@"authorCache"]];
    if (rulesOut) *rulesOut = addedRules;
    if (authorsOut) *authorsOut = authors;
    return applied;
}
+ (NSArray<NSString *> *)parseMutedRules:(NSString *)raw {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!raw.length) return out;
    NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@",，、\n"];
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSUInteger i = 0, n = raw.length;
    while (i < n) {
        while (i < n && ([ws characterIsMember:[raw characterAtIndex:i]] || [seps characterIsMember:[raw characterAtIndex:i]])) i++;
        if (i >= n) break;
        NSUInteger start = i, end = NSNotFound;
        if ([raw characterAtIndex:i] == '/') {
            // A regex ends at an unescaped "/" followed only by spaces and then a separator or the end.
            for (NSUInteger j = i + 1; j < n; j++) {
                unichar c = [raw characterAtIndex:j];
                if (c == '\\') { j++; continue; }
                if (c != '/') continue;
                NSUInteger k = j + 1;
                while (k < n && [raw characterAtIndex:k] == ' ') k++;
                if (k >= n || [seps characterIsMember:[raw characterAtIndex:k]]) { end = j + 1; break; }
            }
        }
        if (end == NSNotFound) {
            end = start;
            while (end < n && ![seps characterIsMember:[raw characterAtIndex:end]]) end++;
        }
        NSString *t = [[raw substringWithRange:NSMakeRange(start, end - start)] stringByTrimmingCharactersInSet:ws];
        if (t.length && ![out containsObject:t]) [out addObject:t];
        i = end;
    }
    return out;
}

static NSString *const kTPRuleExpiryKey = @"tp_filter_rule_expiry";   // rule -> end time (seconds since 1970)

+ (NSArray<NSString *> *)mutedRules {
    // Read for every row the feed builds: parse again only when the saved text changed.
    static NSString *lastRaw;
    static NSArray<NSString *> *lastParsed;
    NSString *raw = [self stringForKey:TPKeyFilterKeywords] ?: @"";
    if (!lastParsed || ![raw isEqualToString:lastRaw]) { lastRaw = [raw copy]; lastParsed = [self parseMutedRules:raw]; }
    NSArray<NSString *> *all = lastParsed;
    NSDictionary *exp = [[self defaults] dictionaryForKey:kTPRuleExpiryKey];
    if (!exp.count) return all;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:all.count];
    for (NSString *r in all) {
        NSNumber *end = exp[r];
        if (end && end.doubleValue <= now) continue;
        [out addObject:r];
    }
    return out;
}

+ (void)setMutedRules:(NSArray<NSString *> *)rules {
    [self setString:[rules componentsJoinedByString:@"\n"] forKey:TPKeyFilterKeywords];
    NSDictionary *exp = [[self defaults] dictionaryForKey:kTPRuleExpiryKey];
    if (!exp.count) return;
    NSMutableDictionary *keep = [NSMutableDictionary dictionary];
    for (NSString *r in rules) if (exp[r]) keep[r] = exp[r];
    [[self defaults] setObject:keep forKey:kTPRuleExpiryKey];
}

+ (NSDate *)expiryForMutedRule:(NSString *)rule {
    NSNumber *end = [[self defaults] dictionaryForKey:kTPRuleExpiryKey][rule];
    return end ? [NSDate dateWithTimeIntervalSince1970:end.doubleValue] : nil;
}

+ (void)setExpiry:(NSDate *)date forMutedRule:(NSString *)rule {
    if (!rule.length) return;
    NSMutableDictionary *exp = [[[self defaults] dictionaryForKey:kTPRuleExpiryKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (date) exp[rule] = @(date.timeIntervalSince1970); else [exp removeObjectForKey:rule];
    [[self defaults] setObject:exp forKey:kTPRuleExpiryKey];
}

static NSString *TPTodayStamp(void) {
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:NSDate.date];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)c.year, (long)c.month, (long)c.day];
}

+ (void)recordFilteredPostWithReason:(NSString *)reason {
    NSUserDefaults *ud = [self defaults];
    NSDictionary *old = [ud dictionaryForKey:@"tp_filter_today"];
    NSString *day = TPTodayStamp();
    BOOL same = [old[@"day"] isEqualToString:day];
    NSMutableDictionary *reasons = same ? [old[@"reasons"] mutableCopy] : nil;
    if (!reasons) reasons = [NSMutableDictionary dictionary];
    if (reason.length) reasons[reason] = @([reasons[reason] integerValue] + 1);
    NSInteger count = (same ? [old[@"count"] integerValue] : 0) + 1;
    [ud setObject:@{ @"day": day, @"count": @(count), @"reasons": reasons } forKey:@"tp_filter_today"];
}

+ (void)recordBlockedAds:(NSInteger)count {
    if (count <= 0) return;
    // Ads can be dropped on several queues at once; read and add under one lock so none are lost.
    @synchronized ([TPPrefs class]) {
        NSUserDefaults *ud = [self defaults];
        NSDictionary *old = [ud dictionaryForKey:@"tp_ads_today"];
        NSString *day = TPTodayStamp();
        NSInteger n = ([old[@"day"] isEqualToString:day] ? [old[@"count"] integerValue] : 0) + count;
        [ud setObject:@{ @"day": day, @"count": @(n) } forKey:@"tp_ads_today"];
    }
}

+ (NSInteger)blockedAdsToday {
    NSDictionary *d = [[self defaults] dictionaryForKey:@"tp_ads_today"];
    return [d[@"day"] isEqualToString:TPTodayStamp()] ? [d[@"count"] integerValue] : 0;
}

+ (NSDictionary *)filterStatsToday {
    NSDictionary *d = [[self defaults] dictionaryForKey:@"tp_filter_today"];
    if (![d[@"day"] isEqualToString:TPTodayStamp()]) return @{ @"count": @0 };
    NSString *top = nil; NSInteger best = 0;
    NSDictionary *reasons = d[@"reasons"];
    for (NSString *r in reasons) if ([reasons[r] integerValue] > best) { best = [reasons[r] integerValue]; top = r; }
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:d[@"count"] ?: @0 forKey:@"count"];
    if (top) out[@"top"] = top;
    return out;
}

#pragma mark - Post time format

static NSArray<NSString *> *TPTimePartIDs(void) { return @[@"relative", @"weekday", @"date", @"time"]; }

+ (NSArray<NSDictionary *> *)timeParts {
    NSString *raw = [self stringForKey:TPKeyTimeParts];
    if (!raw.length) raw = @"relative,!weekday,!date,!time";
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *t in [raw componentsSeparatedByString:@","]) {
        BOOL off = [t hasPrefix:@"!"];
        NSString *ident = off ? [t substringFromIndex:1] : t;
        if (![TPTimePartIDs() containsObject:ident] || [seen containsObject:ident]) continue;
        [seen addObject:ident];
        [out addObject:@{ @"id": ident, @"on": @(!off) }];
    }
    for (NSString *ident in TPTimePartIDs()) if (![seen containsObject:ident]) [out addObject:@{ @"id": ident, @"on": @NO }];
    return out;
}

+ (void)setTimeParts:(NSArray<NSDictionary *> *)parts {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSDictionary *p in parts) [tokens addObject:[p[@"on"] boolValue] ? p[@"id"] : [@"!" stringByAppendingString:p[@"id"]]];
    [self setString:parts ? [tokens componentsJoinedByString:@","] : @"" forKey:TPKeyTimeParts];
}

// One formatter per template, in the current language and region.
static NSString *TPFormatDate(NSDate *date, NSString *template) {
    static NSMutableDictionary<NSString *, NSDateFormatter *> *cache;
    static NSLocale *cacheLocale;
    @synchronized ([TPPrefs class]) {
        NSLocale *loc = NSLocale.currentLocale;
        if (!cache || ![cacheLocale.localeIdentifier isEqualToString:loc.localeIdentifier]) {
            cache = [NSMutableDictionary dictionary];
            cacheLocale = loc;
        }
        NSDateFormatter *f = cache[template];
        if (!f) {
            f = [NSDateFormatter new];
            f.locale = loc;
            [f setLocalizedDateFormatFromTemplate:template];
            cache[template] = f;
        }
        return [f stringFromDate:date];
    }
}

+ (NSString *)postTimeForDate:(NSDate *)date relative:(NSString *)relative {
    if (![date isKindOfClass:[NSDate class]]) return nil;
    // Threads can hand back a time text it got from us earlier (it keeps some of them), which
    // would then be taken as the relative part and the date repeated. Every text made here is
    // remembered with the relative text it was made from, so it can be swapped back.
    static NSCache<NSString *, NSString *> *made;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ made = [NSCache new]; made.countLimit = 2000; });
    NSString *source = relative.length ? [made objectForKey:relative] : nil;
    if (source) relative = source.length ? source : nil;
    // Parsed once per change: this runs for every time label while scrolling.
    static NSString *lastRaw;
    static NSArray<NSString *> *lastOn;
    NSString *raw = [self stringForKey:TPKeyTimeParts];
    NSArray<NSString *> *on;
    @synchronized ([TPPrefs class]) {
        if (!lastOn || ![lastRaw isEqualToString:raw]) {
            NSMutableArray *ids = [NSMutableArray array];
            for (NSDictionary *p in [self timeParts]) if ([p[@"on"] boolValue]) [ids addObject:p[@"id"]];
            lastRaw = [raw copy];
            lastOn = ids;
        }
        on = lastOn;
    }
    BOOL custom = NO;
    for (NSString *ident in on) if (![ident isEqualToString:@"relative"]) custom = YES;
    if (!custom) return nil;

    NSInteger yearMode = [self integerForKey:TPKeyTimeYear];
    NSCalendar *cal = NSCalendar.currentCalendar;
    BOOL withYear = yearMode == 2 || (yearMode == 1 && [cal component:NSCalendarUnitYear fromDate:date] != [cal component:NSCalendarUnitYear fromDate:NSDate.date]);
    NSString *dateT = withYear ? @"yMMMd" : @"MMMd";
    NSString *timeT = [self boolForKey:TPKeyTimeSeconds] ? @"HHmmss" : @"HHmm";
    NSString *weekdayT = [self boolForKey:TPKeyTimeWeekdayFull] ? @"EEEE" : @"EEE";
    NSInteger sepIdx = [self integerForKey:TPKeyTimeSeparator];
    NSString *sep = @[@" · ", @" - ", @" | ", @" "][MAX(0, MIN(sepIdx, 3))];

    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < on.count; i++) {
        NSString *ident = on[i];
        NSString *next = i + 1 < on.count ? on[i + 1] : nil;
        NSString *v = nil;
        if ([ident isEqualToString:@"relative"]) v = relative;
        else if ([ident isEqualToString:@"weekday"]) v = TPFormatDate(date, weekdayT);
        else if ([ident isEqualToString:@"date"] && [next isEqualToString:@"time"]) {
            // Date followed by time reads as one, in the region's own order ("27 Nov 15:59").
            v = TPFormatDate(date, [dateT stringByAppendingFormat:@" %@", timeT]);
            i++;
        } else if ([ident isEqualToString:@"time"] && [next isEqualToString:@"date"]) {
            v = [NSString stringWithFormat:@"%@ %@", TPFormatDate(date, timeT), TPFormatDate(date, dateT)];
            i++;
        } else if ([ident isEqualToString:@"date"]) v = TPFormatDate(date, dateT);
        else if ([ident isEqualToString:@"time"]) v = TPFormatDate(date, timeT);
        if (v.length) [out addObject:v];
    }
    if (!out.count) return nil;
    NSString *text = [out componentsJoinedByString:sep];
    [made setObject:(relative ?: @"") forKey:text];
    return text;
}

+ (void)applyExactTimeMode:(NSInteger)mode {
    if (mode <= 0) { [self setString:@"" forKey:TPKeyTimeParts]; return; }
    // 1 date & time · 2 with year · 3 with year and seconds
    [self setString:@"!relative,!weekday,date,time" forKey:TPKeyTimeParts];
    [self setInteger:mode >= 2 ? 2 : 0 forKey:TPKeyTimeYear];
    [self setBool:mode == 3 forKey:TPKeyTimeSeconds];
}

+ (void)migrateExactTime {
    NSUserDefaults *d = [self defaults];
    id old = [d objectForKey:@"tp_exact_time"];
    if (!old) return;
    // 1.30 added "With Year" as option 2; "With Seconds" moved from 2 to 3.
    NSInteger mode = [old integerValue];
    if (mode == 2 && ![d boolForKey:@"tp_time_format_v2"]) mode = 3;
    if ([old isKindOfClass:[NSNumber class]] && ![self stringForKey:TPKeyTimeParts].length) [self applyExactTimeMode:mode];
    [d removeObjectForKey:@"tp_exact_time"];
    [d removeObjectForKey:@"tp_time_format_v2"];
}

@end
