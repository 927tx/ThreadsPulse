#import "TPAuthorStatsViewController.h"
#import "TPAuthorInfo.h"
#import "TPLocalization.h"
#import "TPUI.h"

static NSString *const kHiddenGroup = @"␟hidden";

#pragma mark - Country row

@interface TPStatsBarCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic) CGFloat fraction;
@end

@implementation TPStatsBarCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = [TPUI cardColor];
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont systemFontOfSize:16];
        _countLabel = [UILabel new];
        _countLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _countLabel.textColor = [TPUI accent];
        _countLabel.textAlignment = NSTextAlignmentRight;
        _track = [UIView new];
        _track.backgroundColor = UIColor.tertiarySystemFillColor;
        _track.layer.cornerRadius = 2;
        _bar = [UIView new];
        _bar.backgroundColor = [TPUI accent];
        _bar.layer.cornerRadius = 2;
        [_track addSubview:_bar];
        for (UIView *v in @[_nameLabel, _countLabel, _track]) [self.contentView addSubview:v];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat x = self.layoutMargins.left, w = b.size.width - x - 8;
    _countLabel.frame = CGRectMake(b.size.width - 8 - 60, 10, 60, 22);
    _nameLabel.frame = CGRectMake(x, 10, w - 64, 22);
    _track.frame = CGRectMake(x, 38, w, 4);
    _bar.frame = CGRectMake(0, 0, MAX(4, w * _fraction), 4);
}
@end

#pragma mark - Authors of one country

@interface TPAuthorListViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@end

@implementation TPAuthorListViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [TPUI pageColor];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.entries.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return TPL(@"Tap an author to open their profile.");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"a"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
    NSDictionary *e = self.entries[ip.row];
    NSString *u = e[@"u"], *n = e[@"n"];
    c.backgroundColor = [TPUI cardColor];
    c.textLabel.text = u.length ? (n.length ? [NSString stringWithFormat:@"%@  @%@", n, u] : [@"@" stringByAppendingString:u])
                                : [NSString stringWithFormat:@"%@ %@", TPL(@"User ID"), e[@"pk"]];
    NSMutableArray *bits = [NSMutableArray array];
    if ([e[@"joined"] length]) [bits addObject:e[@"joined"]];
    if ([e[@"number"] length]) [bits addObject:e[@"number"]];
    if ([TPAuthorInfo isNewAccount:e[@"joined"]]) [bits insertObject:TPL(@"NEW") atIndex:0];
    c.detailTextLabel.text = [bits componentsJoinedByString:@" · "];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = u.length ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    c.selectionStyle = u.length ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *u = self.entries[ip.row][@"u"];
    if (!u.length || !TPAuthorOpenProfile) return;
    UIViewController *root = self.navigationController.presentingViewController ? self.navigationController : self;
    [root dismissViewControllerAnimated:YES completion:^{ TPAuthorOpenProfile(u); }];
}
@end

#pragma mark - Countries

@implementation TPAuthorStatsViewController {
    NSArray<NSString *> *_groups;                         // country names, hidden group last
    NSDictionary<NSString *, NSArray *> *_byGroup;
    NSUInteger _total, _maxCount;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TPL(@"Location Stats");
    self.tableView.backgroundColor = [TPUI pageColor];
    self.tableView.rowHeight = 52;
    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:TPAuthorInfoDidUpdateNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)reload {
    NSMutableDictionary<NSString *, NSMutableArray *> *g = [NSMutableDictionary dictionary];
    NSArray *entries = [TPAuthorInfo allEntries];
    for (NSDictionary *e in entries) {
        // Authors without a country (hidden, or Threads gave none) go under "Not shared", so the total
        // matches the authors counted in Read Status & Cache.
        NSString *key = [e[@"location"] length] ? e[@"location"] : kHiddenGroup;
        if (!g[key]) g[key] = [NSMutableArray array];
        [g[key] addObject:e];
    }
    for (NSMutableArray *list in g.allValues) {
        [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [(a[@"u"] ?: a[@"pk"]) caseInsensitiveCompare:(b[@"u"] ?: b[@"pk"])];
        }];
    }
    NSMutableArray *countries = [[g.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != %@", kHiddenGroup]] mutableCopy];
    [countries sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger ca = g[a].count, cb = g[b].count;
        if (ca != cb) return ca > cb ? NSOrderedAscending : NSOrderedDescending;
        return [a localizedCompare:b];
    }];
    if (g[kHiddenGroup]) [countries addObject:kHiddenGroup];
    _groups = countries;
    _byGroup = g;
    _total = 0; _maxCount = 1;
    for (NSString *k in g) { _total += g[k].count; _maxCount = MAX(_maxCount, g[k].count); }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX(_groups.count, 1); }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (!_groups.count) return nil;
    NSUInteger countries = _groups.count - (_byGroup[kHiddenGroup] ? 1 : 0);
    return [NSString stringWithFormat:TPL(@"%lu authors · %lu countries or regions"), (unsigned long)_total, (unsigned long)countries];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return TPL(@"Counts the authors currently cached (kept for up to 21 days).");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (!_groups.count) {
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"empty"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        c.backgroundColor = [TPUI cardColor];
        c.textLabel.text = TPL(@"No author info yet. Browse the feed and it will appear here.");
        c.textLabel.numberOfLines = 0;
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    TPStatsBarCell *c = [tv dequeueReusableCellWithIdentifier:@"bar"] ?: [[TPStatsBarCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"bar"];
    NSString *key = _groups[ip.row];
    NSUInteger n = _byGroup[key].count;
    BOOL hidden = [key isEqualToString:kHiddenGroup];
    NSString *flag = hidden ? @"🌐" : ([TPAuthorInfo flagForCountry:key] ?: @"📍");
    c.nameLabel.text = [NSString stringWithFormat:@"%@  %@", flag, hidden ? TPL(@"Not shared") : key];
    c.nameLabel.textColor = hidden ? UIColor.secondaryLabelColor : UIColor.labelColor;
    c.countLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)n];
    c.bar.backgroundColor = hidden ? UIColor.systemGrayColor : [TPUI accent];
    c.countLabel.textColor = hidden ? UIColor.secondaryLabelColor : [TPUI accent];
    c.fraction = (CGFloat)n / _maxCount;
    [c setNeedsLayout];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_groups.count) return;
    NSString *key = _groups[ip.row];
    TPAuthorListViewController *list = [[TPAuthorListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    list.entries = _byGroup[key];
    list.title = [key isEqualToString:kHiddenGroup] ? TPL(@"Not shared") : key;
    [self.navigationController pushViewController:list animated:YES];
}
@end
