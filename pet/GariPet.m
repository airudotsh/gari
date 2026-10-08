// GariPet v0.3 — Gari's body. A pixel pet that lives on screen (alive + interactive).
// Principle: the mood shows only real state (sleeping = actually idle). Idle animations are decoration but never lie about state.
// Separate from the engine: if this app dies, Gari (collection, distillation, reports) keeps running.
// Build: clang -fobjc-arc -framework Cocoa -O2 -o gari-pet GariPet.m
// Self-snapshot: ./gari-pet --snapshot <output-folder>   (renders a PNG per mood, then exits — for visual checks)
#import <Cocoa/Cocoa.h>
#import <sys/file.h>

#define CELL 5.0
#define BCOLS 13
#define BROWS 10
#define TICK 0.12

typedef NS_ENUM(int, GariMood) { MoodSleep, MoodAwake, MoodWork, MoodAlert };

// ---------------------------------------------------------------- body (layer 1: hand-dotted sheet)
// Gari = a Garibaldi fish. Reference dot grammar: 3-tone shading + dorsal fin + forked tail + pectoral fin.
// D = deep orange (back/fin shade) B = body orange (vivid) H = belly/cheek (peach). The eyes are drawn in code (blinking, gaze).
// Sprite: "Cute Fish Sprites" by chips8688 — https://opengameart.org/content/cute-fish-sprites
// License OGA-BY 3.0 (attribution). One orange-variant idle frame ported to the grid (eyes replaced by code animation).
static NSString *BODY[BROWS] = {
    @"......AA.....",
    @"..AAAABBA....",
    @".ABBBCABA..AA",
    @"ABBBBBCAA.ACA",
    @"ABBBBBDCBACCA",
    @"ABBBBBDBBCBA.",
    @"ABBBBDDBBABBA",
    @".AAAAAAAA.AAA",
    @".....ACBA....",
    @"......AAA....",
};

static NSColor *gBodyColor, *gShadeColor, *gBellyColor;   // palette (replaceable via pet-config.json)

static NSColor *hexColor(NSString *hex, NSColor *fallback) {
    if (![hex isKindOfClass:NSString.class]) return fallback;
    NSString *h = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (h.length != 6) return fallback;
    unsigned v = 0;
    [[NSScanner scannerWithString:h] scanHexInt:&v];
    return [NSColor colorWithCalibratedRed:((v >> 16) & 0xFF) / 255.0
                                     green:((v >> 8) & 0xFF) / 255.0
                                      blue:(v & 0xFF) / 255.0 alpha:1];
}

static void initPalette(NSDictionary *cfg) {
    NSColor *fallback = [NSColor colorWithCalibratedRed:1.000 green:0.400 blue:0.000 alpha:1]; // Garibaldi orange
    gBodyColor = hexColor(cfg[@"body_color"], fallback);
    // shade and belly are derived from the body color (Garibaldi ratios: saturation -14%/-22%, hue +5°/+9°)
    NSColor *hsb = [gBodyColor colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
    CGFloat h, s, b, a;
    [hsb getHue:&h saturation:&s brightness:&b alpha:&a];
    gShadeColor = hexColor(cfg[@"shade_color"],
        [NSColor colorWithCalibratedHue:fmin(1, h + 5.0 / 360) saturation:s * 0.86
                             brightness:fmin(1, b * 1.02) alpha:1]);
    gBellyColor = hexColor(cfg[@"belly_color"],
        [NSColor colorWithCalibratedHue:fmin(1, h + 9.0 / 360) saturation:s * 0.78
                             brightness:fmin(1, b * 1.05) alpha:1]);
}

static NSColor *fishCellColor(int c, int y) {
    if (y < 0 || y >= BROWS || c < 0 || c >= BCOLS) return nil;
    unichar ch = [BODY[y] characterAtIndex:c];
    switch (ch) {
        case 'A': case 'B': case 'E': return gBodyColor;   // body
        case 'C': return gShadeColor;                       // shade
        case 'D': return gBellyColor;                       // light belly
        default:  return nil;
    }
}

// Official Codex Pets atlas spec — when a skin is equipped
#define SHEET_COLS 8
#define SHEET_CELL_W 192.0
#define SHEET_CELL_H 208.0
static int sheetRowFor(GariMood m) {
    switch (m) { case MoodWork: return 7; case MoodAwake: return 8;
                 case MoodAlert: return 5; default: return 0; }
}

// ---------------------------------------------------------------- state reading (Gari's real state)

@interface GariStateReader : NSObject
+ (NSString *)gariPath:(NSString *)rel;
+ (void)read:(GariMood *)mood badge:(int *)badge;
@end

@implementation GariStateReader
+ (NSString *)gariPath:(NSString *)rel {
    NSString *home = NSProcessInfo.processInfo.environment[@"GARI_HOME"];
    if (home.length == 0) home = [NSHomeDirectory() stringByAppendingPathComponent:@"gari"];
    return [home stringByAppendingPathComponent:rel];
}
+ (void)read:(GariMood *)mood badge:(int *)badge {
    NSFileManager *fm = NSFileManager.defaultManager;
    *mood = MoodSleep; *badge = 0;
    BOOL stale = YES;
    NSData *hd = [NSData dataWithContentsOfFile:[self gariPath:@"store/health.json"]];
    if (hd) {
        NSDictionary *h = [NSJSONSerialization JSONObjectWithData:hd options:0 error:nil];
        NSString *last = h[@"last_sweep"];
        if ([last isKindOfClass:NSString.class]) {
            NSDate *d = [[NSISO8601DateFormatter new] dateFromString:last];
            if (d && [NSDate.date timeIntervalSinceDate:d] < 30 * 60) stale = NO;
        }
    }
    NSData *pd = [NSData dataWithContentsOfFile:[self gariPath:@"pending-approvals.json"]];
    if (pd) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil];
        if ([arr isKindOfClass:NSArray.class]) *badge += (int)arr.count;
    }
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd";
    NSString *today = [df stringFromDate:NSDate.date];
    if ([fm fileExistsAtPath:[self gariPath:[NSString stringWithFormat:@"reports/%@.md", today]]]
        && ![fm fileExistsAtPath:[self gariPath:[NSString stringWithFormat:@"pet/seen-%@", today]]])
        *badge += 1;
    if (stale) *mood = MoodAlert;
    else if ([fm fileExistsAtPath:[self gariPath:@"store/sweep.lock"]]) *mood = MoodWork;
    else if (*badge > 0) *mood = MoodAwake;
}
@end

// ---------------------------------------------------------------- heart particles

@interface Heart : NSObject
@property CGFloat x, y, vy, life;
@end
@implementation Heart @end

@interface AmbientBubble : NSObject
@property CGFloat x, y, vy, life, size, wobble;
@end
@implementation AmbientBubble @end

// A borderless panel needs this to receive keyboard input. ESC = close (popover standard).
@interface KeyableWindow : NSWindow
@end
@implementation KeyableWindow
// Restore standard editing shortcuts for an app without a menu bar — ⌘C/V/X/A/Z flow to the first responder
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if (e.modifierFlags & NSEventModifierFlagCommand) {
        // Decide by physical key code — on non-Latin keyboard layouts, ⌘V's charactersIgnoringModifiers
        // arrives as a different character instead of "v", so character comparison misses entirely (passes only on Latin layouts)
        SEL sel = NULL;
        switch (e.keyCode) {
            case 8: sel = @selector(copy:); break;       // C
            case 9: sel = @selector(paste:); break;      // V
            case 7: sel = @selector(cut:); break;        // X
            case 0: sel = @selector(selectAll:); break;  // A
            case 6: sel = (e.modifierFlags & NSEventModifierFlagShift)
                        ? NSSelectorFromString(@"redo:")
                        : NSSelectorFromString(@"undo:"); break;  // Z
        }
        if (sel && [NSApp sendAction:sel to:nil from:self]) return YES;
    }
    return [super performKeyEquivalent:e];
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender { [self orderOut:nil]; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) { [self orderOut:nil]; return; }  // ESC
    [super keyDown:event];
}
@end

// Container that stacks top → bottom (for manual layout)
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// ---- panel UI helpers (labels, row cards) ----

static NSAttributedString *mdRender(NSString *text, CGFloat size, NSColor *color) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSFont *base = [NSFont systemFontOfSize:size];
    NSFont *bold = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    NSFont *head = [NSFont systemFontOfSize:size + 1.5 weight:NSFontWeightBold];
    NSFont *mono = [NSFont monospacedSystemFontOfSize:size - 1 weight:NSFontWeightRegular];
    NSColor *codeBg = [NSColor colorWithCalibratedWhite:0 alpha:0.30];
    NSColor *accent = [NSColor colorWithCalibratedRed:1.00 green:0.58 blue:0.22 alpha:1];
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineSpacing = 5.5;               // effective line height ~1.55 for long text (following ChatGPT/Claude practice)
    para.paragraphSpacing = 9;            // breathing room between paragraphs (blank lines become this spacing, not boxes)
    NSMutableParagraphStyle *headPara = [para mutableCopy];
    headPara.paragraphSpacingBefore = 13; // headings: far from what's above
    headPara.paragraphSpacing = 5;        // close to the body below (proximity)
    NSMutableParagraphStyle *bulletPara = [para mutableCopy];
    bulletPara.headIndent = 14;           // hanging indent (wrapped lines don't slip under the bullet)
    bulletPara.paragraphSpacing = 5;      // list items tighter (narrower than the paragraph 9)
    NSMutableParagraphStyle *quipPara = [para mutableCopy];
    quipPara.paragraphSpacingBefore = 10; // the nudge line gets its own breathing room from the body
    BOOL inCode = NO;
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger li = 0; li < lines.count; li++) {
        NSString *line = lines[li];
        if ([line hasPrefix:@"```"]) { inCode = !inCode; continue; }   // fence lines are not shown
        if (!inCode && ![[line stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet] length]) continue;   // no boxes for blank lines
        NSFont *lineFont = base;
        NSParagraphStyle *linePara = para;
        NSColor *lineColor = color;
        if (inCode) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:line
                attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: color,
                             NSBackgroundColorAttributeName: codeBg,
                             NSParagraphStyleAttributeName: para}]];
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                attributes:@{NSFontAttributeName: mono, NSParagraphStyleAttributeName: para}]];
            continue;
        }
        if ([line hasPrefix:@"### "]) { line = [line substringFromIndex:4]; lineFont = bold; linePara = headPara; }
        else if ([line hasPrefix:@"## "]) { line = [line substringFromIndex:3]; lineFont = head; linePara = headPara; }
        else if ([line hasPrefix:@"# "]) { line = [line substringFromIndex:2]; lineFont = head; linePara = headPara; }
        if ([line hasPrefix:@"- "]) {
            line = [line substringFromIndex:2];
            if (linePara == para || linePara == quipPara) linePara = bulletPara;
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"•  "
                attributes:@{NSFontAttributeName: base,
                             NSForegroundColorAttributeName: [lineColor colorWithAlphaComponent:0.45],
                             NSParagraphStyleAttributeName: bulletPara}]];
        }
        if ([line rangeOfString:@"«nudge" options:NSCaseInsensitiveSearch].location != NSNotFound || [line hasPrefix:@"Nudge —"] || [line containsString:@"«참견"] || [line hasPrefix:@"참견 —"]) {
            lineColor = accent;                       // color + spacing is the nudge marker — no label needed
            linePara = quipPara;
            NSRange r = [line rangeOfString:@"nudge" options:NSCaseInsensitiveSearch]; if (r.location == NSNotFound) r = [line rangeOfString:@"참견"];
            line = [line substringFromIndex:NSMaxRange(r)];
            line = [line stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@" —–-:«»"]];
        }
        NSArray *codeParts = [line componentsSeparatedByString:@"`"];
        for (NSUInteger ci = 0; ci < codeParts.count; ci++) {
            if (![codeParts[ci] length]) continue;
            if (ci % 2 == 1) {   // `inline code` — no background fill (bleeds across wraps), mono + brightness only
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:codeParts[ci]
                    attributes:@{NSFontAttributeName: mono,
                                 NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.99],
                                 NSParagraphStyleAttributeName: linePara}]];
                continue;
            }
            NSArray *parts = [codeParts[ci] componentsSeparatedByString:@"**"];
            for (NSUInteger i = 0; i < parts.count; i++) {
                if (![parts[i] length]) continue;
                [out appendAttributedString:[[NSAttributedString alloc] initWithString:parts[i]
                    attributes:@{NSFontAttributeName: (i % 2 == 1) ? bold : lineFont,
                                 NSForegroundColorAttributeName: lineColor,
                                 NSParagraphStyleAttributeName: linePara}]];
            }
        }
        if (li + 1 < lines.count)
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                attributes:@{NSFontAttributeName: base, NSParagraphStyleAttributeName: para,
                             NSForegroundColorAttributeName: color}]];
    }
    NSDataDetector *det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    [det enumerateMatchesInString:out.string options:0 range:NSMakeRange(0, out.length)
        usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags fl, BOOL *stop) {
        if (m.URL)
            [out addAttributes:@{NSLinkAttributeName: m.URL,
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:0.62 blue:0.30 alpha:1],
                NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)} range:m.range];
    }];
    return out;
}

static NSButton *flatBtn(NSString *title, NSColor *tint, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bordered = NO;
    b.wantsLayer = YES;
    b.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.06].CGColor;
    b.layer.borderColor = [NSColor colorWithCalibratedWhite:1 alpha:0.14].CGColor;
    b.layer.borderWidth = 1;
    b.layer.cornerRadius = 6;
    b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    b.contentTintColor = tint;
    return b;
}

static NSTextField *hudLabel(NSString *text, NSFont *font, NSColor *color,
                             NSInteger maxLines, CGFloat width) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text ?: @""];
    l.font = font;
    l.textColor = color;
    l.selectable = NO;
    l.maximumNumberOfLines = maxLines;
    l.cell.truncatesLastVisibleLine = (maxLines > 0);   // unlimited labels never truncate
    l.preferredMaxLayoutWidth = width;
    l.frame = NSMakeRect(0, 0, width, 10);
    CGFloat h = ceil([l.cell cellSizeForBounds:NSMakeRect(0, 0, width, 20000)].height);  // measured from the cell
    CGFloat lineH = ceil(font.ascender - font.descender + font.leading) + 2;
    if (maxLines > 0) h = MIN(h, lineH * maxLines);
    l.frame = NSMakeRect(0, 0, width, h + 2);
    return l;
}

