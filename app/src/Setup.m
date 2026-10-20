// ============================================================
// 校园网一键连接 · 首次配置弹窗
//
// 首次点击桌面图标时弹出，收集校园网账号与密码，写入 macOS 钥匙串。
// 密码只在内存里存在几毫秒，直接交给 /usr/bin/security 写入本机钥匙串：
// 不联网、不写文件、不进日志。保存成功后本程序退出，主程序继续联网。
//
// 用 Objective-C + AppKit 实现（不依赖 Swift 工具链，clang 即可编译）。
// ============================================================

#import <Cocoa/Cocoa.h>

// 深大标准色「荔枝红」PANTONE 208C
static NSColor *WineColor(void) {
    return [NSColor colorWithSRGBRed:134.0 / 255.0 green:31.0 / 255.0 blue:65.0 / 255.0 alpha:1.0];
}

static NSColor *WhiteAlpha(CGFloat a) {
    return [NSColor colorWithWhite:1.0 alpha:a];
}

#pragma mark - 无边框窗口（需要能成为 key window）

@interface CardWindow : NSWindow
@end

@implementation CardWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

#pragma mark - 坐标翻转容器（从左上角开始排版）

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

#pragma mark - WiFi 图形（与 app 图标同款：三条弧 + 圆点）

@interface WifiGlyph : NSView
@end

@implementation WifiGlyph

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat h = self.bounds.size.height;
    CGFloat cx = NSMidX(self.bounds);
    CGFloat R = h * 0.72;          // 最外弧半径
    CGFloat cy = h * 0.16;         // 圆心（圆点位置，贴近底部）

    [[NSColor whiteColor] setStroke];
    CGFloat ratios[] = {1.0, 0.653, 0.307};
    for (int i = 0; i < 3; i++) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy)
                                      radius:R * ratios[i]
                                  startAngle:48 endAngle:132
                                   clockwise:NO];
        p.lineWidth = R * 0.15;
        p.lineCapStyle = NSLineCapStyleRound;
        [p stroke];
    }

    CGFloat dot = R * 0.11;
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - dot, cy - dot, dot * 2, dot * 2)] fill];
}

@end

#pragma mark - 控制器

@interface SetupController : NSObject
@property (nonatomic, copy) NSString *service;
@property (nonatomic, strong) CardWindow *window;
@property (nonatomic, strong) NSTextField *acctField;
@property (nonatomic, strong) NSTextField *passField;
@property (nonatomic, strong) NSTextField *errorLabel;
@end

@implementation SetupController

#pragma mark 控件工厂

- (NSTextField *)label:(NSString *)text
                     x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h
                  size:(CGFloat)size weight:(NSFontWeight)weight
                 color:(NSColor *)color alpha:(CGFloat)alpha {
    NSTextField *f = [NSTextField labelWithString:text];
    f.frame = NSMakeRect(x, y, w, h);
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = [color colorWithAlphaComponent:alpha];
    f.lineBreakMode = NSLineBreakByWordWrapping;
    f.maximumNumberOfLines = 0;
    return f;
}

- (NSArray *)fieldAt:(CGFloat)y width:(CGFloat)w placeholder:(NSString *)ph secure:(BOOL)secure {
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(34, y, w, 34)];
    box.wantsLayer = YES;
    box.layer.backgroundColor = WhiteAlpha(0.10).CGColor;
    box.layer.cornerRadius = 8;
    box.layer.borderWidth = 1;
    box.layer.borderColor = WhiteAlpha(0.16).CGColor;

    NSTextField *tf = secure ? [[NSSecureTextField alloc] initWithFrame:NSZeroRect]
                             : [[NSTextField alloc] initWithFrame:NSZeroRect];
    tf.frame = NSMakeRect(11, 7, w - 22, 20);
    tf.bezeled = NO;
    tf.bordered = NO;
    tf.drawsBackground = NO;
    tf.editable = YES;
    tf.selectable = YES;
    tf.textColor = [NSColor whiteColor];
    tf.font = [NSFont systemFontOfSize:13.5];
    tf.focusRingType = NSFocusRingTypeNone;
    tf.placeholderString = ph;
    tf.usesSingleLineMode = YES;
    [box addSubview:tf];

    return @[box, tf];
}

- (NSButton *)button:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w primary:(BOOL)primary {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, w, 34)];
    b.bordered = NO;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 8;
    b.layer.backgroundColor = (primary ? WineColor() : WhiteAlpha(0.10)).CGColor;
    b.attributedTitle = [[NSAttributedString alloc]
        initWithString:title
            attributes:@{NSForegroundColorAttributeName: primary ? [NSColor whiteColor] : WhiteAlpha(0.86),
                         NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]}];
    return b;
}

#pragma mark 组装界面

