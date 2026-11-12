/*
 * hpscan - minimal macOS scan frontend for HPLIP's SANE "hpaio" backend.
 *
 * Loads libsane-hpaio.so directly (no sane-backends install needed), scans one
 * page from the first (or named) HP device and writes PNG, JPEG, TIFF or PDF
 * via ImageIO / CoreGraphics.
 *
 *   hpscan [-d device] [-r dpi] [-m Color|Gray|Lineart] [-L] [-b backend.so] out.{png,jpg,tiff,pdf}
 */
#include <dlfcn.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include "sane.h"
#include "saneopts.h"

#ifndef DEFAULT_BACKEND
#define DEFAULT_BACKEND "/Library/Printers/HPLIP/lib/libsane-hpaio.so"
#endif

typedef SANE_Status (*init_fn)(SANE_Int *, SANE_Auth_Callback);
typedef void (*exit_fn)(void);
typedef SANE_Status (*get_devices_fn)(const SANE_Device ***, SANE_Bool);
typedef SANE_Status (*open_fn)(SANE_String_Const, SANE_Handle *);
typedef void (*close_fn)(SANE_Handle);
typedef const SANE_Option_Descriptor *(*get_opt_fn)(SANE_Handle, SANE_Int);
typedef SANE_Status (*control_fn)(SANE_Handle, SANE_Int, SANE_Action, void *, SANE_Int *);
typedef SANE_Status (*params_fn)(SANE_Handle, SANE_Parameters *);
typedef SANE_Status (*start_fn)(SANE_Handle);
typedef SANE_Status (*read_fn)(SANE_Handle, SANE_Byte *, SANE_Int, SANE_Int *);
typedef void (*cancel_fn)(SANE_Handle);

static struct {
    init_fn init; exit_fn exit; get_devices_fn get_devices; open_fn open; close_fn close;
    get_opt_fn get_opt; control_fn control; params_fn params; start_fn start; read_fn read;
    cancel_fn cancel;
} be;

static void *sym(void *h, const char *name)
{
    char full[64];
    snprintf(full, sizeof full, "sane_hpaio_%s", name);
    void *p = dlsym(h, full);
    if (!p) { fprintf(stderr, "hpscan: backend lacks %s\n", full); exit(2); }
    return p;
}

static int find_option(SANE_Handle h, const char *name)
{
    SANE_Int n = 0;
    if (be.control(h, 0, SANE_ACTION_GET_VALUE, &n, NULL) != SANE_STATUS_GOOD) return -1;
    for (int i = 1; i < n; i++) {
        const SANE_Option_Descriptor *d = be.get_opt(h, i);
        if (d && d->name && strcmp(d->name, name) == 0) return i;
    }
    return -1;
}

/* Set an integer option, snapping to the nearest value the device lists
 * (HP's LEDM backend silently falls back to its minimum otherwise).
 * Returns the value the backend actually holds afterwards. */
static SANE_Int set_int(SANE_Handle h, const char *name, SANE_Int v)
{
    int o = find_option(h, name);
    if (o < 0) return v;
    const SANE_Option_Descriptor *d = be.get_opt(h, o);
    int fixed = d->type == SANE_TYPE_FIXED;
    SANE_Word w = fixed ? SANE_FIX(v) : v;
    if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST && d->constraint.word_list[0] > 0) {
        const SANE_Word *l = d->constraint.word_list;
        SANE_Word best = l[1];
        for (int i = 1; i <= l[0]; i++)
            if (labs((long)l[i] - w) < labs((long)best - w)) best = l[i];
        w = best;
    } else if (d->constraint_type == SANE_CONSTRAINT_RANGE) {
        if (w < d->constraint.range->min) w = d->constraint.range->min;
        if (w > d->constraint.range->max) w = d->constraint.range->max;
    }
    if (be.control(h, o, SANE_ACTION_SET_VALUE, &w, NULL) != SANE_STATUS_GOOD)
        fprintf(stderr, "hpscan: warning: could not set %s=%d\n", name, v);
    SANE_Word got = w;
    be.control(h, o, SANE_ACTION_GET_VALUE, &got, NULL);
    SANE_Int actual = fixed ? (SANE_Int)SANE_UNFIX(got) : got;
    if (actual != v)
        fprintf(stderr, "hpscan: %s %d not supported, using %d\n", name, v, actual);
    return actual;
}

static void set_str(SANE_Handle h, const char *name, const char *v)
{
    int o = find_option(h, name);
    if (o < 0) return;
    const SANE_Option_Descriptor *d = be.get_opt(h, o);
    char *buf = calloc(1, d->size > (SANE_Int)strlen(v) + 1 ? d->size : strlen(v) + 1);
    strcpy(buf, v);
    if (be.control(h, o, SANE_ACTION_SET_VALUE, buf, NULL) != SANE_STATUS_GOOD)
        fprintf(stderr, "hpscan: warning: could not set %s=%s\n", name, v);
    free(buf);
}