static NSView *hudRowCard(CGFloat width) {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 10)];
    row.wantsLayer = YES;
    row.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.055].CGColor;
    row.layer.cornerRadius = 10;
    return row;
}

// ---------------------------------------------------------------- pet view

@class ResizeGrip;

@interface PetView : NSView
@property GariMood mood;
@property int badge;
@property long tick;
@property (strong) NSImage *sheet;
@property (strong) NSDate *moodChangedAt;
@property (strong) NSDate *happyUntil;      // petting reaction window (expression)
@property (strong) NSString *bubbleOverride;
@property (strong) NSDate *bubbleUntil;     // speech bubble expiry (separate from expression)
@property (strong) NSString *lastBubbleLine; // avoid repeating the same line
@property (strong) NSMutableArray<Heart *> *hearts;
@property (strong) NSMutableArray<AmbientBubble *> *ambient;
@property int bubbleCountdown;
// aliveness engine
@property CGFloat breathPhase;
@property int blinkCountdown, blinkFrames;
@property CGFloat hopY, hopV;
@property NSPoint lookVec;                  // pupil direction (-1..1)
@property BOOL mouseInside;
@property int glanceCountdown;
@property NSPoint dragOffset;
@property BOOL dragged;
@property BOOL mouseIsDown;      // no click-through toggling while dragging
@property BOOL cursorPushed;
@property NSPoint lookTarget;    // glance target (lookVec interpolates toward it)
@property (strong) NSWindow *hudWindow;     // dashboard — toggled by click
@property (strong) NSScrollView *hudScroll; // content (JSON → native rows)
@property (strong) NSTextView *hudInput;    // question box at the bottom of the panel (grows to multiple lines)
@property (strong) NSScrollView *hudInputScroll;
@property (strong) NSTextField *hudPlaceholder;
@property (strong) NSTextField *headerSub;  // header status line
@property (strong) NSTextField *headerTime;
@property (strong) NSView *headerDot;       // pipeline status dot
@property (strong) NSDictionary *hudData;   // gari hud --json
@property int hudMode;                       // 0 = dashboard, 1 = chat
@property BOOL showAllPendings;              // inbox "others" expanded
@property BOOL showRecords;                  // today's log expanded
@property BOOL showSuggestions;              // Gari's tidy-up suggestions expanded
@property BOOL showWorkItems;                // work-type pendings expanded
@property BOOL showDetail;                   // details under the stakes (the older full view) expanded
@property int wiggleFrames;                  // wiggle frames left
@property int glideFrames;                   // glide frames left
@property CGFloat rubAccum;                  // rubbing gauge
@property NSInteger lastThreadCount;         // for deciding fade-in
@property (strong) NSButton *tabA, *tabB;
@property (strong) NSView *tabLine;
@property (strong) NSPopUpButton *chatPopup;
@property (strong) NSArray *chatSessionIds;
@property (strong) NSArray *chatSessionTitles;
@property (strong) NSString *chatCurrentSid;
@property (strong) NSTimer *askTimer;
@property (strong) NSString *lastAskStatus;
@property (strong) ResizeGrip *hudGrip;
@property (strong) NSString *lastQ, *lastA; // last Q&A
@property BOOL asking;
@end

@interface ChatInputView : NSTextView
@end

@implementation ChatInputView
- (void)paste:(id)sender {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSImage *img = nil;
    // file copies (Finder) first, then screenshot-style bitmaps
    NSArray *urls = [pb readObjectsForClasses:@[NSURL.class]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *u in urls) {
        NSString *ext = u.pathExtension.lowercaseString;
        if ([@[@"png", @"jpg", @"jpeg", @"gif", @"webp"] containsObject:ext]) {
            [self insertText:[NSString stringWithFormat:@"[ATTACH: %@] ", u.path]
            replacementRange:self.selectedRange];
            return;
        }
    }
    if ([pb canReadObjectForClasses:@[NSImage.class] options:@{}])
        img = [[NSImage alloc] initWithPasteboard:pb];
    if (img) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *path = [GariStateReader gariPath:
            [NSString stringWithFormat:@"store/attach/%@.png", [df stringFromDate:NSDate.date]]];
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        if ([png writeToFile:path atomically:YES]) {
            [self insertText:[NSString stringWithFormat:@"[ATTACH: %@] ", path]
            replacementRange:self.selectedRange];
            return;
        }
    }
    [super paste:sender];
}
@end

@interface ResizeGrip : NSView
@property (weak) NSWindow *win;
@property (copy) void (^onResizeEnd)(void);
@property NSRect startFrame;
@property NSPoint startMouse;
@end

@implementation ResizeGrip
- (void)drawRect:(NSRect)r {
    NSBezierPath *ln = [NSBezierPath bezierPath];
    ln.lineWidth = 1.2;
    CGFloat W = self.bounds.size.width, m = 3;
    for (int i = 0; i < 3; i++) {   // 3 diagonal lines at bottom-right — the standard resize grip
        CGFloat off = 3 + i * 3.5;
        [ln moveToPoint:NSMakePoint(W - m - off, m)];
        [ln lineToPoint:NSMakePoint(W - m, m + off)];
    }
    [[NSColor colorWithCalibratedWhite:1 alpha:0.22] setStroke];
    [ln stroke];
}
- (void)resetCursorRects {
    if (@available(macOS 15.0, *)) {
        [self addCursorRect:self.bounds cursor:
            [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionBottomRight
                                       inDirections:NSCursorFrameResizeDirectionsAll]];
    } else {
        [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
    }
}
- (void)mouseDown:(NSEvent *)e {
    self.startFrame = self.win.frame;
    self.startMouse = NSEvent.mouseLocation;
}
- (void)mouseDragged:(NSEvent *)e {
    NSPoint cur = NSEvent.mouseLocation;
    CGFloat dw = cur.x - self.startMouse.x;
    CGFloat dh = self.startMouse.y - cur.y;   // dragging down makes it bigger
    NSRect f = self.startFrame;
    CGFloat w = MAX(380, MIN(1000, f.size.width + dw));
    CGFloat h = MAX(430, MIN(NSScreen.mainScreen.visibleFrame.size.height, f.size.height + dh));
    [self.win setFrame:NSMakeRect(f.origin.x, f.origin.y + (f.size.height - h), w, h)
               display:YES];
}
- (void)mouseUp:(NSEvent *)e {
    if (self.onResizeEnd) self.onResizeEnd();
}
@end


@implementation PetView

- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    self.hearts = [NSMutableArray array];
    self.ambient = [NSMutableArray array];
    self.bubbleCountdown = 30;
    self.blinkCountdown = 30;
    self.glanceCountdown = 40;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil]];
    return self;
}

- (BOOL)isHappy { return self.happyUntil && [self.happyUntil timeIntervalSinceNow] > 0; }

// Is the point on the fish's body? (generous hit area — body ellipse + tail, 6px slack)
- (BOOL)pointOverFish:(NSPoint)viewPt {
    CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2;
    CGFloat oyBase = 16;
    int c = (int)floor((viewPt.x - ox) / CELL);
    int rBottom = (int)floor((viewPt.y - oyBase) / CELL);
    int y = BROWS - 1 - rBottom;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            if (fishCellColor(c + dx, y + dy)) return YES;   // 1-cell slack
    return NO;
}

// Click-through: the window takes the mouse only when the cursor is over the fish (cheap check every tick)
- (void)updateClickThrough {
    if (self.mouseIsDown) return;   // keep while dragging
    NSPoint mouse = [NSEvent mouseLocation];
    NSRect wf = self.window.frame;
    BOOL over = NO;
    if (NSPointInRect(mouse, wf))
        over = [self pointOverFish:NSMakePoint(mouse.x - wf.origin.x,
                                               mouse.y - wf.origin.y)];
    self.window.ignoresMouseEvents = !over;
    if (over && !self.cursorPushed) { [NSCursor.pointingHandCursor push]; self.cursorPushed = YES; }
    else if (!over && self.cursorPushed) { [NSCursor pop]; self.cursorPushed = NO; }
}

// Next tick interval — slow when inactive (avoids RunCat-style constant high-frequency wakeups)
- (NSTimeInterval)desiredTickInterval {
    if (!self.window.isVisible) return 2.0;                      // hidden
    BOOL active = (self.mood != MoodSleep) || self.hearts.count > 0
                  || self.ambient.count > 0
                  || self.hopY > 0 || self.bubbleOverride != nil
                  || self.mouseInside;
    return active ? 0.12 : 0.45;                                 // 2fps is enough for breathing while asleep
}

// ---------------- aliveness tick (adaptive)
- (void)animTick {
    self.tick += 1;
    [self updateClickThrough];
    self.breathPhase += 0.14;
    // Blink (not while asleep) — one frame only, spaced generously: avoids the "eyes vanish and come back" feel
    if (self.mood != MoodSleep) {
        if (self.blinkFrames > 0) self.blinkFrames -= 1;
        else if (--self.blinkCountdown <= 0) {
            self.blinkFrames = 1;
            self.blinkCountdown = 50 + arc4random_uniform(60);   // once every 6–13 s
        }
    }
    // hop physics
    if (self.hopV != 0 || self.hopY > 0) {
        self.hopY += self.hopV; self.hopV -= 1.6;
        if (self.hopY <= 0) { self.hopY = 0; self.hopV = 0; }
    } else if (self.mood == MoodWork && self.tick % 10 == 0) {
        self.hopV = 4.2;   // bouncy while working
    } else if (self.mood == MoodAwake && arc4random_uniform(90) == 0) {
        self.hopV = 5.0;   // an occasional excited hop
    }
    // Wiggle — now and then while awake (settling into position)
    if (self.wiggleFrames > 0) self.wiggleFrames -= 1;
    else if (self.mood == MoodAwake && self.hopY == 0 && arc4random_uniform(150) == 0)
        self.wiggleFrames = 12;
    // Glide — now and then, a lazy slide left and right
    if (self.glideFrames > 0) self.glideFrames -= 1;
    else if (self.mood == MoodAwake && self.hopY == 0 && arc4random_uniform(240) == 0)
        self.glideFrames = 70;
    self.rubAccum *= 0.94;   // the rub gauge cools slowly
    // Gaze: without a mouse, glance around now and then — smoothly toward a target (no teleporting)
    if (!self.mouseInside && self.mood != MoodSleep && --self.glanceCountdown <= 0) {
        self.lookTarget = NSMakePoint(((int)arc4random_uniform(3) - 1) * 0.8,
                                      ((int)arc4random_uniform(3) - 1) * 0.4);
        self.glanceCountdown = 30 + arc4random_uniform(50);
    }
    if (!self.mouseInside) {
        self.lookVec = NSMakePoint(self.lookVec.x + (self.lookTarget.x - self.lookVec.x) * 0.25,
                                   self.lookVec.y + (self.lookTarget.y - self.lookVec.y) * 0.25);
    }
    // floating hearts
    for (Heart *h in [self.hearts copy]) {
        h.y += h.vy; h.life -= 0.045;
        if (h.life <= 0) [self.hearts removeObject:h];
    }
    // Ambient water bubbles — disabled by user request. Working bubbles (a state signal) are separate.
    if (NO && --self.bubbleCountdown <= 0) {
        AmbientBubble *b = [AmbientBubble new];
        CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2;
        b.x = ox + CELL * (0.8 + arc4random_uniform(20) / 10.0);
        b.y = 16 + BROWS * CELL * 0.55;
        b.vy = 0.6 + arc4random_uniform(6) / 10.0;
        b.size = 2.5 + arc4random_uniform(25) / 10.0;
        b.life = 1.0;
        b.wobble = arc4random_uniform(100) / 100.0 * 6.28;
        [self.ambient addObject:b];
        self.bubbleCountdown = 34 + arc4random_uniform(56);   // every 4–11 s
    }
    for (AmbientBubble *b in [self.ambient copy]) {
        b.y += b.vy;
        b.wobble += 0.18;
        b.x += sin(b.wobble) * 0.35;
        b.life -= 0.012;
        if (b.life <= 0 || b.y > self.bounds.size.height - 4) [self.ambient removeObject:b];
    }
    self.needsDisplay = YES;
}

// ---------------- drawing
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2
               + (self.wiggleFrames > 0 ? sin(self.wiggleFrames * 1.1) * 2.4 : 0)
               + (self.glideFrames > 0 ? sin(self.glideFrames / 70.0 * M_PI * 2) * 5.0 : 0);
    CGFloat oy = 16 + self.hopY;
    CGFloat spriteTop, spriteRight;
    CGFloat breath = (self.mood == MoodSleep ? 1.6 : 0.9) * (1 + sin(self.breathPhase)) / 2;

    if (self.sheet) {
        int row = sheetRowFor(self.mood);
        int col = (int)(self.tick / 3) % SHEET_COLS;
        NSRect src = NSMakeRect(col * SHEET_CELL_W,
                                self.sheet.size.height - (row + 1) * SHEET_CELL_H,
                                SHEET_CELL_W, SHEET_CELL_H);
        NSRect dst = NSMakeRect((self.bounds.size.width - 96) / 2, 12 + self.hopY, 96, 104);
        [NSGraphicsContext.currentContext setImageInterpolation:NSImageInterpolationNone];
        [self.sheet drawInRect:dst fromRect:src
                     operation:NSCompositingOperationSourceOver fraction:1.0
                respectFlipped:YES hints:nil];
        spriteTop = NSMaxY(dst); spriteRight = NSMaxX(dst);
    } else {
        // The fish floats in water — bobbing doubles as breathing
        CGFloat bob = sin(self.breathPhase * (self.mood == MoodSleep ? 0.5 : 1.0))
                      * (self.mood == MoodSleep ? 1.5 : 2.5);
        oy += bob;
        BOOL flipped = (self.mood == MoodAlert);   // pipeline problem = belly-up fish
        // Tail wag: the tail columns move up and down (faster while working)
        long wagTick = self.mood == MoodWork ? self.tick : self.tick / 3;
        CGFloat wag = (wagTick % 2 == 0 ? 1 : -1) * (self.mood == MoodSleep ? 0 : 2);
        for (int r = 0; r < BROWS; r++) {
            int logicalY = flipped ? (BROWS - 1 - r) : r;
            for (int c = 0; c < BCOLS; c++) {
                NSColor *col = fishCellColor(c, logicalY);
                if (!col) continue;
                [col setFill];
                // snap to integer coordinates — fractional offsets cause stripes between pixels
                CGFloat y = floor(oy + (BROWS - 1 - r) * CELL + (c >= 10 ? wag : 0));
                NSRectFill(NSMakeRect(floor(ox + c * CELL), y, CELL, CELL));
            }
        }
        [self drawFaceAtX:ox y:oy flipped:flipped];
        spriteTop = oy + BROWS * CELL;
        spriteRight = ox + BCOLS * CELL;
    }

    // zzz (asleep)
    if (self.mood == MoodSleep && (self.tick / 8) % 2 == 0) {
        NSString *z = (self.tick / 8) % 4 == 0 ? @"z" : @"zZ";
        [z drawAtPoint:NSMakePoint(spriteRight - 14, spriteTop + 2)
        withAttributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightBold],
                         NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.55 alpha:0.9]}];
    }
    // water bubbles (small outlined circles — pixel feel)
    for (AmbientBubble *b in self.ambient) {
        NSColor *bc = [NSColor colorWithCalibratedRed:0.55 green:0.80 blue:0.98
                                                alpha:MAX(0, MIN(0.8, b.life))];
        [bc setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(b.x, b.y, b.size, b.size)];
        ring.lineWidth = 1.2;
        [ring stroke];
    }
    // heart
    for (Heart *h in self.hearts) [self drawHeartAt:NSMakePoint(h.x, h.y) alpha:h.life];
    // speech bubble
    if (self.bubbleOverride && self.bubbleUntil &&
        [self.bubbleUntil timeIntervalSinceNow] <= 0) self.bubbleOverride = nil;
    NSString *bubble = self.bubbleOverride;
    if (!bubble && self.moodChangedAt && [NSDate.date timeIntervalSinceDate:self.moodChangedAt] < 12.0) {
        switch (self.mood) {
            case MoodWork:  bubble = @"Tidying…"; break;
            case MoodAwake: bubble = @"Report's ready"; break;
            case MoodAlert: bubble = @"Pipeline problem!"; break;
            default: break;
        }
    }
    if (bubble) [self drawBubble:bubble top:spriteTop];
    // badge
    // Badge removed (user request) — waiting counts are conveyed by the dashboard and the mood expression
    (void)spriteRight;
}

