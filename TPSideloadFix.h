#import <Foundation/Foundation.h>

void TPSideloadFixInstall(void);
void TPRebindSymbols(const char **names, void **replacements, size_t count);
NSString *TPSideloadFixStatus(void);
NSString *TPSideloadFixStats(void);
