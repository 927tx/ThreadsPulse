#import <UIKit/UIKit.h>

// Download history, kept between launches. One record per download (a post, a video or a
// profile picture); each item keeps the links it was downloaded from so failed items can be
// retried. With "Keep Copies" on, saved files are also kept in ThreadsPulse's own folder.
extern NSString *const TPDownloadStoreDidChangeNotification;
// Posted by the running download about twice a second. userInfo: record, progress (0–1), speed.
extern NSString *const TPDownloadProgressNotification;

// Set by the tweak: opens a post in Threads (author may be nil).
extern void (^TPDownloadOpenPost)(NSString *code, NSString *author);

@interface TPDownloadStore : NSObject
// Creates a record for a download being queued. context: code, author, kind (@"post", @"avatar").
// Returns the items with @"tp_record" / @"tp_index" added.
+ (NSArray<NSDictionary *> *)addRecordForItems:(NSArray<NSDictionary *> *)items context:(NSDictionary *)context;
// Re-queues items of an existing record (retry). Returns nil if nothing is left to download.
+ (NSArray<NSDictionary *> *)retryItemsForRecord:(NSString *)rid failedOnly:(BOOL)failedOnly;

+ (void)setRecord:(NSString *)rid status:(NSInteger)status;   // 0 queued, 1 downloading, 2 finished, 4 cancelled
+ (void)setRecord:(NSString *)rid item:(NSInteger)index saved:(BOOL)saved;
// A file about to be saved to Photos: makes the thumbnail and, with Keep Copies on, keeps a copy.
+ (void)keepFile:(NSURL *)file record:(NSString *)rid item:(NSInteger)index;
+ (void)keepData:(NSData *)data extension:(NSString *)ext record:(NSString *)rid item:(NSInteger)index;
+ (void)removeRecord:(NSString *)rid;

+ (NSArray<NSDictionary *> *)records;              // newest first
+ (NSDictionary *)recordWithID:(NSString *)rid;
// The newest post download of this code that is queued, running or saved at least one item.
+ (NSDictionary *)existingRecordForCode:(NSString *)code;
+ (NSInteger)failedRecordCount;                   // downloads with at least one failed item
+ (NSArray<NSDictionary *> *)libraryFiles;         // @{ path, record, item, video, date }
+ (unsigned long long)libraryBytes;
+ (void)deleteLibraryFile:(NSString *)path;
+ (void)deleteAllLibraryFiles;
+ (void)clearHistory;
+ (UIImage *)thumbnailForRecord:(NSDictionary *)record item:(NSInteger)index;
@end

@interface TPDownloadManagerViewController : UITableViewController
+ (void)present;
@end