// Face (layer 2: code — small black eyes without whites. Blinking and gaze are handled in code)
- (void)drawFaceAtX:(CGFloat)ox y:(CGFloat)oy flipped:(BOOL)flipped {
    // Eye position = upper head (rows 4..5, cols 3..4 — vertically centered, so the same spot when flipped).
    int eyeRowTop = 3;
    CGFloat eyeY = oy + (BROWS - 1 - (eyeRowTop + 1)) * CELL - CELL * 0.5;   // bottom y of the eye area (half a cell down)
    CGFloat ex = ox + 2.5 * CELL;
    CGFloat eyeW = 1.2 * CELL;  // the artist's eye = vertical pill (1x2 cells)
    (void)flipped;
    BOOL closed = (self.mood == MoodSleep) || self.blinkFrames > 0;
    BOOL happy = [self isHappy];
    NSColor *ink = [NSColor colorWithCalibratedWhite:0.10 alpha:1];

    if (self.mood == MoodAlert) {  // X eyes — the universal sign of a belly-up fish
        [ink setFill];
        for (int i = 0; i < 4; i++) {
            CGFloat d = i * CELL * 0.55;
            NSRectFill(NSMakeRect(ex + d, eyeY + d, CELL * 0.6, CELL * 0.6));
            NSRectFill(NSMakeRect(ex + CELL * 1.65 - d, eyeY + d, CELL * 0.6, CELL * 0.6));
        }
    } else if (happy) {  // ∩ smiling eyes
        [ink setFill];
        NSRectFill(NSMakeRect(ex - CELL * 0.2, eyeY + CELL * 0.2, CELL * 0.7, CELL * 1.1));
        NSRectFill(NSMakeRect(ex + CELL * 0.5, eyeY + CELL * 1.0, CELL * 1.4, CELL * 0.7));
        NSRectFill(NSMakeRect(ex + CELL * 1.7, eyeY + CELL * 0.2, CELL * 0.7, CELL * 1.1));
    } else if (closed) {  // closed eyes — a bar in the same spot (never feels like they vanished)
        [ink setFill];
        NSRectFill(NSMakeRect(ex - CELL * 0.1, eyeY + CELL * 0.6, CELL * 2.4, CELL * 0.8));
    } else {  // black vertical pill eyes — follow the gaze
        [ink setFill];
        NSRectFill(NSMakeRect(ex + self.lookVec.x * CELL * 0.3,
                              eyeY + CELL * 0.05 + self.lookVec.y * CELL * 0.3,
                              CELL * 1.1, CELL * 1.9));
    }

    // No mouth — bubbles rise in front of the head only while working (a state signal)
    if (self.mood == MoodWork) {
        [[NSColor colorWithCalibratedRed:0.55 green:0.80 blue:0.98 alpha:0.85] setFill];
        int phase = (int)(self.tick % 12);
        if (phase < 8) {
            CGFloat bs = 2.5 + phase * 0.3;
            [[NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(ox + CELL * 0.4, eyeY + CELL * (2.5 + phase * 0.7), bs, bs)] fill];
        }
    }
}

- (void)drawHeartAt:(NSPoint)p alpha:(CGFloat)a {
    NSColor *c = [NSColor colorWithCalibratedRed:0.95 green:0.42 blue:0.50 alpha:MAX(0, MIN(1, a))];
    [c setFill];
    CGFloat s = 3.2;  // pixel heart (5x4)
    int heart[4][5] = {{0,1,0,1,0},{1,1,1,1,1},{0,1,1,1,0},{0,0,1,0,0}};
    for (int r = 0; r < 4; r++)
        for (int col = 0; col < 5; col++)
            if (heart[r][col]) NSRectFill(NSMakeRect(p.x + col * s, p.y + (3 - r) * s, s, s));
}

- (void)drawBubble:(NSString *)text top:(CGFloat)spriteTop {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1]};
    NSSize ts = [text sizeWithAttributes:attrs];
    CGFloat bw = ts.width + 16, bh = ts.height + 8;
    CGFloat ox = (self.bounds.size.width - BCOLS * CELL) / 2;
    CGFloat headX = ox + 4 * CELL;                     // anchor above the head
    CGFloat bx = MAX(4, MIN(headX - bw * 0.35, self.bounds.size.width - bw - 4));
    CGFloat by = MIN(spriteTop + 10, self.bounds.size.height - bh - 2);
    NSRect bub = NSMakeRect(bx, by, bw, bh);
    [[NSColor colorWithCalibratedWhite:0.98 alpha:0.96] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bub xRadius:8 yRadius:8] fill];
    NSBezierPath *tail = [NSBezierPath bezierPath];    // speech-bubble tail
    [tail moveToPoint:NSMakePoint(headX - 3, by + 2)];   // overlap the body to hide the seam
    [tail lineToPoint:NSMakePoint(headX + 7, by + 2)];
    [tail lineToPoint:NSMakePoint(headX + 1, by - 6)];
    [tail closePath];
    [tail fill];
    [text drawAtPoint:NSMakePoint(bx + 8, by + 4) withAttributes:attrs];
}

// ---------------- interaction
- (void)mouseEntered:(NSEvent *)e { self.mouseInside = YES; }
- (void)mouseExited:(NSEvent *)e { self.mouseInside = NO; self.lookVec = NSZeroPoint; }
- (void)mouseMoved:(NSEvent *)e {
    NSPoint vp = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self pointOverFish:vp]) {
        self.rubAccum += fabs(e.deltaX) + fabs(e.deltaY);
        if (self.rubAccum > 90) {   // rubbing acknowledged — overjoyed
            self.rubAccum = 0;
            for (int i = 0; i < 4; i++) {
                Heart *h = [Heart new];
                h.x = self.bounds.size.width / 2 - 30 + arc4random_uniform(60);
                h.y = 16 + BROWS * CELL - 8 + arc4random_uniform(14);
                h.vy = 1.2 + arc4random_uniform(10) / 10.0;
                h.life = 1.0;
                [self.hearts addObject:h];
            }
            self.happyUntil = [NSDate dateWithTimeIntervalSinceNow:2.0];
            self.hopV = 3.5;
            self.wiggleFrames = 14;
        }
    }
    if (self.mood == MoodSleep) return;   // a sleeping fish doesn't look around
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    CGFloat dx = (p.x - center.x) / (self.bounds.size.width / 2);
    CGFloat dy = (p.y - center.y) / (self.bounds.size.height / 2);
    self.lookVec = NSMakePoint(MAX(-1, MIN(1, dx)), MAX(-1, MIN(1, dy)));
}

- (void)mouseDown:(NSEvent *)e {
    self.dragged = NO;
    self.mouseIsDown = YES;
    self.dragOffset = e.locationInWindow;
}
- (void)mouseDragged:(NSEvent *)e {
    self.dragged = YES;
    NSPoint s = [NSEvent mouseLocation];
    [self.window setFrameOrigin:NSMakePoint(s.x - self.dragOffset.x, s.y - self.dragOffset.y)];
}

- (void)mouseUp:(NSEvent *)e {
    self.mouseIsDown = NO;
    if (self.dragged) {
        NSPoint o = self.window.frame.origin;
        NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"x": @(o.x), @"y": @(o.y)}
                                                    options:0 error:nil];
        [d writeToFile:[GariStateReader gariPath:@"pet/position.json"] atomically:YES];
        return;
    }
    // Single click = pet + toggle the dashboard (instant — no double-click meaning, no delay)
    [self petting];
}

- (void)petting {
    self.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.8];
    self.hopV = 5.5;
    for (int i = 0; i < 3 + arc4random_uniform(3); i++) {
        Heart *h = [Heart new];
        h.x = self.bounds.size.width / 2 - 30 + arc4random_uniform(60);
        h.y = 16 + BROWS * CELL - 8 + arc4random_uniform(14);
        h.vy = 1.2 + arc4random_uniform(10) / 10.0;
        h.life = 1.0;
        [self.hearts addObject:h];
    }
    // Line pool: defaults + extras per situation (sign-offs, work, time of day) — never the same line twice in a row
    NSMutableArray *lines = [@[
        @"Reporting for duty!", @"Hehe", @"Oh, you're here!", @"You called?",
        @"Listening, as always", @"Stacking cards", @"I'll do the remembering",
        @"Ask me anything", @"Ready to meddle", @"Water's nice today",
        @"Fins in top condition", @"On my honor as a Garibaldi!",
        @"You're the best", @"Wagging my tail", @"Forgot something? I didn't"] mutableCopy];
    if (self.badge > 0)
        [lines addObjectsFromArray:@[
            @"Dashboard, at your service", @"Things are waiting for your sign-off",
            @"Your inbox misses you", @"A few things need a stamp"]];
    if (self.mood == MoodWork)
        [lines addObjectsFromArray:@[
            @"Digging through work — you called?", @"Busy, but you come first",
            @"See the bubbles? That's me working"]];
    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:NSDate.date];
    if (hour >= 23 || hour < 5)
        [lines addObjectsFromArray:@[
            @"Still up at this hour… impressive", @"I'm nocturnal, no worries",
            @"Quiet currents before dawn — nice"]];
    else if (hour >= 5 && hour < 10)
        [lines addObjectsFromArray:@[
            @"Good morning!", @"The morning report is ready", @"Start with today's one step"]];
    NSString *pick = lines[arc4random_uniform((uint32_t)lines.count)];
    if ([pick isEqualToString:self.lastBubbleLine] && lines.count > 1)
        pick = lines[arc4random_uniform((uint32_t)lines.count)];
    self.lastBubbleLine = pick;
    self.bubbleOverride = pick;
    self.bubbleUntil = [NSDate dateWithTimeIntervalSinceNow:2.5];
    [self toggleHud];   // click = pet + dashboard (everything about Gari is visible inside Gari)
    self.needsDisplay = YES;
}

static NSString *hudTimeShort(NSString *iso) {
    if (![iso isKindOfClass:NSString.class] || iso.length < 16) return @"";
    NSString *hm = [iso substringWithRange:NSMakeRange(11, 5)];
    NSString *day = [iso substringToIndex:10];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd";
    NSString *today = [df stringFromDate:NSDate.date];
    return [day isEqualToString:today] ? hm : [NSString stringWithFormat:@"%@ %@", [day substringFromIndex:5], hm];
}

// ---------------- dashboard (HUD) — reports, sign-offs, pendings, cards, status in a panel next to the pet

- (void)toggleHud {
    if (self.hudWindow && self.hudWindow.isVisible) {
        [self.hudWindow orderOut:nil];
        return;
    }
    [self openHud];
}