/* Scan area: ask for the full bed (max of each geometry range). */
static void set_max(SANE_Handle h, const char *name)
{
    int o = find_option(h, name);
    if (o < 0) return;
    const SANE_Option_Descriptor *d = be.get_opt(h, o);
    if (d->constraint_type != SANE_CONSTRAINT_RANGE) return;
    SANE_Word w = d->constraint.range->max;
    be.control(h, o, SANE_ACTION_SET_VALUE, &w, NULL);
}

static CFStringRef uti_for(const char *path)
{
    const char *ext = strrchr(path, '.');
    ext = ext ? ext + 1 : "";
    if (!strcasecmp(ext, "jpg") || !strcasecmp(ext, "jpeg")) return CFSTR("public.jpeg");
    if (!strcasecmp(ext, "tif") || !strcasecmp(ext, "tiff")) return CFSTR("public.tiff");
    if (!strcasecmp(ext, "pdf")) return CFSTR("com.adobe.pdf");
    return CFSTR("public.png");
}

static int write_image(const char *path, const SANE_Parameters *p, unsigned char *data,
                       int lines, int dpi)
{
    int gray = p->format == SANE_FRAME_GRAY;
    size_t bpl = p->bytes_per_line;
    unsigned char *pix = data;
    int bpc = p->depth;

    if (p->depth == 1) {            /* SANE lineart: 1 = black; expand to 8-bit gray */
        size_t w = p->pixels_per_line;
        pix = malloc(w * lines);
        for (int y = 0; y < lines; y++)
            for (size_t x = 0; x < w; x++)
                pix[y * w + x] = (data[y * bpl + x / 8] & (0x80 >> (x % 8))) ? 0 : 255;
        bpl = w; bpc = 8;
    }

    CGColorSpaceRef cs = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef cfd = CFDataCreate(NULL, pix, bpl * lines);
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(cfd);
    CGImageRef img = CGImageCreate(p->pixels_per_line, lines, bpc, bpc * (gray ? 1 : 3), bpl, cs,
                                   kCGImageAlphaNone, prov, NULL, false, kCGRenderingIntentDefault);
    int ok = 0;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CFStringRef uti = uti_for(path);

    if (CFStringCompare(uti, CFSTR("com.adobe.pdf"), 0) == kCFCompareEqualTo) {
        CGRect box = CGRectMake(0, 0, p->pixels_per_line * 72.0 / dpi, lines * 72.0 / dpi);
        CGContextRef ctx = CGPDFContextCreateWithURL(url, &box, NULL);
        if (ctx) {
            CGPDFContextBeginPage(ctx, NULL);
            CGContextDrawImage(ctx, box, img);
            CGPDFContextEndPage(ctx);
            CGPDFContextClose(ctx);
            CGContextRelease(ctx);
            ok = 1;
        }
    } else {
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, uti, 1, NULL);
        if (dst) {
            double d = dpi;
            CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &d);
            const void *k[] = { kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight };
            const void *v[] = { n, n };
            CFDictionaryRef props = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            CGImageDestinationAddImage(dst, img, props);
            ok = CGImageDestinationFinalize(dst);
            CFRelease(props); CFRelease(n); CFRelease(dst);
        }
    }
    CFRelease(url); CGImageRelease(img); CGDataProviderRelease(prov); CFRelease(cfd);
    CGColorSpaceRelease(cs);
    if (pix != data) free(pix);
    return ok;
}

static void usage(void)
{
    fprintf(stderr,
        "usage: hpscan [-L|-R] [-d device] [-r dpi] [-m Color|Gray|Lineart] [-b backend] OUTPUT\n"
        "  OUTPUT extension picks the format: .png .jpg .tiff .pdf\n"
        "  -L  list scanners and exit\n"
        "  -R  list supported resolutions and exit\n");
    exit(1);
}

