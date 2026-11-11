// fwalpha — CrossOver ARM's equivalent of patches/x64/stage1-macos/0009 (launcher alpha).
//
// The Gryphline launcher (Games.exe, Qt) draws its rounded window with transparent margins and
// expects DWM to composite that alpha. Wine's mac driver makes every Metal view, its layer and
// the window opaque, so the margins show up black. On x64 that is fixed in winemac.so itself;
// CrossOver ARM's winemac.so can't be rebuilt (its source isn't published), so the patcher adds a
// load command for this library to it and the same behaviour is applied at runtime instead.
//
// Only the launcher's Games.exe process is touched, and in it only windows that host a Metal
// view: the view and every Metal layer stop being opaque, the window surface behind the view is not
// drawn, and the window keeps per-pixel alpha with a clear background. The game is a separate
// process and is never changed. FWALPHA_DISABLE turns it off; FWALPHA_DEBUG logs to stderr.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <string.h>
#include <strings.h>

static const void *kComposites = &kComposites;
static BOOL debug;

static Class WineMetalView, WineContentView, WineWindow;
static IMP orig_makeBackingLayer, orig_viewDidMoveToWindow, orig_newMetalView, orig_updateLayer;
static IMP orig_setUsePerPixelAlpha, orig_winSetOpaque, orig_winSetBackgroundColor;
static IMP orig_metalLayerSetOpaque, orig_metalViewSetLayer, orig_addGLContext, orig_backingSetContents;

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

/* Whether the view, or a view inside it, draws with Metal or with an OpenGL context. An attached
 * OpenGL context shows up as an AppKit OpenGL sublayer of the view's layer. */
static BOOL view_has_metal(NSView *view)
{
    for (CALayer *sub in view.layer.sublayers)
        if (strstr(object_getClassName(sub), "OpenGL")) return YES;
    for (NSView *sub in view.subviews)
        if ([sub isKindOfClass:WineMetalView] || view_has_metal(sub)) return YES;
    return NO;
}

/* MoltenVK sets its layer opaque for VK_COMPOSITE_ALPHA_OPAQUE_BIT swapchains, and MoltenVK 1.4
 * may install a CAMetalLayer of its own on the view instead of using Wine's, so every Metal layer
 * in the launcher's process is kept non-opaque. Its windows are all Wine windows. */
static void metalLayer_setOpaque(CALayer *self, SEL _cmd, BOOL opaque)
{
    ((void (*)(id, SEL, BOOL))orig_metalLayerSetOpaque)(self, _cmd, NO);
}

static void adopt_layer(CALayer *layer)
{
    if (!layer) return;
    layer.opaque = NO;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
}

static void metalView_setLayer(NSView *self, SEL _cmd, CALayer *layer)
{
    ((void (*)(id, SEL, id))orig_metalViewSetLayer)(self, _cmd, layer);
    adopt_layer(layer);
}

/* Drop surface images already set, and redraw, in every view of a newly marked window. */
static void redraw_all(NSView *view)
{
    if (view_has_metal(view)) view.layer.contents = nil;
    [view setNeedsDisplay:YES];
    for (NSView *sub in view.subviews) redraw_all(sub);
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
    redraw_all(window.contentView);
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

/* With CrossOver's stock MoltenVK the launcher's Qt draws through ANGLE into a Metal view; with
 * the patched MoltenVK it uses desktop OpenGL instead. Its OpenGL surface is made transparent here,
 * as the Mac driver's OpenGLSurfaceMode=transparent would at context creation, and the window is
 * marked. */
static void content_addGLContext(NSView *self, SEL _cmd, id context)
{
    if ([context isKindOfClass:[NSOpenGLContext class]])
    {
        GLint opacity = 0;
        [(NSOpenGLContext *)context setValues:&opacity forParameter:NSOpenGLContextParameterSurfaceOpacity];
    }
    ((void (*)(id, SEL, id))orig_addGLContext)(self, _cmd, context);
    if (debug) fprintf(stderr, "fwalpha: GL context %p added to view %p (%s) in window %p\n", context, self,
                       object_getClassName(self), self.window);
    mark_window(self.window);
    [self setNeedsDisplay:YES];
}

/* The window surface sits behind the Metal view and has no alpha, so it would show through
 * wherever the swapchain is transparent. */
static void content_updateLayer(NSView *self, SEL _cmd)
{
    if (view_has_metal(self))
    {
        mark_window(self.window);
        if (window_composites(self.window))
        {
            self.layer.contents = nil;
            return;
        }
    }
    ((void (*)(id, SEL))orig_updateLayer)(self, _cmd);
}

/* The window surface image is set straight on the content view's layer, not through updateLayer,
 * and sits behind the Metal or OpenGL drawing; where that drawing is transparent it would show
 * through (black, or white for OpenGL). Drop it in compositing windows. */
static void backing_setContents(CALayer *self, SEL _cmd, id contents)
{
    id view = self.delegate;
    if (contents && [view isKindOfClass:WineContentView] && window_composites([view window]) && view_has_metal(view))
        contents = nil;
    ((void (*)(id, SEL, id))orig_backingSetContents)(self, _cmd, contents);
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

    Class CAMetalLayerClass = objc_getClass("CAMetalLayer");
    if (CAMetalLayerClass)
        orig_metalLayerSetOpaque = hook(CAMetalLayerClass, @selector(setOpaque:), (IMP)metalLayer_setOpaque);
    orig_metalViewSetLayer = hook(WineMetalView, @selector(setLayer:), (IMP)metalView_setLayer);
    Class backingLayer = objc_getClass("NSViewBackingLayer");
    orig_backingSetContents = hook(backingLayer ? backingLayer : [CALayer class], @selector(setContents:),
                                   (IMP)backing_setContents);
    hook(WineMetalView, @selector(isOpaque), (IMP)metal_isOpaque);
    orig_makeBackingLayer = hook(WineMetalView, @selector(makeBackingLayer), (IMP)metal_makeBackingLayer);
    orig_viewDidMoveToWindow = hook(WineMetalView, @selector(viewDidMoveToWindow), (IMP)metal_viewDidMoveToWindow);
    orig_newMetalView = hook(WineContentView, @selector(newMetalViewWithDevice:), (IMP)content_newMetalView);
    orig_updateLayer = hook(WineContentView, @selector(updateLayer), (IMP)content_updateLayer);
    orig_addGLContext = hook(WineContentView, @selector(addGLContext:), (IMP)content_addGLContext);
    orig_setUsePerPixelAlpha = hook(WineWindow, @selector(setUsePerPixelAlpha:), (IMP)window_setUsePerPixelAlpha);
    orig_winSetOpaque = hook(WineWindow, @selector(setOpaque:), (IMP)window_setOpaque);
    orig_winSetBackgroundColor = hook(WineWindow, @selector(setBackgroundColor:), (IMP)window_setBackgroundColor);
    if (debug) fprintf(stderr, "fwalpha: active in %s\n", (*_NSGetArgv())[0]);
}
