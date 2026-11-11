// fwalpha — CrossOver ARM's equivalent of patches/x64/stage1-macos/0009 (launcher alpha).
//
// The Gryphline launcher (Games.exe, Qt) draws its rounded window with transparent margins and
// expects DWM to composite that alpha. Wine's mac driver makes every Metal view, its layer and
// the window opaque, so the margins show up black. On x64 that is fixed in winemac.so itself;
// CrossOver ARM's winemac.so can't be rebuilt (its source isn't published), so the patcher adds a
// load command for this library to it and the same behaviour is applied at runtime instead.
//
// Only the launcher's Games.exe process is touched, and in it only windows that host a Metal
// view: the view and its layer stop being opaque, the window surface behind the view is not
// drawn, and the window keeps per-pixel alpha with a clear background. The game is a separate
// process and is never changed. FWALPHA_DISABLE turns it off; FWALPHA_DEBUG logs to stderr.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <crt_externs.h>
#include <string.h>
#include <strings.h>

static const void *kComposites = &kComposites;
static BOOL debug;

static Class WineMetalView, WineContentView, WineWindow, clearLayerClass;
static IMP orig_makeBackingLayer, orig_viewDidMoveToWindow, orig_newMetalView, orig_updateLayer;
static IMP orig_setUsePerPixelAlpha, orig_winSetOpaque, orig_winSetBackgroundColor;

/* Replace (or, if the class only inherits it, add) an instance method; returns the old IMP. */
static IMP hook(Class cls, SEL sel, IMP imp)
{
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m)))
        method_setImplementation(m, imp);
    return old;
}

static BOOL window_composites(NSWindow *window)
{
    return window && [objc_getAssociatedObject(window, kComposites) boolValue];
}

static BOOL view_has_metal(NSView *view)
{
    for (NSView *sub in view.subviews)
        if ([sub isKindOfClass:WineMetalView] || view_has_metal(sub)) return YES;
    return NO;
}

/* MoltenVK sets the layer opaque again for VK_COMPOSITE_ALPHA_OPAQUE_BIT swapchains, so the
 * layer gets a subclass whose setOpaque: always passes NO. */
static void layer_setOpaque(CALayer *self, SEL _cmd, BOOL opaque)
{
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, NO);
}

static void adopt_layer(CALayer *layer)
{
    if (!layer) return;
    Class base = object_getClass(layer);
    if (base != clearLayerClass)
    {
        if (!clearLayerClass)
        {
            clearLayerClass = objc_allocateClassPair(base, "FWClearMetalLayer", 0);
            class_addMethod(clearLayerClass, @selector(setOpaque:), (IMP)layer_setOpaque, "v@:c");
            objc_registerClassPair(clearLayerClass);
        }
        if (class_getSuperclass(clearLayerClass) == base) object_setClass(layer, clearLayerClass);
    }
    layer.opaque = NO;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
}

static void mark_window(NSWindow *window)
{
    if (![window isKindOfClass:WineWindow] || window_composites(window)) return;
    objc_setAssociatedObject(window, kComposites, @YES, OBJC_ASSOCIATION_RETAIN);
    if (debug)
        fprintf(stderr, "fwalpha: compositing alpha for window %p (was opaque=%d)\n", window, window.opaque);
    ((void (*)(id, SEL, BOOL))orig_setUsePerPixelAlpha)(window, @selector(setUsePerPixelAlpha:), YES);
    ((void (*)(id, SEL, BOOL))orig_winSetOpaque)(window, @selector(setOpaque:), NO);
    ((void (*)(id, SEL, id))orig_winSetBackgroundColor)(window, @selector(setBackgroundColor:), [NSColor clearColor]);
    window.contentView.layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    [window.contentView setNeedsDisplay:YES];
}

static BOOL metal_isOpaque(NSView *self, SEL _cmd) { return NO; }

static CALayer *metal_makeBackingLayer(NSView *self, SEL _cmd)
{
    CALayer *layer = ((CALayer *(*)(id, SEL))orig_makeBackingLayer)(self, _cmd);
    adopt_layer(layer);
    return layer;
}