int main(int argc, char **argv)
{
    const char *backend = getenv("HPSCAN_BACKEND") ? getenv("HPSCAN_BACKEND") : DEFAULT_BACKEND;
    const char *device = NULL, *mode = "Color";
    int dpi = 300, list = 0, show_res = 0, c;

    while ((c = getopt(argc, argv, "LRd:r:m:b:h")) != -1) {
        switch (c) {
        case 'L': list = 1; break;
        case 'R': show_res = 1; break;
        case 'd': device = optarg; break;
        case 'r': dpi = atoi(optarg); break;
        case 'm': mode = optarg; break;
        case 'b': backend = optarg; break;
        default: usage();
        }
    }
    if (!list && !show_res && optind != argc - 1) usage();

    void *h = dlopen(backend, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "hpscan: %s\n", dlerror()); return 2; }
    be.init = sym(h, "init"); be.exit = sym(h, "exit"); be.get_devices = sym(h, "get_devices");
    be.open = sym(h, "open"); be.close = sym(h, "close"); be.get_opt = sym(h, "get_option_descriptor");
    be.control = sym(h, "control_option"); be.params = sym(h, "get_parameters");
    be.start = sym(h, "start"); be.read = sym(h, "read"); be.cancel = sym(h, "cancel");

    SANE_Int ver;
    if (be.init(&ver, NULL) != SANE_STATUS_GOOD) { fprintf(stderr, "hpscan: init failed\n"); return 2; }

    const SANE_Device **devs = NULL;
    be.get_devices(&devs, SANE_TRUE);
    if (list) {
        for (int i = 0; devs && devs[i]; i++)
            printf("%s\t%s %s\n", devs[i]->name, devs[i]->vendor, devs[i]->model);
        be.exit();
        return 0;
    }
    if (!device) {
        if (!devs || !devs[0]) { fprintf(stderr, "hpscan: no HP scanner found (is it plugged in?)\n"); return 3; }
        device = devs[0]->name;
    }

    SANE_Handle sh;
    SANE_Status st = be.open(device, &sh);
    if (st != SANE_STATUS_GOOD) { fprintf(stderr, "hpscan: open %s failed (%d)\n", device, st); return 3; }

    if (show_res) {
        int o = find_option(sh, SANE_NAME_SCAN_RESOLUTION);
        const SANE_Option_Descriptor *d = o < 0 ? NULL : be.get_opt(sh, o);
        if (d && d->constraint_type == SANE_CONSTRAINT_WORD_LIST)
            for (int i = 1; i <= d->constraint.word_list[0]; i++)
                printf("%d\n", d->constraint.word_list[i]);
        be.close(sh); be.exit();
        return 0;
    }

    /* Right after a scan the 2130 rejects new jobs until its head has parked
     * (~10-20 s). Retry with a fresh session instead of failing. */
    const int max_wait = 45, step = 3;
    for (int waited = 0;; waited += step) {
        set_str(sh, SANE_NAME_SCAN_MODE, mode);
        dpi = set_int(sh, SANE_NAME_SCAN_RESOLUTION, dpi);
        set_max(sh, SANE_NAME_SCAN_BR_X);
        set_max(sh, SANE_NAME_SCAN_BR_Y);

        if (waited == 0)
            fprintf(stderr, "hpscan: scanning %s at %d dpi (%s)...\n", device, dpi, mode);
        st = be.start(sh);
        if (st == SANE_STATUS_GOOD) break;
        if (st == SANE_STATUS_NO_DOCS || waited >= max_wait) {
            fprintf(stderr, "hpscan: start failed: %s\n",
                    st == SANE_STATUS_NO_DOCS ? "no document" : "scanner busy or not responding");
            be.close(sh); be.exit(); return 4;
        }
        if (waited == 0) fprintf(stderr, "hpscan: scanner busy, waiting...\n");
        be.cancel(sh);
        be.close(sh);
        sleep(step);
        if (be.open(device, &sh) != SANE_STATUS_GOOD) {
            fprintf(stderr, "hpscan: lost connection to %s\n", device); be.exit(); return 3;
        }
    }

    SANE_Parameters p;
    be.params(sh, &p);
    size_t cap = (size_t)p.bytes_per_line * (p.lines > 0 ? p.lines : 3600), len = 0;
    unsigned char *buf = malloc(cap);
    for (;;) {
        if (cap - len < 65536) { cap *= 2; buf = realloc(buf, cap); }
        SANE_Int got = 0;
        st = be.read(sh, buf + len, 65536, &got);
        len += got;
        if (st == SANE_STATUS_EOF) break;
        if (st != SANE_STATUS_GOOD) { fprintf(stderr, "hpscan: read error %d\n", st); break; }
    }
    be.params(sh, &p);              /* line count may only be known now */
    int lines = (int)(len / p.bytes_per_line);
    be.cancel(sh);
    be.close(sh);
    be.exit();

    if (lines <= 0) { fprintf(stderr, "hpscan: no image data received\n"); return 5; }
    if (!write_image(argv[optind], &p, buf, lines, dpi)) {
        fprintf(stderr, "hpscan: could not write %s\n", argv[optind]); return 6;
    }
    fprintf(stderr, "hpscan: wrote %s (%dx%d)\n", argv[optind], p.pixels_per_line, lines);
    free(buf);
    return 0;
}