// Assemble the panel card (shared by window and snapshot) — header + scrolling content + bottom question bar
- (NSView *)makeHudCard:(NSSize)size {
    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 18;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;

    // Live background blur — the tint below holds the card up even in snapshots / where unsupported
    NSVisualEffectView *fx = [[NSVisualEffectView alloc]
        initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    fx.material = NSVisualEffectMaterialHUDWindow;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:fx];
    NSView *tint = [[NSView alloc] initWithFrame:fx.frame];
    tint.wantsLayer = YES;
    tint.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:0.88].CGColor;
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:tint];

    // ---- two-tier header: (1) one status line (dot + summary + time, no name — user request) (2) our own tab bar ----
    CGFloat headerH = 68;
    NSView *dot = [[NSView alloc]
        initWithFrame:NSMakeRect(22, size.height - 25, 8, 8)];
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = 4;
    dot.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.30 green:0.82 blue:0.45 alpha:1].CGColor;
    [card addSubview:dot];
    self.headerDot = dot;

    NSTextField *sub = hudLabel(@"Connecting…", [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
                                [NSColor colorWithCalibratedWhite:0.70 alpha:1], 1, size.width - 44 - 66);
    sub.frame = NSMakeRect(38, size.height - 30, size.width - 44 - 66, 16);
    [card addSubview:sub];
    self.headerSub = sub;

    NSTextField *time = hudLabel(@"", [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                 [NSColor colorWithCalibratedWhite:0.45 alpha:1], 1, 60);
    time.frame = NSMakeRect(size.width - 70, size.height - 30, 50, 16);
    time.alignment = NSTextAlignmentRight;
    [card addSubview:time];
    self.headerTime = time;

    // Our own tab bar — system controls render as inactive gray on a floating translucent panel, so we draw it ourselves
    CGFloat halfW = size.width / 2;
    NSButton *ta = [NSButton buttonWithTitle:@"Dashboard" target:self action:@selector(tabTapped:)];
    ta.bordered = NO;
    ta.tag = 0;
    ta.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    ta.frame = NSMakeRect(0, size.height - 64, halfW, 30);
    [card addSubview:ta];
    self.tabA = ta;
    NSButton *tb = [NSButton buttonWithTitle:@"Chat" target:self action:@selector(tabTapped:)];
    tb.bordered = NO;
    tb.tag = 1;
    tb.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    tb.frame = NSMakeRect(halfW, size.height - 64, halfW, 30);
    [card addSubview:tb];
    self.tabB = tb;

    NSView *headerLine = [[NSView alloc]
        initWithFrame:NSMakeRect(0, size.height - headerH, size.width, 1)];
    headerLine.wantsLayer = YES;
    headerLine.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.07].CGColor;
    [card addSubview:headerLine];

    NSView *tabLine = [[NSView alloc]
        initWithFrame:NSMakeRect(0, size.height - headerH, halfW, 2)];
    tabLine.wantsLayer = YES;
    tabLine.layer.backgroundColor = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.10 alpha:1].CGColor;
    [card addSubview:tabLine];
    self.tabLine = tabLine;

    // ---- scrolling content ----
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 57, size.width, size.height - headerH - 57)];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    sv.autohidesScrollers = YES;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:sv];
    self.hudScroll = sv;

    // ---- bottom question bar (no divider — the input box border is the boundary) ----

    // Separate the shell (style) from the pure input (text only) — styling a text field directly
    // pins the text to the top and breaks with a doubled editor background
    CGFloat wrapH = 44;
    NSView *inputWrap = [[NSView alloc]
        initWithFrame:NSMakeRect(14, 9, size.width - 28, wrapH)];
    inputWrap.wantsLayer = YES;
    inputWrap.layer.cornerRadius = 10;
    inputWrap.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;
    inputWrap.layer.borderWidth = 1;
    inputWrap.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;
    [card addSubview:inputWrap];

    ResizeGrip *grip = [[ResizeGrip alloc] initWithFrame:
        NSMakeRect(size.width - 16, 2, 14, 16)];
    grip.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [card addSubview:grip];
    self.hudGrip = grip;

    NSScrollView *inSv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(12, 11, inputWrap.frame.size.width - 24, wrapH - 22)];
    inSv.drawsBackground = NO;
    inSv.hasVerticalScroller = YES;
    inSv.autohidesScrollers = YES;
    inSv.borderType = NSNoBorder;
    ChatInputView *tv = [[ChatInputView alloc] initWithFrame:
        NSMakeRect(0, 0, inSv.frame.size.width, inSv.frame.size.height)];
    tv.richText = NO;
    tv.drawsBackground = NO;
    tv.font = [NSFont systemFontOfSize:13];
    tv.textColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
    tv.insertionPointColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
    tv.textContainerInset = NSMakeSize(0, 1);
    tv.textContainer.lineFragmentPadding = 0;
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.delegate = (id<NSTextViewDelegate>)self;
    inSv.documentView = tv;
    NSTextField *ph = hudLabel(@"Ask Gari…", [NSFont systemFontOfSize:13],
                               [NSColor colorWithCalibratedWhite:0.48 alpha:1], 1,
                               inputWrap.frame.size.width - 24);
    ph.frame = NSMakeRect(13, (wrapH - ph.frame.size.height) / 2,
                          inputWrap.frame.size.width - 24, ph.frame.size.height);
    [inputWrap addSubview:ph];            // label behind —
    [inputWrap addSubview:inSv];          // input on top (no click shield)
    self.hudInputScroll = inSv;
    self.hudInput = tv;
    self.hudPlaceholder = ph;
    NSClickGestureRecognizer *wrapTap = [[NSClickGestureRecognizer alloc]
        initWithTarget:self action:@selector(focusInput:)];
    [inputWrap addGestureRecognizer:wrapTap];   // clicking the box padding also focuses

    return card;
}

// ---- multi-line input: Enter = send / Shift+Enter = newline, grows with content (max 5 lines) ----
- (BOOL)textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:)) {
        if (NSEvent.modifierFlags & NSEventModifierFlagShift) return NO;   // allow newline
        [self hudAsk:nil];
        return YES;
    }
    return NO;
}

- (void)textDidChange:(NSNotification *)n {
    self.hudPlaceholder.hidden = self.hudInput.string.length > 0;
    [self growInput];
}

- (void)growInput {
    NSTextView *tv = self.hudInput;
    (void)[tv.layoutManager glyphRangeForTextContainer:tv.textContainer];
    CGFloat used = [tv.layoutManager usedRectForTextContainer:tv.textContainer].size.height;
    CGFloat wrapH = MAX(44, MIN(124, ceil(used) + 24));   // grows 1–5 lines, then scrolls inside
    NSView *wrap = self.hudInputScroll.superview;
    if (fabs(wrap.frame.size.height - wrapH) < 1) return;
    NSView *card = wrap.superview;
    CGFloat W = card.frame.size.width, H = card.frame.size.height;
    wrap.frame = NSMakeRect(14, 9, W - 28, wrapH);
    self.hudInputScroll.frame = NSMakeRect(12, 11, W - 28 - 24, wrapH - 22);
    CGFloat bottom = 9 + wrapH + 4;
    CGFloat headerH = 68;
    self.hudScroll.frame = NSMakeRect(0, bottom, W, H - headerH - bottom);
    [self buildHud];
}

// Brighten the cursor (insertion point) when editing — the default black cursor is invisible on a dark panel
- (void)controlTextDidBeginEditing:(NSNotification *)note {
    NSTextView *editor = self.hudInput;
    if ([editor isKindOfClass:NSTextView.class]) {
        editor.insertionPointColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1];
        editor.drawsBackground = NO;
    }
}

- (void)hudResizeEnded {
    NSSize s = self.hudWindow.frame.size;
    NSDictionary *j = @{@"w": @(s.width), @"h": @(s.height)};
    [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil]
        writeToFile:[GariStateReader gariPath:@"pet/hud-size.json"] atomically:YES];
    NSString *typed = self.hudInput.string ?: @"";
    self.hudWindow.contentView = [self makeHudCard:s];
    [self wireGrip];
    [self buildHud];
    self.hudInput.string = typed;
    [self textDidChange:nil];
    [self.hudWindow makeFirstResponder:self.hudInput];
}

- (void)wireGrip {
    self.hudGrip.win = self.hudWindow;
    __weak typeof(self) weakSelf = self;
    self.hudGrip.onResizeEnd = ^{ [weakSelf hudResizeEnded]; };
}

- (void)toggleDetail:(id)s { self.showDetail = !self.showDetail; [self buildHud]; }

- (void)stakeTapped:(NSClickGestureRecognizer *)g {
    NSString *action = g.view.identifier;
    if ([action isEqualToString:@"chat"]) {
        self.hudMode = 1;
        [self buildHud];
    }
    [self.hudWindow makeFirstResponder:self.hudInput];
}

- (void)focusInput:(id)sender {
    [self.hudWindow makeFirstResponder:self.hudInput];
}

- (void)tabTapped:(NSButton *)btn {
    self.hudMode = (int)btn.tag;
    [self buildHud];
}

- (void)updateTabStyles {
    NSColor *on = [NSColor colorWithCalibratedWhite:0.96 alpha:1];
    NSColor *off = [NSColor colorWithCalibratedWhite:0.48 alpha:1];
    self.tabA.contentTintColor = self.hudMode == 0 ? on : off;
    self.tabB.contentTintColor = self.hudMode == 1 ? on : off;
    if (self.tabLine) {
        NSRect f = self.tabLine.frame;
        f.origin.x = self.hudMode == 0 ? 0 : f.size.width;
        self.tabLine.frame = f;
    }
}

