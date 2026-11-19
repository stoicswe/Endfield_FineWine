/*
 * finewine-presence: lets apps that look for running games by file name find a Windows game.
 *
 * Discord recognises a game on the Mac by the file name of a running app ("endfield.exe",
 * "zenlesszonezero game/zenlesszonezero.exe"), and only looks at processes that macOS lists
 * as apps, are not inside an app bundle, and have a window. A game under FineWine runs from
 * an app bundle of its own name (for the Dock and Game Mode), which hides the Windows file
 * name. So the Mac driver starts a copy of this program next to each game, under the game's
 * file name: an app with no Dock icon and one invisible window, which ends when the game does.
 *
 * Usage: <copy named like the game's file> <process id of the game>
 *
 * What Discord needs was found by trying, 2026-11: a plain process is not seen; an app
 * without a window is not seen; the file name inside an app bundle is not seen.
 */
#import <AppKit/AppKit.h>

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        pid_t game = argc > 1 ? (pid_t)atoi(argv[1]) : 0;
        NSApplication *app;
        NSWindow *window;
        dispatch_source_t gone;

        if (game <= 1 || kill(game, 0)) return 1;

        app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        /* One clear pixel in the corner, on every Space, that takes no clicks and no part
         * in window switching. */
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
        window.opaque = NO;
        window.backgroundColor = [NSColor clearColor];
        window.ignoresMouseEvents = YES;
        window.hasShadow = NO;
        window.releasedWhenClosed = NO;
        window.excludedFromWindowsMenu = YES;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
        [window orderFrontRegardless];

        gone = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, game, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gone, ^{ exit(0); });
        dispatch_resume(gone);
        if (kill(game, 0)) return 0;   /* it ended before the source was armed */

        [app run];
    }
    return 0;
}
