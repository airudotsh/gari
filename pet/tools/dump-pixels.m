// dump-pixels — dump a PNG's pixels as text (for porting a sprite onto Gari's grid)
// Build: clang -fobjc-arc -framework Cocoa -O2 -o dump-pixels dump-pixels.m
// Usage: ./dump-pixels sprite.png [--crop x y w h]
// Output: line 1 = "W H", then each pixel as "RRGGBBAA" (row-major, space-separated)
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: dump-pixels file.png [--crop x y w h]\n"); return 1; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) { fprintf(stderr, "read failed: %s\n", argv[1]); return 1; }
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
        if (!rep) { fprintf(stderr, "couldn't decode bitmap\n"); return 1; }
        NSInteger x0 = 0, y0 = 0, w = rep.pixelsWide, h = rep.pixelsHigh;
        if (argc == 7 && strcmp(argv[2], "--crop") == 0) {
            x0 = atoi(argv[3]); y0 = atoi(argv[4]);
            w = atoi(argv[5]); h = atoi(argv[6]);
        }
        printf("%ld %ld\n", (long)w, (long)h);
        for (NSInteger y = y0; y < y0 + h; y++) {
            for (NSInteger x = x0; x < x0 + w; x++) {
                NSColor *c = [rep colorAtX:x y:y];
                c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                printf("%02X%02X%02X%02X ",
                       (int)(c.redComponent * 255), (int)(c.greenComponent * 255),
                       (int)(c.blueComponent * 255), (int)(c.alphaComponent * 255));
            }
            printf("\n");
        }
    }
    return 0;
}