// hudData (JSON) → native rows. The single place to iterate on polish.
- (void)buildHud {
    [self updateTabStyles];
    if (self.hudMode == 1) { [self buildChat]; return; }
    CGFloat W = self.hudScroll.frame.size.width;
    CGFloat pad = 22, contentW = W - pad * 2 - 14;   // room for the scroller
    FlippedView *doc = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, 10)];
    __block CGFloat y = 16;

    NSColor *fg = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    NSColor *dim = [NSColor colorWithCalibratedWhite:0.52 alpha:1];
    NSColor *accent = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.10 alpha:1];

    NSDictionary *d = self.hudData;

    // header refresh
    NSDictionary *pipe = d[@"pipeline"];
    if (pipe) {
        BOOL ok = [pipe[@"ok"] boolValue];
        self.headerDot.layer.backgroundColor = (ok
            ? [NSColor colorWithCalibratedRed:0.30 green:0.82 blue:0.45 alpha:1]
            : [NSColor colorWithCalibratedRed:0.92 green:0.35 blue:0.30 alpha:1]).CGColor;
        NSDictionary *fresh = [d[@"freshness"] isKindOfClass:NSDictionary.class] ? d[@"freshness"] : @{};
        NSString *age = @"no record";
        if (pipe[@"age_min"] != NSNull.null && pipe[@"age_min"]) {
            int interval = [fresh[@"sweep_interval_min"] intValue] ?: 10;
            int remain = interval - [pipe[@"age_min"] intValue];
            age = remain > 0
                ? [NSString stringWithFormat:@"tidied %@ min ago, next in ~%d min", pipe[@"age_min"], remain]
                : [NSString stringWithFormat:@"tidied %@ min ago, refreshing soon", pipe[@"age_min"]];
        }
        NSNumber *cost = [pipe[@"cost_today"] isKindOfClass:NSNumber.class] ? pipe[@"cost_today"] : nil;
        self.headerSub.stringValue = [NSString stringWithFormat:@"%@ · %@ · cards %@%@",
            ok ? @"healthy" : @"needs a check", age, pipe[@"cards_today"] ?: @0,
            cost ? [NSString stringWithFormat:@" · $%.2f", cost.doubleValue] : @""];
        self.headerTime.stringValue = d[@"time"] ?: @"";
    } else {
        self.headerSub.stringValue = @"Connection failed — run gari status in a terminal";
    }

    NSDictionary *fr = [d[@"freshness"] isKindOfClass:NSDictionary.class] ? d[@"freshness"] : @{};
    NSString *mts = hudTimeShort(fr[@"morning_ts"]);
    void (^section)(NSString *) = ^(NSString *title) {
        NSTextField *l = hudLabel(title, [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                  dim, 1, contentW);
        NSMutableAttributedString *a = [l.attributedStringValue mutableCopy];
        [a addAttribute:NSKernAttributeName value:@0.8 range:NSMakeRange(0, a.length)];
        l.attributedStringValue = a;
        l.frame = NSMakeRect(pad, y, contentW, l.frame.size.height);
        [doc addSubview:l];
        y += l.frame.size.height + 8;
    };

    // ═══ New grammar: Gari's one line + today's 3 things that matter (consequence clauses) — why this screen exists
    NSDictionary *stakes = [d[@"stakes"] isKindOfClass:NSDictionary.class] ? d[@"stakes"] : @{};
    NSArray *stakeList = [stakes[@"stakes"] isKindOfClass:NSArray.class] ? stakes[@"stakes"] : @[];
    if ([stakes[@"brief"] length]) {
        NSTextField *br = hudLabel(stakes[@"brief"],
            [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
            [NSColor colorWithCalibratedWhite:0.96 alpha:1], 0, contentW - 8);
        br.frame = NSMakeRect(pad + 4, y + 6, contentW - 8, br.frame.size.height);
        [doc addSubview:br];
        y += br.frame.size.height + 24;
    }
    NSArray *nums = @[@"①", @"②", @"③"];
    for (NSUInteger si = 0; si < MIN(stakeList.count, 3u); si++) {
        NSDictionary *st = stakeList[si];
        NSString *action = st[@"action"] ?: @"";
        BOOL hasBtns = [action isEqualToString:@"resolve"] && [st[@"id"] length];
        CGFloat tw2 = contentW - 28 - (hasBtns ? 66 : 0);
        NSTextField *gain = hudLabel(st[@"gain"],
            [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold], fg, 0, tw2 - 26);
        NSString *subT = [action isEqualToString:@"input"]
            ? [NSString stringWithFormat:@"%@  ↳ answer in the box below", st[@"label"] ?: @""]
            : ([action isEqualToString:@"chat"]
               ? [NSString stringWithFormat:@"%@  ↳ click to chat", st[@"label"] ?: @""]
               : (st[@"label"] ?: @""));
        NSTextField *lb = hudLabel(subT, [NSFont systemFontOfSize:11.5], dim, 2, tw2 - 26);
        CGFloat rh = 13 + gain.frame.size.height + 5 + lb.frame.size.height + 13;
        NSView *row = hudRowCard(contentW);
        row.frame = NSMakeRect(pad, y, contentW, rh);
        NSTextField *no = hudLabel(nums[si], [NSFont systemFontOfSize:14 weight:NSFontWeightBold],
                                   accent, 1, 22);
        no.frame = NSMakeRect(13, rh - 14 - no.frame.size.height, 22, no.frame.size.height);
        [row addSubview:no];
        gain.frame = NSMakeRect(38, rh - 13 - gain.frame.size.height, tw2 - 26, gain.frame.size.height);
        [row addSubview:gain];
        lb.frame = NSMakeRect(38, 12, tw2 - 26, lb.frame.size.height);
        [row addSubview:lb];
        if (hasBtns) {
            NSButton *done = flatBtn(@"Done", accent, self, @selector(resolvePending:));
            done.identifier = st[@"id"];
            done.frame = NSMakeRect(contentW - 66, rh / 2 + 2, 52, 23);
            [row addSubview:done];
            NSButton *later = flatBtn(@"Later", dim, self, @selector(snoozePending:));
            later.identifier = st[@"id"];
            later.frame = NSMakeRect(contentW - 66, rh / 2 - 25, 52, 23);
            [row addSubview:later];
        } else {
            gain.identifier = action;   // input → focus / chat → chat tab
            NSClickGestureRecognizer *tap = [[NSClickGestureRecognizer alloc]
                initWithTarget:self action:@selector(stakeTapped:)];
            [gain addGestureRecognizer:tap];
            NSClickGestureRecognizer *tap2 = [[NSClickGestureRecognizer alloc]
                initWithTarget:self action:@selector(stakeTapped:)];
            lb.identifier = action;
            [lb addGestureRecognizer:tap2];
        }
        [doc addSubview:row];
        y += rh + 10;
    }
    if (stakeList.count) {
        NSNumber *tot = [stakes[@"total"] isKindOfClass:NSNumber.class] ? stakes[@"total"] : @0;
        NSButton *more = [NSButton buttonWithTitle:
            [NSString stringWithFormat:@"Gari is watching the other %@ · details %@",
             tot, self.showDetail ? @"▾" : @"▸"]
            target:self action:@selector(toggleDetail:)];
        more.bordered = NO;
        more.controlSize = NSControlSizeSmall;
        more.font = [NSFont systemFontOfSize:11.5];
        more.contentTintColor = dim;
        more.alignment = NSTextAlignmentLeft;
        more.frame = NSMakeRect(pad, y + 4, contentW, 24);
        [doc addSubview:more];
        y += 36;
    }

    if (self.showDetail || !stakeList.count) {   // details = the whole older view (always, when there are no stakes)

    // ═══ Group 1: Today — one combined card for the one step, nudge, question (morning output, once a day)
    NSDictionary *nsD = d[@"next_step"];
    NSString *nag = [d[@"nag"] isKindOfClass:NSString.class] ? d[@"nag"] : @"";
    NSString *question = [d[@"question"] isKindOfClass:NSString.class] ? d[@"question"] : @"";
    NSString *mentor = [d[@"mentor"] isKindOfClass:NSString.class] ? d[@"mentor"] : @"";
    if ([nsD[@"action"] length] || nag.length || question.length || mentor.length) {
        section(mts.length
            ? [NSString stringWithFormat:@"Today — computed %@ · refreshes tomorrow at %d:00", mts, [fr[@"report_hour"] intValue] ?: 9]
            : @"Today");
        FlippedView *today = [[FlippedView alloc] initWithFrame:NSZeroRect];
        today.wantsLayer = YES;
        today.layer.backgroundColor = [accent colorWithAlphaComponent:0.10].CGColor;
        today.layer.cornerRadius = 12;
        __block CGFloat cy = 13;
        CGFloat innerW = contentW - 28;
        if ([nsD[@"action"] length]) {
            NSTextField *act = hudLabel(nsD[@"action"],
                [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], fg, 0, innerW);
            act.frame = NSMakeRect(14, cy, innerW, act.frame.size.height);
            [today addSubview:act];
            cy += act.frame.size.height;
            if ([nsD[@"reason"] length]) {
                NSTextField *why = hudLabel(nsD[@"reason"],
                    [NSFont systemFontOfSize:12], [NSColor colorWithCalibratedWhite:0.72 alpha:1], 0, innerW);
                why.frame = NSMakeRect(14, cy + 4, innerW, why.frame.size.height);
                [today addSubview:why];
                cy += 4 + why.frame.size.height;
            }
        }
        void (^subRow)(NSString *, NSString *, NSColor *) = ^(NSString *prefix, NSString *text, NSColor *pc) {
            if (!text.length) return;
            NSView *div = [[NSView alloc] initWithFrame:NSMakeRect(14, cy + 10, innerW, 1)];
            div.wantsLayer = YES;
            div.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1 alpha:0.09].CGColor;
            [today addSubview:div];
            cy += 20;
            NSTextField *pl = hudLabel(prefix, [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], pc, 1, 34);
            pl.frame = NSMakeRect(14, cy + 1, 34, pl.frame.size.height);
            [today addSubview:pl];
            NSTextField *tl = hudLabel(text, [NSFont systemFontOfSize:12.5], fg, 0, innerW - 42);
            tl.frame = NSMakeRect(56, cy, innerW - 42, tl.frame.size.height);
            [today addSubview:tl];
            cy += tl.frame.size.height;
        };
        subRow(@"Mentor", mentor, [NSColor colorWithCalibratedWhite:0.62 alpha:1]);
        subRow(@"Nudge", nag, accent);
        subRow(@"Question", question, dim);
        if (question.length) {
            NSTextField *hint = hudLabel(@"↳ answer in the box below and it gets recorded",
                [NSFont systemFontOfSize:10.5], dim, 1, innerW - 42);
            hint.frame = NSMakeRect(56, cy + 3, innerW - 42, hint.frame.size.height);
            [today addSubview:hint];
            cy += 3 + hint.frame.size.height;
        }
        today.frame = NSMakeRect(pad, y, contentW, cy + 13);
        [doc addSubview:today];
        y += cy + 13 + 22;
    }

    // ═══ Group 1.5: project compass — where things are heading (wiki-based; user's definition: "the dashboard is for checking direction")
    NSArray *compass = [d[@"compass"] isKindOfClass:NSArray.class] ? d[@"compass"] : @[];
    if (compass.count) {
        section(@"Project compass — from the wikis");
        for (NSDictionary *b in compass) {
            NSTextField *pj = hudLabel(b[@"project"],
                [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], fg, 1, contentW - 28);
            NSTextField *idl = hudLabel(b[@"identity"],
                [NSFont systemFontOfSize:10.5], dim, 2, contentW - 28);
            NSTextField *nx = hudLabel([b[@"next"] length]
                    ? [NSString stringWithFormat:@"Next: %@", b[@"next"]] : @"Next: (no pending items)",
                [NSFont systemFontOfSize:11.5],
                [NSColor colorWithCalibratedWhite:0.82 alpha:1], 2, contentW - 28);
            CGFloat rh = 10 + pj.frame.size.height + 2 + idl.frame.size.height
                       + 4 + nx.frame.size.height + 10;
            NSView *row = hudRowCard(contentW);
            row.frame = NSMakeRect(pad, y, contentW, rh);
            pj.frame = NSMakeRect(14, rh - 10 - pj.frame.size.height, contentW - 28, pj.frame.size.height);
            idl.frame = NSMakeRect(14, rh - 10 - pj.frame.size.height - 2 - idl.frame.size.height,
                                   contentW - 28, idl.frame.size.height);
            nx.frame = NSMakeRect(14, 10, contentW - 28, nx.frame.size.height);
            pj.identifier = b[@"project"];
            NSClickGestureRecognizer *tap = [[NSClickGestureRecognizer alloc]
                initWithTarget:self action:@selector(compassRowTapped:)];
            [pj addGestureRecognizer:tap];
            [row addSubview:pj];
            [row addSubview:idl];
            [row addSubview:nx];
            [doc addSubview:row];
            y += rh + 8;
        }
        y += 14;
    }

    // ═══ Group 2: Inbox — everything that needs your action (now / looks done / duplicates / sign-off / grading / others)
    NSArray *pendings = d[@"pendings"];
    NSDictionary *triage = [d[@"triage"] isKindOfClass:NSDictionary.class] ? d[@"triage"] : @{};
    NSArray *approvals = d[@"approvals"];
    NSArray *shadowItems = d[@"shadow"];
    NSUInteger inboxTotal = pendings.count + approvals.count + shadowItems.count;
    if (inboxTotal) {
        NSString *tts = hudTimeShort(triage[@"ts"]);
        section(tts.length
            ? [NSString stringWithFormat:@"Inbox %lu — reviewed by Gari %@", inboxTotal, tts]
            : [NSString stringWithFormat:@"Inbox %lu", inboxTotal]);

        NSString *nowId = triage[@"now"][@"id"] ?: @"";
        NSString *nowWhy = triage[@"now"][@"why"] ?: @"";
        NSMutableDictionary *doneLike = [NSMutableDictionary dictionary];
        for (NSDictionary *dl in (triage[@"done_like"] ?: @[]))
            if (dl[@"id"]) doneLike[dl[@"id"]] = dl[@"evidence"] ?: @"";
        NSMutableSet *dupeDrop = [NSMutableSet set];
        for (NSDictionary *dp in (triage[@"dupes"] ?: @[]))
            for (NSString *dr in (dp[@"drop"] ?: @[])) [dupeDrop addObject:dr];

        // shared pending row (with Done/Later buttons)
        void (^pendRow)(NSDictionary *, NSString *, NSColor *, BOOL) =
            ^(NSDictionary *p, NSString *tag, NSColor *tagColor, BOOL highlight) {
            BOOL dimmed = !highlight && tag.length;
            NSTextField *t = hudLabel(p[@"text"],
                [NSFont systemFontOfSize:13 weight:highlight ? NSFontWeightSemibold : NSFontWeightRegular],
                dimmed ? dim : fg, 0, contentW - 126);
            NSString *origin = [p[@"restored"] boolValue]
                ? [NSString stringWithFormat:@"backfilled · %@/%@", p[@"tool"] ?: @"", p[@"project"] ?: @""]
                : [NSString stringWithFormat:@"%@/%@", p[@"tool"] ?: @"", p[@"project"] ?: @""];
            NSString *subTxt = tag.length
                ? [NSString stringWithFormat:@"%@ · %@", tag, origin]
                : [origin stringByAppendingString:@" · click to ask for context"];
            NSTextField *sub2 = hudLabel(subTxt, [NSFont systemFontOfSize:10.5],
                tagColor ?: dim, 0, contentW - 126);
            CGFloat rh = 11 + t.frame.size.height + 3 + sub2.frame.size.height + 11;
            NSView *row = hudRowCard(contentW);
            if (highlight) {
                row.layer.borderColor = [accent colorWithAlphaComponent:0.5].CGColor;
                row.layer.borderWidth = 1;
            }
            row.frame = NSMakeRect(pad, y, contentW, rh);
            t.frame = NSMakeRect(14, rh - 11 - t.frame.size.height, contentW - 126, t.frame.size.height);
            [row addSubview:t];
            sub2.frame = NSMakeRect(14, 10, contentW - 126, sub2.frame.size.height);
            [row addSubview:sub2];
            t.identifier = p[@"id"] ?: @"";   // clicking the text = ask Gari for this pending item's context
            NSClickGestureRecognizer *tap = [[NSClickGestureRecognizer alloc]
                initWithTarget:self action:@selector(pendingRowTapped:)];
            [t addGestureRecognizer:tap];
            NSButton *done = flatBtn(@"Done", accent, self, @selector(resolvePending:));
            done.identifier = p[@"id"] ?: @"";
            done.frame = NSMakeRect(contentW - 66, rh / 2 + 2, 52, 23);
            [row addSubview:done];
            NSButton *later = flatBtn(@"Later", dim, self, @selector(snoozePending:));
            later.identifier = p[@"id"] ?: @"";
            later.frame = NSMakeRect(contentW - 66, rh / 2 - 25, 52, 23);
            [row addSubview:later];
            [doc addSubview:row];
            y += rh + 8;
        };

        NSDictionary *kinds = [triage[@"kinds"] isKindOfClass:NSDictionary.class] ? triage[@"kinds"] : @{};
        NSMutableArray *rest = [NSMutableArray array];       // direction-level — only you can decide
        NSMutableArray *workP = [NSMutableArray array];      // work-level — can be handled by delegation
        NSDictionary *nowP = nil;
        NSMutableArray *doneP = [NSMutableArray array], *dupeP = [NSMutableArray array];
        for (NSDictionary *p in pendings) {
            NSString *pid = p[@"id"] ?: @"";
            if ([pid isEqualToString:nowId]) nowP = p;
            else if (doneLike[pid]) [doneP addObject:p];
            else if ([dupeDrop containsObject:pid]) [dupeP addObject:p];
            else if ([kinds[pid] isEqualToString:@"work"]) [workP addObject:p];
            else [rest addObject:p];
        }
        if (nowP) pendRow(nowP, [NSString stringWithFormat:@"▶ Do this now%@%@",
                                 nowWhy.length ? @" — " : @"", nowWhy], accent, YES);
        // Tidy-up suggestions (looks done, duplicates) are Gari's housekeeping — collapsed by default; you only see what awaits a decision
        if (doneP.count + dupeP.count) {
            if (self.showSuggestions) {
                for (NSDictionary *p in doneP)
                    pendRow(p, [NSString stringWithFormat:@"Looks done · %@", doneLike[p[@"id"]]],
                            [NSColor systemGreenColor], NO);
                for (NSDictionary *p in dupeP) pendRow(p, @"Duplicate — safe to fold", nil, NO);
            }
            NSButton *sg = [NSButton buttonWithTitle:
                self.showSuggestions ? @"Hide tidy-up suggestions ▾"
                    : [NSString stringWithFormat:@"Gari's tidy-up suggestions: %lu ▸ (looks done / duplicates — just confirm)",
                       doneP.count + dupeP.count]
                target:self action:@selector(toggleSuggestions:)];
            sg.bordered = NO;
            sg.controlSize = NSControlSizeSmall;
            sg.font = [NSFont systemFontOfSize:11.5];
            sg.contentTintColor = [NSColor systemGreenColor];
            sg.alignment = NSTextAlignmentLeft;
            sg.frame = NSMakeRect(pad, y, contentW, 24);
            [doc addSubview:sg];
            y += 30;
        }

        // Sign-off — answering in the input box records it
        for (NSString *a in approvals) {
            NSArray *parts = [a componentsSeparatedByString:@" — "];
            NSTextField *t = hudLabel(parts[0],
                [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], fg, 0, contentW - 46);
            NSTextField *sub2 = hudLabel(parts.count > 1
                    ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" — "]
                    : @"Sign-off — answer in the box below and it gets recorded",
                [NSFont systemFontOfSize:10.5], dim, 2, contentW - 46);
            CGFloat rh = 11 + t.frame.size.height + 3 + sub2.frame.size.height + 11;
            NSView *row = hudRowCard(contentW);
            row.frame = NSMakeRect(pad, y, contentW, rh);
            NSTextField *mark = hudLabel(@"◇", [NSFont systemFontOfSize:12], accent, 1, 20);
            mark.frame = NSMakeRect(13, rh - 12 - mark.frame.size.height + 1, 20, mark.frame.size.height);
            [row addSubview:mark];
            t.frame = NSMakeRect(34, rh - 11 - t.frame.size.height, contentW - 46, t.frame.size.height);
            [row addSubview:t];
            sub2.frame = NSMakeRect(34, 10, contentW - 46, sub2.frame.size.height);
            [row addSubview:sub2];
            [doc addSubview:row];
            y += rh + 8;
        }

        // Grading — right / misfire
        for (NSDictionary *s in shadowItems) {
            NSTextField *t = hudLabel(s[@"text"], [NSFont systemFontOfSize:12.5], fg, 0, contentW - 150);
            NSTextField *sub2 = hudLabel(@"Coach grading", [NSFont systemFontOfSize:10.5], dim, 1, contentW - 150);
            CGFloat rh = 11 + t.frame.size.height + 3 + sub2.frame.size.height + 11;
            NSView *row = hudRowCard(contentW);
            row.frame = NSMakeRect(pad, y, contentW, rh);
            t.frame = NSMakeRect(14, rh - 11 - t.frame.size.height, contentW - 150, t.frame.size.height);
            [row addSubview:t];
            sub2.frame = NSMakeRect(14, 10, contentW - 150, sub2.frame.size.height);
            [row addSubview:sub2];
            NSButton *ok = flatBtn(@"Right", [NSColor systemGreenColor], self, @selector(gradeShadow:));
            ok.identifier = [NSString stringWithFormat:@"%@|right", s[@"id"]];
            ok.frame = NSMakeRect(contentW - 126, (rh - 23) / 2, 54, 23);
            [row addSubview:ok];
            NSButton *no = flatBtn(@"Misfire", dim, self, @selector(gradeShadow:));
            no.identifier = [NSString stringWithFormat:@"%@|wrong", s[@"id"]];
            no.frame = NSMakeRect(contentW - 66, (rh - 23) / 2, 54, 23);
            [row addSubview:no];
            [doc addSubview:row];
            y += rh + 8;
        }

        // Work-level — the agent's job, not yours (collapsed by default)
        if (workP.count) {
            if (self.showWorkItems) {
                for (NSDictionary *p in workP) pendRow(p, @"Work — can be delegated", nil, NO);
            }
            NSButton *wk = [NSButton buttonWithTitle:
                self.showWorkItems ? @"Hide work queue ▾"
                    : [NSString stringWithFormat:@"Work queue: %lu ▸ (build / verify — delegate from chat)",
                       workP.count]
                target:self action:@selector(toggleWorkItems:)];
            wk.bordered = NO;
            wk.controlSize = NSControlSizeSmall;
            wk.font = [NSFont systemFontOfSize:11.5];
            wk.contentTintColor = dim;
            wk.alignment = NSTextAlignmentLeft;
            wk.frame = NSMakeRect(pad, y, contentW, 24);
            [doc addSubview:wk];
            y += 30;
        }

        // Other pendings — collapsed by default
        if (rest.count) {
            if (self.showAllPendings) {
                for (NSDictionary *p in rest) pendRow(p, @"", nil, NO);
            }
            NSButton *toggle = [NSButton buttonWithTitle:
                self.showAllPendings ? @"Collapse ▾"
                    : [NSString stringWithFormat:@"Other pendings: %lu ▸", rest.count]
                target:self action:@selector(toggleAllPendings:)];
            toggle.bordered = NO;
            toggle.controlSize = NSControlSizeSmall;
            toggle.font = [NSFont systemFontOfSize:11.5];
            toggle.contentTintColor = dim;
            toggle.alignment = NSTextAlignmentLeft;
            toggle.frame = NSMakeRect(pad, y, 200, 24);
            [doc addSubview:toggle];
            y += 30;
        }
        y += 14;
    }

    // ═══ Group 3: today's log — a one-line summary, expand for details
    NSArray *decs = d[@"decisions"], *cors = d[@"corrections"], *wins = d[@"wins"];
    NSUInteger recTotal = decs.count + cors.count + wins.count;
    if (recTotal) {
        NSButton *rec = [NSButton buttonWithTitle:
            [NSString stringWithFormat:@"Today: %lu decisions · %lu corrections · %lu wins %@",
             decs.count, cors.count, wins.count, self.showRecords ? @"▾" : @"▸"]
            target:self action:@selector(toggleRecords:)];
        rec.bordered = NO;
        rec.controlSize = NSControlSizeSmall;
        rec.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
        rec.contentTintColor = dim;
        rec.alignment = NSTextAlignmentLeft;
        rec.frame = NSMakeRect(pad, y, contentW, 24);
        [doc addSubview:rec];
        y += 30;
        if (self.showRecords) {
            void (^recs)(NSArray *, NSString *, NSColor *) = ^(NSArray *items, NSString *bullet, NSColor *bc) {
                NSUInteger shown = MIN(items.count, 4u);
                for (NSUInteger i = 0; i < shown; i++) {
                    NSTextField *b = hudLabel(bullet, [NSFont systemFontOfSize:12.5], bc, 1, 16);
                    b.frame = NSMakeRect(pad, y, 16, b.frame.size.height);
                    [doc addSubview:b];
                    NSTextField *t = hudLabel(items[i][@"text"], [NSFont systemFontOfSize:12.5],
                        [NSColor colorWithCalibratedWhite:0.80 alpha:1], 2, contentW - 20);
                    t.frame = NSMakeRect(pad + 18, y, contentW - 20, t.frame.size.height);
                    [doc addSubview:t];
                    y += t.frame.size.height + 7;
                }
                if (items.count > shown) {
                    NSTextField *more = hudLabel([NSString stringWithFormat:@"+%lu more", items.count - shown],
                                                 [NSFont systemFontOfSize:11], dim, 1, contentW);
                    more.frame = NSMakeRect(pad + 18, y, contentW, more.frame.size.height);
                    [doc addSubview:more];
                    y += more.frame.size.height + 7;
                }
            };
            recs(decs, @"·", dim);
            recs(cors, @"↺", accent);
            recs(wins, @"▲", [NSColor systemGreenColor]);
        }
        y += 8;
    }

    }   // end of the details gate

    doc.frame = NSMakeRect(0, 0, W, y + 12);
    CGFloat dashOldY = self.hudScroll.contentView.bounds.origin.y;
    self.hudScroll.documentView = doc;
    [doc scrollPoint:NSMakePoint(0, MIN(dashOldY,
        MAX(0, y + 12 - self.hudScroll.frame.size.height)))];   // keep the reading position when a toggle expands
}

