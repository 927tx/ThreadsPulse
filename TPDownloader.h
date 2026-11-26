#import <UIKit/UIKit.h>

@interface TPDownloader : NSObject
+ (NSURL *)bestURLFromObject:(id)videoObject;
+ (NSURL *)bestURLFromVideoView:(UIView *)view player:(id)playerHint;
+ (NSString *)debugReportForVideoView:(UIView *)view player:(id)playerHint;
+ (void)showReport:(NSString *)text;

+ (void)downloadItems:(NSArray<NSDictionary *> *)items;
// context: code, author, kind (@"post" / @"avatar") for the download history; retry, quiet.
+ (void)downloadItems:(NSArray<NSDictionary *> *)items context:(NSDictionary *)context;

// Download manager: the queue and the running download.
+ (BOOL)queuePaused;
+ (void)setQueuePaused:(BOOL)paused;
+ (NSString *)activeRecordID;
+ (NSArray<NSString *> *)activeRecordIDs;   // more than one while a video converts and the next post downloads
+ (NSArray<NSString *> *)queuedRecordIDs;
+ (void)removeQueuedRecord:(NSString *)recordID;
+ (void)moveQueuedRecordFrom:(NSInteger)from to:(NSInteger)to;
+ (void)cancelRecord:(NSString *)recordID;
+ (void)downloadVideoURL:(NSURL *)url;
+ (void)downloadVideoURL:(NSURL *)url dash:(NSDictionary *)dash;
+ (void)downloadVideoURL:(NSURL *)url dash:(NSDictionary *)dash context:(NSDictionary *)context;

// High-quality DASH streams (separate video + audio). Returns nil when the setting is off, no
// manifest is found, or the DASH video isn't larger than the progressive MP4.
// Keys: dashVideo (NSURL), dashAudio (NSURL, optional), dashLabel (NSString, e.g. "1080p").
+ (NSDictionary *)dashInfoFromObject:(id)obj;
+ (NSDictionary *)dashInfoFromVideoView:(UIView *)view player:(id)playerHint;

+ (NSURL *)bestVideoURLHarvestedFromObject:(id)obj;
+ (NSURL *)bestImageURLHarvestedFromObject:(id)obj;
+ (NSURL *)bestVideoURLNearView:(UIView *)view;

+ (double)imageAreaFromURL:(NSURL *)url;
+ (void)appendPendingReport:(NSString *)report;
+ (id)safeValue:(id)obj key:(NSString *)key;
+ (id)ivarValue:(id)obj name:(NSString *)name;
+ (void)toast:(NSString *)text;
+ (UIViewController *)topViewController;

// File names for saved media ("Name Files From Post"). Parts: author, country, date, time, code,
// index, threads. Returns every part in the user's order with whether it is on.
+ (NSArray<NSDictionary *> *)fileNameParts;            // @{ id, on }
+ (void)setFileNameParts:(NSArray<NSDictionary *> *)parts;
+ (NSString *)fileNameWithAuthor:(NSString *)author country:(NSString *)country date:(NSDate *)date
                            code:(NSString *)code index:(NSInteger)index count:(NSInteger)count
                           label:(NSString *)label extension:(NSString *)ext;   // label: @"avatar", @"cover" or nil
@end