/* The Vulkan path (wined3d -> MoltenVK) creates its Metal view without newMetalViewWithDevice:,
 * so the window is marked when the view is attached to it. */
static void metal_viewDidMoveToWindow(NSView *self, SEL _cmd)
{
    ((void (*)(id, SEL))orig_viewDidMoveToWindow)(self, _cmd);
    adopt_layer(self.layer);
    mark_window(self.window);
}

static id content_newMetalView(NSView *self, SEL _cmd, id device)
{
    NSView *view = ((id (*)(id, SEL, id))orig_newMetalView)(self, _cmd, device);
    adopt_layer(view.layer);
    mark_window(self.window);
    return view;
}

/* The window surface sits behind the Metal view and has no alpha, so it would show through
 * wherever the swapchain is transparent. */
static void content_updateLayer(NSView *self, SEL _cmd)
{
    if (window_composites(self.window) && view_has_metal(self))
    {
        self.layer.contents = nil;
        return;
    }
    ((void (*)(id, SEL))orig_updateLayer)(self, _cmd);
}

/* Wine re-derives these from the window's own transparency state; keep compositing windows clear. */
static void window_setUsePerPixelAlpha(NSWindow *self, SEL _cmd, BOOL use)
{
    ((void (*)(id, SEL, BOOL))orig_setUsePerPixelAlpha)(self, _cmd, use || window_composites(self));
}

static void window_setOpaque(NSWindow *self, SEL _cmd, BOOL opaque)
{
    ((void (*)(id, SEL, BOOL))orig_winSetOpaque)(self, _cmd, opaque && !window_composites(self));
}

static void window_setBackgroundColor(NSWindow *self, SEL _cmd, NSColor *color)
{
    ((void (*)(id, SEL, id))orig_winSetBackgroundColor)(self, _cmd, window_composites(self) ? [NSColor clearColor] : color);
}

/* Wine rewrites argv[0] to the Windows path of the process's executable. */
static BOOL is_launcher_process(void)
{
    char **argv = *_NSGetArgv();
    const char *name = argv && argv[0] ? argv[0] : "";
    const char *base = strrchr(name, '\\');
    base = base ? base + 1 : name;
    return !strcasecmp(base, "Games.exe");
}

__attribute__((constructor)) static void fwalpha_init(void)
{
    if (getenv("FWALPHA_DISABLE") || !is_launcher_process()) return;
    debug = getenv("FWALPHA_DEBUG") != NULL;
    WineMetalView = objc_getClass("WineMetalView");
    WineContentView = objc_getClass("WineContentView");
    WineWindow = objc_getClass("WineWindow");
    if (!WineMetalView || !WineContentView || !WineWindow
        || !class_getInstanceMethod(WineWindow, @selector(setUsePerPixelAlpha:))
        || !class_getInstanceMethod(WineContentView, @selector(updateLayer)))
    {
        if (debug) fprintf(stderr, "fwalpha: winemac.so classes not found, leaving it alone\n");
        return;
    }

    hook(WineMetalView, @selector(isOpaque), (IMP)metal_isOpaque);
    orig_makeBackingLayer = hook(WineMetalView, @selector(makeBackingLayer), (IMP)metal_makeBackingLayer);
    orig_viewDidMoveToWindow = hook(WineMetalView, @selector(viewDidMoveToWindow), (IMP)metal_viewDidMoveToWindow);
    orig_newMetalView = hook(WineContentView, @selector(newMetalViewWithDevice:), (IMP)content_newMetalView);
    orig_updateLayer = hook(WineContentView, @selector(updateLayer), (IMP)content_updateLayer);
    orig_setUsePerPixelAlpha = hook(WineWindow, @selector(setUsePerPixelAlpha:), (IMP)window_setUsePerPixelAlpha);
    orig_winSetOpaque = hook(WineWindow, @selector(setOpaque:), (IMP)window_setOpaque);
    orig_winSetBackgroundColor = hook(WineWindow, @selector(setBackgroundColor:), (IMP)window_setBackgroundColor);
    if (debug) fprintf(stderr, "fwalpha: active in %s\n", (*_NSGetArgv())[0]);
}