- (void)buildChat {
    CGFloat W = self.hudScroll.frame.size.width;
    CGFloat pad = 22, contentW = W - pad * 2;   // left/right symmetric (scrollbar auto-hides)
    FlippedView *doc = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, 10)];
    __block CGFloat y = 14;
    NSColor *fg = [NSColor colorWithCalibratedWhite:0.94 alpha:1];
    NSColor *dim = [NSColor colorWithCalibratedWhite:0.52 alpha:1];
    NSColor *accent = [NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.10 alpha:1];
    NSDictionary *chat = self.hudData[@"chat"];

    // Session bar: current session (flat button, opens a dark menu) + New chat
    NSArray *sessions = [chat[@"sessions"] isKindOfClass:NSArray.class] ? chat[@"sessions"] : @[];
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    NSString *cur = chat[@"session"] ?: @"";
    for (NSDictionary *s in sessions) {
        [ids addObject:s[@"id"] ?: @""];
        [titles addObject:s[@"title"] ?: @"chat"];
    }
    self.chatSessionIds = ids;
    self.chatSessionTitles = titles;
    self.chatCurrentSid = cur;
    NSString *curTitle = chat[@"title"] ?: @"New chat";
    if (curTitle.length > 26) curTitle = [[curTitle substringToIndex:26] stringByAppendingString:@"…"];
    NSButton *sess = [NSButton buttonWithTitle:
        [NSString stringWithFormat:@"%@  ▾", curTitle] target:self action:@selector(showSessionMenu:)];
    sess.bordered = NO;
    sess.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    sess.contentTintColor = [NSColor colorWithCalibratedWhite:0.62 alpha:1];
    sess.alignment = NSTextAlignmentLeft;
    sess.frame = NSMakeRect(pad - 4, y, contentW - 84, 24);
    [doc addSubview:sess];
    NSButton *nb = flatBtn(@"New chat", accent, self, @selector(chatNew:));
    nb.frame = NSMakeRect(pad + contentW - 72, y, 72, 24);
    [doc addSubview:nb];
    y += 34;

    // bubble thread
    NSArray *thread = [chat[@"thread"] isKindOfClass:NSArray.class] ? chat[@"thread"] : @[];
    void (^bubble)(NSString *, BOOL) = ^(NSString *rawText, BOOL mine) {
        if (!rawText.length) return;
        CGFloat maxW = contentW * 0.82;
        // extract local images: ![..](path) / [ATTACH: path]
        NSMutableArray *imgPaths = [NSMutableArray array];
        NSString *text = rawText;
        for (NSString *pat in @[@"!\\[[^\\]]*\\]\\(([^)]+)\\)", @"\\[(?:ATTACH|첨부):\\s*([^\\]]+)\\]"]) {
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
            for (NSTextCheckingResult *m in [re matchesInString:text options:0
                                                           range:NSMakeRange(0, text.length)]) {
                NSString *pth = [[text substringWithRange:[m rangeAtIndex:1]]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                pth = pth.stringByExpandingTildeInPath;
                if ([NSFileManager.defaultManager fileExistsAtPath:pth]) [imgPaths addObject:pth];
            }
            text = [re stringByReplacingMatchesInString:text options:0
                                                  range:NSMakeRange(0, text.length) withTemplate:@""];
        }
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        void (^imgBubbles)(void) = ^{
            for (NSString *pth in imgPaths) {
                NSImage *im = [[NSImage alloc] initWithContentsOfFile:pth];
                if (!im) continue;
                CGFloat iw = MIN(maxW * 0.85, im.size.width);
                CGFloat ih = im.size.height * (iw / MAX(1, im.size.width));
                ih = MIN(ih, 260);
                iw = im.size.width * (ih / MAX(1, im.size.height));
                NSImageView *iv = [NSImageView imageViewWithImage:im];
                iv.imageScaling = NSImageScaleProportionallyUpOrDown;
                iv.wantsLayer = YES;
                iv.layer.cornerRadius = 10;
                iv.layer.masksToBounds = YES;
                iv.frame = NSMakeRect(mine ? pad + contentW - iw : pad, y, iw, ih);
                [doc addSubview:iv];
                y += ih + 7;
            }
        };
        if (!text.length) { imgBubbles(); return; }   // image-only message
        NSTextView *l = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, maxW - 32, 10)];
        l.editable = NO;
        l.selectable = YES;                    // links clickable, text copyable
        l.drawsBackground = NO;
        l.textContainerInset = NSZeroSize;
        l.textContainer.lineFragmentPadding = 0;
        l.textContainer.widthTracksTextView = NO;
        l.textContainer.containerSize = NSMakeSize(maxW - 32, CGFLOAT_MAX);
        l.linkTextAttributes = @{                // drop the forced blue — use the palette's orange
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:0.62 blue:0.30 alpha:1],
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
            NSCursorAttributeName: NSCursor.pointingHandCursor};
        [l.textStorage setAttributedString:mdRender(text, 14,
            mine ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.98] : fg)];
        (void)[l.layoutManager glyphRangeForTextContainer:l.textContainer];   // force full layout even for long answers
        NSRect used = [l.layoutManager usedRectForTextContainer:l.textContainer];
        CGFloat tw = MIN(maxW - 32, ceil(used.size.width) + 2);   // the bubble is only as wide as what was said
        l.textContainer.containerSize = NSMakeSize(tw, CGFLOAT_MAX);
        (void)[l.layoutManager glyphRangeForTextContainer:l.textContainer];
        used = [l.layoutManager usedRectForTextContainer:l.textContainer];
        CGFloat lh = ceil(used.size.height);
        if (getenv("GARI_DEBUG_MEASURE"))
            fprintf(stderr, "[measure] chars=%lu tw=%.0f lh=%.0f\n",
                    (unsigned long)text.length, tw, lh);
        l.frame = NSMakeRect(0, 0, tw, lh + 2);
        CGFloat bw = tw + 32;
        CGFloat bh = l.frame.size.height + 24;
        NSView *b = [[NSView alloc] initWithFrame:
            NSMakeRect(mine ? pad + contentW - bw : pad, y, bw, bh)];
        b.wantsLayer = YES;
        b.layer.cornerRadius = 13;
        b.layer.backgroundColor = mine
            ? [accent colorWithAlphaComponent:0.88].CGColor
            : [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;
        l.frame = NSMakeRect(16, 12, tw, l.frame.size.height);
        [b addSubview:l];
        [doc addSubview:b];
        y += bh + 7;
        imgBubbles();
    };
    if (!thread.count && !self.asking) {
        NSTextField *empty = hudLabel(@"Ask me anything — memory, docs, general knowledge, or hand me a task.",
                                      [NSFont systemFontOfSize:12], dim, 2, contentW);
        empty.frame = NSMakeRect(pad, y + 6, contentW, empty.frame.size.height);
        [doc addSubview:empty];
        y += empty.frame.size.height + 14;
    }
    NSView *lastAnswer = nil;
    for (NSDictionary *t in thread) {
        bubble(t[@"q"], YES);
        bubble(t[@"a"], NO);
        lastAnswer = doc.subviews.lastObject;
        if ([t[@"ts"] length]) {   // Q&A time — small, under the answer
            NSTextField *tm = hudLabel(t[@"ts"], [NSFont systemFontOfSize:9.5],
                [NSColor colorWithCalibratedWhite:0.40 alpha:1], 1, 60);
            tm.frame = NSMakeRect(pad + 4, y - 3, 60, tm.frame.size.height);
            [doc addSubview:tm];
            y += tm.frame.size.height + 10;
        }
    }
    // fade in when a new answer arrives (only when the thread grew)
    if (!self.asking && (NSInteger)thread.count > self.lastThreadCount && lastAnswer) {
        lastAnswer.alphaValue = 0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.3;
            lastAnswer.animator.alphaValue = 1;
        }];
        [self.hudWindow makeFirstResponder:self.hudInput];   // the answer is here, so you can keep typing right away
    }
    self.lastThreadCount = (NSInteger)thread.count;
    if (self.asking) {
        bubble(self.lastQ, YES);
        NSString *st = [NSString stringWithContentsOfFile:
            [GariStateReader gariPath:@"store/ask-status.txt"]
            encoding:NSUTF8StringEncoding error:nil];
        st = [st stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!st.length) st = @"Thinking…";
        NSTextField *sl = hudLabel(st, [NSFont systemFontOfSize:12], dim, 2, contentW * 0.82 - 52);
        CGFloat sw = MIN(contentW * 0.82 - 52, ceil([sl.cell cellSizeForBounds:
            NSMakeRect(0, 0, contentW * 0.82 - 52, 200)].width) + 2);
        sl.frame = NSMakeRect(0, 0, sw, sl.frame.size.height);
        CGFloat bh = MAX(sl.frame.size.height + 20, 36);
        NSView *b = [[NSView alloc] initWithFrame:NSMakeRect(pad, y, sw + 54, bh)];
        b.wantsLayer = YES;
        b.layer.cornerRadius = 13;
        b.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.06].CGColor;
        NSProgressIndicator *sp = [[NSProgressIndicator alloc]
            initWithFrame:NSMakeRect(14, (bh - 14) / 2, 14, 14)];
        sp.style = NSProgressIndicatorStyleSpinning;
        sp.controlSize = NSControlSizeSmall;
        sp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
        [sp startAnimation:nil];
        [b addSubview:sp];
        sl.frame = NSMakeRect(38, (bh - sl.frame.size.height) / 2, sw, sl.frame.size.height);
        [b addSubview:sl];
        [doc addSubview:b];
        y += bh + 7;
    }

    doc.frame = NSMakeRect(0, 0, W, y + 12);
    NSView *oldDoc = self.hudScroll.documentView;
    CGFloat oldY = self.hudScroll.contentView.bounds.origin.y;
    CGFloat viewH = self.hudScroll.frame.size.height;
    BOOL nearBottom = !oldDoc
        || oldDoc.frame.size.height <= viewH
        || (oldDoc.frame.size.height - (oldY + viewH)) < 80;
    self.hudScroll.documentView = doc;
    if (nearBottom) {
        [doc scrollPoint:NSMakePoint(0, MAX(0, y + 12 - viewH))];   // stay at the bottom (follow new messages)
    } else {
        [doc scrollPoint:NSMakePoint(0, MIN(oldY, MAX(0, y + 12 - viewH)))];  // keep the reading position
    }
}