- (void)build {
    const CGFloat W = 460, H = 380;

    self.window = [[CardWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    self.window.opaque = NO;
    self.window.backgroundColor = [NSColor clearColor];
    self.window.hasShadow = YES;
    self.window.movableByWindowBackground = YES;

    NSVisualEffectView *card = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    card.material = NSVisualEffectMaterialHUDWindow;
    card.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    self.window.contentView = card;

    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    [card addSubview:root];

    [root addSubview:[[WifiGlyph alloc] initWithFrame:NSMakeRect(34, 26, 48, 48)]];

    [root addSubview:[self label:@"连接深圳大学校园网" x:96 y:32 w:330 h:24
                            size:18 weight:NSFontWeightSemibold color:[NSColor whiteColor] alpha:1.0]];
    [root addSubview:[self label:@"首次使用，请保存一次校园网账号。之后点图标即可直接连接。"
                               x:96 y:58 w:330 h:18
                            size:11.5 weight:NSFontWeightRegular color:[NSColor whiteColor] alpha:0.60]];

    [root addSubview:[self label:@"账号（校园卡号）" x:34 y:108 w:300 h:16
                            size:11.5 weight:NSFontWeightMedium color:[NSColor whiteColor] alpha:0.72]];
    NSArray *acct = [self fieldAt:128 width:W - 68 placeholder:@"例如 123456" secure:NO];
    [root addSubview:acct[0]];
    self.acctField = acct[1];

    [root addSubview:[self label:@"密码" x:34 y:176 w:300 h:16
                            size:11.5 weight:NSFontWeightMedium color:[NSColor whiteColor] alpha:0.72]];
    NSArray *pass = [self fieldAt:196 width:W - 68 placeholder:@"统一身份认证密码" secure:YES];
    [root addSubview:pass[0]];
    self.passField = pass[1];

    self.errorLabel = [self label:@"" x:34 y:238 w:W - 68 h:16
                             size:11.5 weight:NSFontWeightMedium
                            color:[NSColor colorWithSRGBRed:1.0 green:0.48 blue:0.48 alpha:1.0] alpha:1.0];
    [root addSubview:self.errorLabel];

    NSButton *primary = [self button:@"保存并开始连接" x:34 y:264 w:178 primary:YES];
    primary.target = self;
    primary.action = @selector(saveTapped);
    primary.keyEquivalent = @"\r";
    [root addSubview:primary];

    NSButton *secondary = [self button:@"稍后再说" x:222 y:264 w:96 primary:NO];
    secondary.target = self;
    secondary.action = @selector(cancelTapped);
    secondary.keyEquivalent = @"\033";   // Esc
    [root addSubview:secondary];

    [root addSubview:[self label:@"密码只保存在本机「钥匙串」，不上传、不写日志、不进项目文件。"
                               x:34 y:318 w:W - 68 h:16
                            size:10.5 weight:NSFontWeightRegular color:[NSColor whiteColor] alpha:0.42]];
    [root addSubview:[self label:@"回车保存 · Esc 取消 · 想换账号就再运行一次本程序"
                               x:34 y:338 w:W - 68 h:16
                            size:10.5 weight:NSFontWeightRegular color:[NSColor whiteColor] alpha:0.30]];

    // 在鼠标所在的那块屏幕上居中（多显示器时 [window center] 会跑到主屏去）
    NSScreen *screen = [NSScreen mainScreen];
    NSPoint mouse = [NSEvent mouseLocation];
    for (NSScreen *s in [NSScreen screens]) {
        if (NSMouseInRect(mouse, s.frame, NO)) { screen = s; break; }
    }
    NSRect vf = screen.visibleFrame;
    [self.window setFrameOrigin:NSMakePoint(NSMidX(vf) - W / 2, NSMidY(vf) - H / 2)];

    self.window.initialFirstResponder = self.acctField;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.acctField];

    if (getenv("SZU_SETUP_PRINT_FRAME")) {   // 开发自测：打印窗口位置，便于截图核对
        NSRect f = self.window.frame;
        fprintf(stderr, "FRAME %d %d %d %d\n", (int)f.origin.x, (int)f.origin.y, (int)f.size.width, (int)f.size.height);
        fflush(stderr);
    }
}

#pragma mark 钥匙串

- (NSString *)runSecurity:(NSArray<NSString *> *)args status:(int *)status {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/security";
    t.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    @try {
        [t launch];
    } @catch (NSException *e) {
        *status = -1;
        return @"无法启动 security 命令";
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    *status = t.terminationStatus;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

- (NSString *)saveKeychainAccount:(NSString *)acct password:(NSString *)pass {
    int st = 0;
    [self runSecurity:@[@"add-generic-password", @"-U", @"-s", self.service, @"-a", acct, @"-w", pass] status:&st];
    if (st != 0) {
        return [NSString stringWithFormat:@"写入钥匙串失败（错误码 %d）", st];
    }
    int vst = 0;
    [self runSecurity:@[@"find-generic-password", @"-s", self.service, @"-w"] status:&vst];
    if (vst != 0) return @"写入后校验失败，请重试";
    return nil;
}

#pragma mark 动作

- (void)saveTapped {
    NSString *acct = [self.acctField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *pass = self.passField.stringValue;

    if (acct.length == 0) {
        self.errorLabel.stringValue = @"请填写校园网账号";
        [self.window makeFirstResponder:self.acctField];
        return;
    }
    if (pass.length == 0) {
        self.errorLabel.stringValue = @"请填写密码";
        [self.window makeFirstResponder:self.passField];
        return;
    }

    NSString *err = [self saveKeychainAccount:acct password:pass];
    if (err) {
        self.errorLabel.stringValue = [NSString stringWithFormat:@"保存失败：%@", err];
        return;
    }
    self.passField.stringValue = @"";
    [NSApp terminate:nil];
}

- (void)cancelTapped {
    self.passField.stringValue = @"";
    [NSApp terminate:nil];
}

@end

#pragma mark - 菜单（保证 ⌘V 粘贴可用）

static void BuildMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    editItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];

    [NSApp setMainMenu:mainMenu];
}

#pragma mark - 入口

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *service = @"szu-portal";
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--service") == 0) {
                service = [NSString stringWithUTF8String:argv[i + 1]];  // 开发自测用
            }
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        BuildMenu();

        static SetupController *controller;   // 控件 target 是弱引用，这里必须持有
        controller = [[SetupController alloc] init];
        controller.service = service;
        [controller build];

        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