- (void)showSessionMenu:(NSButton *)btn {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    for (NSUInteger i = 0; i < self.chatSessionIds.count; i++) {
        NSString *t = self.chatSessionTitles[i];
        if (t.length > 40) t = [[t substringToIndex:40] stringByAppendingString:@"…"];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t
            action:@selector(chatSessionMenuPicked:) keyEquivalent:@""];
        it.target = self;
        it.tag = (NSInteger)i;
        if ([self.chatSessionIds[i] isEqualToString:self.chatCurrentSid])
            it.state = NSControlStateValueOn;
        [menu addItem:it];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *fresh = [[NSMenuItem alloc] initWithTitle:@"Start a new chat"
        action:@selector(chatNew:) keyEquivalent:@""];
    fresh.target = self;
    [menu addItem:fresh];
    [menu popUpMenuPositioningItem:nil
        atLocation:NSMakePoint(0, btn.bounds.size.height + 4) inView:btn];
}

- (void)chatSessionMenuPicked:(NSMenuItem *)item {
    NSInteger i = item.tag;
    if (i < 0 || i >= (NSInteger)self.chatSessionIds.count) return;
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"chat", @"use", self.chatSessionIds[i]];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; } @catch (NSException *ex) {}
}

- (void)chatNew:(id)sender {
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"chat", @"new"];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; } @catch (NSException *ex) {}
}

- (void)openHud {
    self.hopV = 3.5;   // you called — a happy greeting

    // mark as read (the dashboard carries the report, so opening it clears the badge)
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd";
    [NSFileManager.defaultManager createFileAtPath:
        [GariStateReader gariPath:[NSString stringWithFormat:@"pet/seen-%@",
                                   [df stringFromDate:NSDate.date]]]
        contents:nil attributes:nil];

    CGFloat W = 400, H = 500;
    if (!self.hudWindow) {
        // restore the saved size (resizable by dragging, remembered afterwards)
        NSData *sd = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/hud-size.json"]];
        if (sd) {
            NSDictionary *sj = [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil];
            if ([sj[@"w"] doubleValue] >= 380) W = [sj[@"w"] doubleValue];
            if ([sj[@"h"] doubleValue] >= 430) H = [sj[@"h"] doubleValue];
        }
        self.hudWindow = [[KeyableWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, W, H)
            styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable)
            backing:NSBackingStoreBuffered defer:NO];
        self.hudWindow.minSize = NSMakeSize(380, 430);
        self.hudWindow.movableByWindowBackground = YES;   // drag empty space to move the panel
        self.hudWindow.maxSize = NSMakeSize(1000, NSScreen.mainScreen.visibleFrame.size.height);
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidEndLiveResizeNotification
            object:self.hudWindow queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            [self hudResizeEnded];
        }];
        self.hudWindow.opaque = NO;
        self.hudWindow.backgroundColor = NSColor.clearColor;
        self.hudWindow.level = NSFloatingWindowLevel;
        self.hudWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                          | NSWindowCollectionBehaviorStationary
                                          | NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.hudWindow.hasShadow = YES;
        self.hudWindow.contentView = [self makeHudCard:NSMakeSize(W, H)];
        [self wireGrip];
        // popover standard: clicking outside = close
        [NSEvent addGlobalMonitorForEventsMatchingMask:
            NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
            handler:^(NSEvent *ev) {
                if (self.hudWindow.isVisible) [self.hudWindow orderOut:nil];
            }];
    }

    // position: prefer left of the pet, right if there's no room — clamped to the screen
    NSRect pet = self.window.frame;
    NSRect screen = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat x = pet.origin.x - W - 12;
    if (x < NSMinX(screen)) x = NSMaxX(pet) + 12;
    if (x + W > NSMaxX(screen)) x = NSMaxX(screen) - W - 8;
    CGFloat y = MAX(NSMinY(screen) + 8, MIN(pet.origin.y, NSMaxY(screen) - H - 8));
    [self.hudWindow setFrameOrigin:NSMakePoint(x, y)];

    [self buildHud];
    // type immediately on summon (Spotlight/Raycast convention) — you opened it on purpose, so take focus
    [NSApp activateIgnoringOtherApps:YES];
    [self.hudWindow makeKeyAndOrderFront:nil];
    [self.hudWindow makeFirstResponder:self.hudInput];
    [self fetchHud];
}

// content is assembled by gari hud (the engine is the single source of truth — the pet only displays)
- (void)fetchHud {
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"hud", @"--json"];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
        NSDictionary *json = d.length
            ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.hudData = [json isKindOfClass:NSDictionary.class] ? json : nil;
            [weakSelf buildHud];
            [weakSelf refresh];
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) {
        self.hudData = nil;
        [self buildHud];
    }
}

// shadow grading buttons — gari grade <ID> right|wrong
- (void)gradeShadow:(NSButton *)btn {
    NSArray *parts = [btn.identifier componentsSeparatedByString:@"|"];
    if (parts.count != 2) return;
    btn.enabled = NO;
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"grade", parts[0], parts[1]];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.2];  // a thank-you for grading
            [weakSelf fetchHud];
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { [self fetchHud]; }
}

- (void)toggleAllPendings:(id)s { self.showAllPendings = !self.showAllPendings; [self buildHud]; }
- (void)toggleRecords:(id)s { self.showRecords = !self.showRecords; [self buildHud]; }
- (void)toggleSuggestions:(id)s { self.showSuggestions = !self.showSuggestions; [self buildHud]; }
- (void)toggleWorkItems:(id)s { self.showWorkItems = !self.showWorkItems; [self buildHud]; }

- (void)compassRowTapped:(NSClickGestureRecognizer *)g {
    NSString *proj = g.view.identifier;
    if (!proj.length || self.asking) return;
    [self.hudInput setString:[NSString stringWithFormat:
        @"Where is the %@ project heading right now? What needs deciding next?", proj]];
    [self hudAsk:nil];
}

- (void)pendingRowTapped:(NSClickGestureRecognizer *)g {
    NSString *pid = g.view.identifier;
    if (!pid.length || self.asking) return;
    [self.hudInput setString:[NSString stringWithFormat:
        @"Pending card %@ — what context did this come from, and is it still valid?", pid]];
    [self hudAsk:nil];
}

- (void)snoozePending:(NSButton *)btn {
    if (!btn.identifier.length) return;
    btn.enabled = NO;
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"snooze", btn.identifier];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; } @catch (NSException *ex) { btn.enabled = YES; }
}

// "Done" button on a pending row — runs gari resolve, then refreshes
- (void)resolvePending:(NSButton *)btn {
    if (btn.identifier.length == 0) return;
    btn.enabled = NO;
    btn.title = @"…";
    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"resolve", btn.identifier];
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf fetchHud]; });
    };
    @try { [t launch]; }
    @catch (NSException *ex) { [self fetchHud]; }
}

// submit the panel question box (Enter)
- (void)hudAsk:(id)sender {
    NSString *q = [self.hudInput.string stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0 || self.asking) return;
    self.lastQ = q;
    self.lastA = @"";
    self.asking = YES;
    self.hudMode = 1;   // asking switches to the chat tab
    [self buildHud];
    NSView *sd = self.hudScroll.documentView;   // send = jump to the bottom where my bubble is
    [sd scrollPoint:NSMakePoint(0, MAX(0, sd.frame.size.height - self.hudScroll.frame.size.height))];
    [self.askTimer invalidate];
    self.lastAskStatus = @"";
    self.askTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
        NSString *st = [NSString stringWithContentsOfFile:
            [GariStateReader gariPath:@"store/ask-status.txt"]
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        st = [st stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![st isEqualToString:self.lastAskStatus]) {
            self.lastAskStatus = st;
            if (self.asking && self.hudWindow.isVisible && self.hudMode == 1) [self buildChat];
        }
    }];
    [self.hudInput setString:@""];   // don't lock — lock/unlock round-trips tangle focus
    [self textDidChange:nil];
    [self buildHud];

    NSTask *t = [NSTask new];
    t.launchPath = [GariStateReader gariPath:@"bin/gari"];
    t.arguments = @[@"ask", q];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    __weak typeof(self) weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.asking = NO;
            [weakSelf.askTimer invalidate];
            weakSelf.askTimer = nil;
            weakSelf.lastQ = nil;   // the thread (ledger) is now the truth — drop the optimistic bubble
            weakSelf.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.5];
            weakSelf.hopV = 6.0;   // got your answer — hop
            [weakSelf fetchHud];
            [weakSelf.hudWindow makeFirstResponder:weakSelf.hudInput];
        });
    };
    @try { [t launch]; }
    @catch (NSException *ex) {
        self.asking = NO;
        self.lastA = @"Couldn't reach Gari — check GARI_HOME/bin/gari";
        [self buildHud];
    }
}

// ask Gari — focus the panel question box (no system alert)
- (void)askGari {
    if (!(self.hudWindow && self.hudWindow.isVisible)) [self openHud];
    [NSApp activateIgnoringOtherApps:YES];
    [self.hudWindow makeKeyAndOrderFront:nil];
    [self.hudWindow makeFirstResponder:self.hudInput];
}

- (void)petColorPicked:(NSMenuItem *)item {
    NSString *hex = item.representedObject;
    NSString *path = [GariStateReader gariPath:@"pet/pet-config.json"];
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *pc = d
        ? [[NSJSONSerialization JSONObjectWithData:d options:0 error:nil] mutableCopy] : nil;
    if (!pc) pc = [NSMutableDictionary dictionary];
    if ([hex isEqualToString:@"#FF6600"]) {
        [pc removeObjectForKey:@"body_color"];   // default color = remove the setting
    } else {
        pc[@"body_color"] = hex;
    }
    [pc removeObjectForKey:@"shade_color"];
    [pc removeObjectForKey:@"belly_color"];
    [[NSJSONSerialization dataWithJSONObject:pc options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:path atomically:YES];
    initPalette(pc);                              // change outfits immediately
    self.needsDisplay = YES;
    self.happyUntil = [NSDate dateWithTimeIntervalSinceNow:1.5];   // new-outfit mood
    self.hopV = 4.0;
}

- (void)rightMouseDown:(NSEvent *)e {
    NSMenu *m = [[NSMenu alloc] init];
    [[m addItemWithTitle:@"Dashboard (click)" action:@selector(toggleHud) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Ask Gari…" action:@selector(askGari) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Open report file" action:@selector(openReport) keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"Check status (gari status)" action:@selector(openStatus) keyEquivalent:@""] setTarget:self];
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *colorRoot = [[NSMenuItem alloc] initWithTitle:@"Color" action:nil keyEquivalent:@""];
    NSMenu *colorMenu = [[NSMenu alloc] init];
    NSData *pcData = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/pet-config.json"]];
    NSDictionary *pc = pcData ? ([NSJSONSerialization JSONObjectWithData:pcData options:0 error:nil] ?: @{}) : @{};
    NSString *curHex = [pc[@"body_color"] isKindOfClass:NSString.class]
        ? [pc[@"body_color"] uppercaseString] : @"#FF6600";
    NSArray *presets = @[
        @[@"Garibaldi orange", @"#FF6600"], @[@"Coral", @"#FF6B81"],
        @[@"Gold", @"#FFB300"], @[@"Mint", @"#2EC4B6"],
        @[@"Sky", @"#3A86FF"], @[@"Lavender", @"#8E7CFF"],
        @[@"Silver", @"#B8B8BE"]];
    for (NSArray *pr in presets) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:pr[0]
            action:@selector(petColorPicked:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = pr[1];
        NSImage *sw = [NSImage imageWithSize:NSMakeSize(14, 14) flipped:NO
            drawingHandler:^BOOL(NSRect r) {
            [hexColor(pr[1], NSColor.grayColor) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1)
                                             xRadius:4 yRadius:4] fill];
            return YES;
        }];
        it.image = sw;
        if ([[pr[1] uppercaseString] isEqualToString:curHex])
            it.state = NSControlStateValueOn;
        [colorMenu addItem:it];
    }
    colorRoot.submenu = colorMenu;
    [m addItem:colorRoot];
    [[m addItemWithTitle:@"Hide for an hour" action:@selector(hideAnHour) keyEquivalent:@""] setTarget:self];
    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"Quit Gari pet (Gari keeps running)" action:@selector(quit) keyEquivalent:@""] setTarget:self];
    [NSMenu popUpContextMenu:m withEvent:e forView:self];
}

- (void)openReport {
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd";
    NSString *today = [df stringFromDate:NSDate.date];
    [NSFileManager.defaultManager createFileAtPath:
        [GariStateReader gariPath:[NSString stringWithFormat:@"pet/seen-%@", today]]
        contents:nil attributes:nil];
    NSString *report = [GariStateReader gariPath:[NSString stringWithFormat:@"reports/%@.md", today]];
    if (![NSFileManager.defaultManager fileExistsAtPath:report]) {
        NSArray *mds = [[NSFileManager.defaultManager
            contentsOfDirectoryAtPath:[GariStateReader gariPath:@"reports"] error:nil]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.md'"]];
        NSString *latest = [[mds sortedArrayUsingSelector:@selector(compare:)] lastObject];
        if (latest) report = [GariStateReader gariPath:[@"reports/" stringByAppendingString:latest]];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:report]];
    [self refresh];
}

- (void)openStatus {
    NSString *cmd = [NSString stringWithFormat:@"%@ status > %@ 2>&1; open -e %@",
        [GariStateReader gariPath:@"bin/gari"],
        [GariStateReader gariPath:@"pet/status-snapshot.txt"],
        [GariStateReader gariPath:@"pet/status-snapshot.txt"]];
    NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh"; t.arguments = @[@"-c", cmd];
    [t launch];
}

- (void)hideAnHour {
    [self.hudWindow orderOut:nil];
    [self.window orderOut:nil];
    // the #1 complaint about desktop pets = they get in the way. Step away for an hour instead of quitting.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3600 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.window orderFrontRegardless];
    });
}

- (void)quit { [NSApp terminate:nil]; }

- (void)refresh {
    GariMood m; int b;
    [GariStateReader read:&m badge:&b];
    if (m != self.mood) self.moodChangedAt = NSDate.date;
    self.mood = m; self.badge = b;
    if (self.asking && self.hudWindow.isVisible && self.hudMode == 1)
        [self buildChat];   // refresh the progress-stage text
    self.needsDisplay = YES;
}
@end

// ---------------------------------------------------------------- app assembly

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) PetView *view;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSSize size = NSMakeSize(150, 112);
    NSImage *sheet = nil;
    NSData *cd = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/pet-config.json"]];
    NSDictionary *petCfg = @{};
    if (cd) petCfg = [NSJSONSerialization JSONObjectWithData:cd options:0 error:nil] ?: @{};
    initPalette(petCfg);
    if (cd) {
        NSDictionary *cj = petCfg;
        NSString *sp = cj[@"spritesheet"];
        if ([sp isKindOfClass:NSString.class] && sp.length > 0) {
            sheet = [[NSImage alloc] initWithContentsOfFile:sp.stringByExpandingTildeInPath];
            if (!sheet) NSLog(@"GariPet: couldn't load the sprite sheet — using built-in pixels: %@", sp);
        }
    }
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    NSPoint origin = NSMakePoint(NSMaxX(screen) - size.width - 40, NSMinY(screen) + 60);
    NSData *pd = [NSData dataWithContentsOfFile:[GariStateReader gariPath:@"pet/position.json"]];
    if (pd) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil];
        if (j[@"x"] && j[@"y"]) {
            NSPoint saved = NSMakePoint([j[@"x"] doubleValue], [j[@"y"] doubleValue]);
            // check the saved position is actually visible in the current screen setup — if a monitor is gone, coordinates fall off-screen
            NSRect savedRect = NSMakeRect(saved.x, saved.y, size.width, size.height);
            for (NSScreen *s in NSScreen.screens) {
                if (NSIntersectsRect(savedRect, s.visibleFrame)) { origin = saved; break; }
            }
        }
    }
    self.window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(origin.x, origin.y, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.level = NSFloatingWindowLevel;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                   | NSWindowCollectionBehaviorStationary
                                   | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.window.hasShadow = NO;
    self.window.acceptsMouseMovedEvents = YES;

    self.view = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    self.view.sheet = sheet;
    self.window.contentView = self.view;
    [self.window orderFrontRegardless];
    [self.view refresh];

    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSRect f = self.window.frame;
        for (NSScreen *s in NSScreen.screens)
            if (NSIntersectsRect(f, s.visibleFrame)) return;   // still visible — leave it
        NSRect vis = NSScreen.mainScreen.visibleFrame;          // off-screen — return to the main screen's bottom-right
        [self.window setFrameOrigin:NSMakePoint(NSMaxX(vis) - f.size.width - 40, NSMinY(vis) + 60)];
        [self.window orderFrontRegardless];
    }];
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) { [self.view refresh]; }];
    [self chainTick];   // adaptive tick — slow while asleep (avoids constant high-frequency wakeups)
}

- (void)chainTick {
    [NSTimer scheduledTimerWithTimeInterval:[self.view desiredTickInterval]
                                    repeats:NO block:^(NSTimer *t) {
        [self.view animTick];
        [self chainTick];
    }];
}
@end

// ---------------------------------------------------------------- self-snapshot (for visual checks)

static void renderSnapshots(NSString *outDir) {
    [NSFileManager.defaultManager createDirectoryAtPath:outDir
        withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 150, 112)];
    struct { GariMood m; int badge; BOOL happy; const char *name; } shots[] = {
        {MoodSleep, 0, NO,  "sleep"}, {MoodAwake, 3, NO, "awake-badge"},
        {MoodWork,  0, NO,  "work"},  {MoodAlert, 0, NO, "alert"},
        {MoodAwake, 0, YES, "petting"},
    };
    for (int i = 0; i < 5; i++) {
        v.mood = shots[i].m; v.badge = shots[i].badge;
        v.breathPhase = 1.0; v.tick = 4;
        if (shots[i].happy) {
            v.happyUntil = [NSDate dateWithTimeIntervalSinceNow:5];
            v.bubbleOverride = @"Reporting for duty!";
            for (int k = 0; k < 4; k++) {
                Heart *h = [Heart new];
                h.x = 60 + k * 18; h.y = 95 + (k % 2) * 14; h.vy = 1; h.life = 0.9;
                [v.hearts addObject:h];
            }
        } else { v.happyUntil = nil; v.bubbleOverride = nil; [v.hearts removeAllObjects]; }
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:[outDir stringByAppendingFormat:@"/pet-%s.png", shots[i].name] atomically:YES];
    }
    // panel preview (for checking styles — sample data)
    v.mood = MoodAwake; v.badge = 0; v.happyUntil = nil; v.bubbleOverride = nil;
    NSView *card = [v makeHudCard:NSMakeSize(400, 500)];
    v.hudData = @{
        @"time": @"12:10",
        @"pipeline": @{@"ok": @YES, @"age_min": @5, @"cards_today": @41},
        @"next_step": @{@"action": @"Lock the search categories — enter 3 example queries",
                        @"reason": @"The last blocker for the memory search MVP — once it's done, memory moves to the finishing stage"},
        @"question": @"Enter the 3 example queries now, or batch them on Monday?",
        @"nag": @"This is the 5th round on the pet mockups and there's still no definition of 'good' — pin one reference first and the back-and-forth shrinks.",
        @"chat": @{@"session": @"9d89a816", @"title": @"Pet sound discussion",
                   @"sessions": @[@{@"id": @"9d89a816", @"title": @"Pet sound discussion"}],
                   @"thread": @[@{@"q": @"What does the D+1 log check mean?", @"a": @"It's a pending item about how the memory system reaches multiple sessions automatically.\n\nSituation: an index that classifies and links the memories (currently 404) is fed to project sessions automatically. The item means confirming from server logs that yesterday's 140 sessions actually received that index.\n\nWhy it matters: unless the injection is verified, the memories tidied so far may never be used in real conversations.\n\n«nudge — Why D+1 specifically? Are yesterday's/today's logs not enough, or is this measuring a delay effect?"},
                                @{@"q": @"When did I decide that?", @"a": @"![pet](docs/img/gari-pet.png)\n## When it was decided\nDecided on **2026-07-05, evening**.\n- To close it, run `gari resolve ab12cd34`\n- Reference: https://example.com/cards\n\n«nudge — There's no verification plan for this decision yet.", @"ts": @"22:40"}]},
        @"shadow": @[@{@"id": @"f1e9e032", @"text": @"Repeated instruction detected: pet size change asked 3 times", @"quote": @""}],
        @"approvals": @[@"Confirm the morning report time — currently 09:00 (config.json report_hour)"],
        @"pendings": @[@{@"idx": @0, @"project": @"gari", @"id": @"ab12cd34",
                         @"text": @"Decide the priority of the 5 retrieval layers (vector/keyword/SQL/graph/API)"},
                       @{@"idx": @1, @"project": @"gari", @"id": @"ef56ab78",
                         @"text": @"Waiting on the final look of the pet"},
                       @{@"idx": @2, @"project": @"roadmap", @"id": @"cd90ef12",
                         @"text": @"Screen recording permission — only the user can do this"}],
        @"freshness": @{@"sweep_interval_min": @10, @"report_hour": @9,
                         @"morning_ts": @"2026-07-06T09:00:12", @"triage_ts": @"2026-07-06T09:00:44"},
        @"stakes": @{@"brief": @"One deploy approval is blocking everything today — I've tidied the rest.",
                     @"total": @126,
                     @"stakes": @[
            @{@"gain": @"Approve it and 105 tests ship to production", @"label": @"Approve the demo server deploy",
              @"action": @"resolve", @"id": @"ab12cd34"},
            @{@"gain": @"Answer it and Gari's memory search gets its axis", @"label": @"What do you usually search for?",
              @"action": @"input", @"id": @""},
            @{@"gain": @"Leave it and the side project drifts another week", @"label": @"Continue the open discussion",
              @"action": @"chat", @"id": @""}]},
        @"compass": @[@{@"project": @"demo-game", @"identity": @"A small mobile mining game for a game jam",
                        @"next": @"Check the jam's judging criteria and deadline — the only outside blocker", @"activity": @29},
                      @{@"project": @"review-board", @"identity": @"A creative review and collaboration board",
                        @"next": @"Decide the product positioning", @"activity": @10}],
        @"triage": @{@"ts": @"2026-07-06T09:00:44",
                     @"now": @{@"id": @"ab12cd34", @"why": @"the last memory-search MVP blocker"},
                     @"done_like": @[@{@"id": @"ef56ab78", @"evidence": @"look-confirmed card today at 16:31"}],
                     @"dupes": @[], @"snooze": @[]},
        @"decisions": @[@{@"project": @"gari", @"text": @"Gari's pet is a Garibaldi fish — solid color + eyes only"},
                        @{@"project": @"gari", @"text": @"Put a question box inside the panel"}],
        @"corrections": @[@{@"text": @"Improve dashboard readability — to shipping quality"}],
        @"wins": @[@{@"text": @"9.5 of 10 usability checklist items met"}],
    };
    [v buildHud];   // top state (no Q&A)
    NSBitmapImageRep *prep = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:prep];
    [[prep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[outDir stringByAppendingString:@"/panel-top.png"] atomically:YES];
    [v.hudScroll.documentView scrollPoint:NSMakePoint(0, 560)];
    NSBitmapImageRep *prep3 = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:prep3];
    [[prep3 representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[outDir stringByAppendingString:@"/panel-pendings.png"] atomically:YES];

    v.hudMode = 1;
    v.asking = YES;
    v.lastQ = @"What were the 6 judging criteria in the north star?";
    [v buildHud];   // chat tab + in-progress state
    NSBitmapImageRep *prep2 = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:prep2];
    [[prep2 representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[outDir stringByAppendingString:@"/panel-chat.png"] atomically:YES];
    printf("Saved 6 snapshots: %s\n", outDir.UTF8String);
}

static void renderIcon(NSString *outPath) {
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 150, 112)];
    v.mood = MoodAwake; v.badge = 0; v.breathPhase = 1.0; v.tick = 4;
    CGFloat S = 6.5;   // the fish (~65x50pt) fills the 512 canvas
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:512 pixelsHigh:512 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    NSAffineTransform *tf = [NSAffineTransform transform];
    // center the fish, not the view, on the canvas: fish center ≈ view coords (75, 45)
    [tf translateXBy:256 - 75 * S yBy:256 - 45 * S];
    [tf scaleBy:S];
    [tf concat];
    [v drawRect:v.bounds];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:outPath atomically:YES];
    printf("Saved icon master: %s\n", outPath.UTF8String);
}

int main(int argc, const char *argv[]) {
    // single-instance lock — whichever door opens it (CLI, Gari.app, launchd), there's only one pet
    // (the system adds hidden arguments when launching the app, so decide by "utility mode", not by whether args exist)
    BOOL utility = (argc >= 2 && (strcmp(argv[1], "--icon") == 0 ||
                                  strcmp(argv[1], "--measure") == 0 ||
                                  strcmp(argv[1], "--snapshot") == 0));
    if (!utility) {
        NSString *lockPath = [GariStateReader gariPath:@"pet/instance.lock"];
        int lockFd = open(lockPath.UTF8String, O_CREAT | O_RDWR, 0644);
        if (lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
            return 0;   // already running (or can't lock) — exit quietly
        }
        // lockFd is intentionally kept open — the OS releases the lock when the process exits
    }
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--icon") == 0) {
            [NSApplication sharedApplication];
            initPalette(@{});
            renderIcon([NSString stringWithUTF8String:argv[2]]);
            return 0;
        }
        if (argc >= 3 && strcmp(argv[1], "--measure") == 0) {
            [NSApplication sharedApplication];
            initPalette(@{});
            NSString *body = [NSString stringWithContentsOfFile:
                [NSString stringWithUTF8String:argv[2]]
                encoding:NSUTF8StringEncoding error:nil] ?: @"(no file)";
            PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 150, 112)];
            NSView *card = [v makeHudCard:NSMakeSize(400, 500)];
            (void)card;
            v.hudData = @{@"chat": @{@"session": @"m", @"title": @"measure",
                                     @"sessions": @[],
                                     @"thread": @[@{@"q": @"measurement question", @"a": body, @"ts": @"00:00"}]}};
            v.hudMode = 1;
            [v buildHud];
            NSView *doc = v.hudScroll.documentView;
            fprintf(stderr, "[doc] height=%.0f (input %lu chars)\n",
                    doc.frame.size.height, (unsigned long)body.length);
            for (NSView *sub in doc.subviews)
                if (sub.frame.size.height > 100)
                    fprintf(stderr, "[bubble] h=%.0f innerViewH=%.0f\n",
                            sub.frame.size.height,
                            sub.subviews.firstObject.frame.size.height);
            return 0;
        }
        if (argc >= 3 && strcmp(argv[1], "--snapshot") == 0) {
            initPalette(@{});
            [NSApplication sharedApplication];
            renderSnapshots([NSString stringWithUTF8String:argv[2]]);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
