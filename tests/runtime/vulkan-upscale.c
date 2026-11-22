/* vulkan-upscale.c: a window with a Vulkan swap chain that is presented to for a few seconds.
 *
 * Used to check MoltenVK's upscaling of a swap chain that is smaller than its window is in
 * display pixels (patches/moltenvk/0006): with Wine's Retina mode off, or with a smaller
 * render size set for the prefix, the swap chain here is smaller, and MoltenVK says in its log
 * whether MetalFX upscales it. The picture is four coloured quarters, so a screenshot shows
 * whether it reached the window whole.
 *
 * Usage: vulkan-upscale [seconds, default 4] [full]   ("full": a window the size of the screen)
 * Prints "vulkan-upscale: ready <width>x<height> pid <unix pid is not known here>" once the
 * first frame is presented and "vulkan-upscale: ok frames <n> extent <w>x<h> screen <w>x<h>"
 * at the end.
 * Build: x86_64-w64-mingw32-clang -O1 -I<Vulkan headers> -o vulkan-upscale.exe vulkan-upscale.c -luser32 -lgdi32 */
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan_core.h>

typedef struct { VkStructureType sType; const void *pNext; VkFlags flags; HINSTANCE hinstance; HWND hwnd; } Win32SurfaceInfo;
#define FAIL(what) do { printf("vulkan-upscale: %s failed\n", what); return 1; } while (0)

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 4;
    HMODULE vk = LoadLibraryA("vulkan-1.dll");
    WNDCLASSA wc = {0};
    HWND hwnd;
    MSG msg;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (!vk) FAIL("loading vulkan-1.dll");
#define FN(name) PFN_##name name = (PFN_##name)(void *)GetProcAddress(vk, #name); if (!name) FAIL(#name)
    FN(vkCreateInstance); FN(vkEnumeratePhysicalDevices); FN(vkCreateDevice); FN(vkGetDeviceQueue);
    FN(vkGetPhysicalDeviceSurfaceCapabilitiesKHR); FN(vkCreateSwapchainKHR); FN(vkGetSwapchainImagesKHR);
    FN(vkAcquireNextImageKHR); FN(vkQueuePresentKHR); FN(vkCreateCommandPool); FN(vkAllocateCommandBuffers);
    FN(vkBeginCommandBuffer); FN(vkEndCommandBuffer); FN(vkCmdPipelineBarrier); FN(vkCmdClearColorImage);
    FN(vkQueueSubmit); FN(vkQueueWaitIdle); FN(vkCreateSemaphore); FN(vkResetCommandBuffer); FN(vkDeviceWaitIdle);
    int (WINAPI *vkCreateWin32SurfaceKHR)(VkInstance, const Win32SurfaceInfo *, const void *, VkSurfaceKHR *) =
        (void *)GetProcAddress(vk, "vkCreateWin32SurfaceKHR");
    if (!vkCreateWin32SurfaceKHR) FAIL("vkCreateWin32SurfaceKHR");

    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "finewine-vulkan-upscale";
    RegisterClassA(&wc);
    if (argc > 2 && !strcmp(argv[2], "full"))   /* a borderless window the size of the screen, as a game in full screen is */
        hwnd = CreateWindowExA(0, wc.lpszClassName, "vulkan-upscale", WS_POPUP | WS_VISIBLE, 0, 0,
                               GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), NULL, NULL, wc.hInstance, NULL);
    else
        hwnd = CreateWindowExA(WS_EX_NOACTIVATE, wc.lpszClassName, "vulkan-upscale", WS_POPUP | WS_VISIBLE, 60, 60, 480, 300, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) FAIL("CreateWindow");
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);

    const char *iext[] = {"VK_KHR_surface", "VK_KHR_win32_surface"};
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ici.pApplicationInfo = &app; ici.enabledExtensionCount = 2; ici.ppEnabledExtensionNames = iext;
    VkInstance inst; if (vkCreateInstance(&ici, NULL, &inst)) FAIL("vkCreateInstance");
    VkPhysicalDevice gpu; uint32_t n = 1; vkEnumeratePhysicalDevices(inst, &n, &gpu); if (!n) FAIL("finding a GPU");
    float prio = 1; VkDeviceQueueCreateInfo qi = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueCount = 1; qi.pQueuePriorities = &prio;
    const char *dext[] = {"VK_KHR_swapchain"};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qi; dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = dext;
    VkDevice dev; if (vkCreateDevice(gpu, &dci, NULL, &dev)) FAIL("vkCreateDevice");
    VkQueue queue; vkGetDeviceQueue(dev, 0, 0, &queue);

    Win32SurfaceInfo si = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR}; si.hinstance = wc.hInstance; si.hwnd = hwnd;
    VkSurfaceKHR surface; if (vkCreateWin32SurfaceKHR(inst, &si, NULL, &surface)) FAIL("vkCreateWin32SurfaceKHR");
    VkSurfaceCapabilitiesKHR caps; if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu, surface, &caps)) FAIL("surface capabilities");
    VkSwapchainCreateInfoKHR sci = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    sci.surface = surface; sci.minImageCount = caps.minImageCount < 3 ? 3 : caps.minImageCount; sci.imageFormat = VK_FORMAT_B8G8R8A8_UNORM;
    sci.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR; sci.imageExtent = caps.currentExtent; sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT; sci.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR; sci.presentMode = VK_PRESENT_MODE_FIFO_KHR; sci.clipped = VK_TRUE;
    VkSwapchainKHR chain; if (vkCreateSwapchainKHR(dev, &sci, NULL, &chain)) FAIL("vkCreateSwapchainKHR");
    VkImage images[8]; n = 8; vkGetSwapchainImagesKHR(dev, chain, &n, images);

    VkCommandPoolCreateInfo pi = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool pool; vkCreateCommandPool(dev, &pi, NULL, &pool);
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; ai.commandPool = pool; ai.commandBufferCount = 1;
    VkCommandBuffer cb; vkAllocateCommandBuffers(dev, &ai, &cb);
    VkSemaphoreCreateInfo semi = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO}; VkSemaphore acquired; vkCreateSemaphore(dev, &semi, NULL, &acquired);

    DWORD end = GetTickCount() + seconds * 1000; unsigned frames = 0;
    while (GetTickCount() < end)
    {
        uint32_t index; VkResult r = vkAcquireNextImageKHR(dev, chain, 2000000000ull, acquired, VK_NULL_HANDLE, &index);
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) { printf("vulkan-upscale: acquire returned %d\n", r); return 1; }
        VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        VkImageMemoryBarrier b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        /* a colour that changes slowly, so that a stuck picture shows in a screenshot */
        VkClearColorValue colour = {{0.1f, 0.3f + 0.5f * ((frames / 30) % 2), 0.8f, 1.0f}};
        vkResetCommandBuffer(cb, 0); vkBeginCommandBuffer(cb, &bi);
        b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; b.image = images[index]; b.subresourceRange = range;
        b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
        vkCmdClearColorImage(cb, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &range);
        b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR; b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; b.dstAccessMask = 0;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &b);
        vkEndCommandBuffer(cb);
        VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo sub = {VK_STRUCTURE_TYPE_SUBMIT_INFO}; sub.waitSemaphoreCount = 1; sub.pWaitSemaphores = &acquired; sub.pWaitDstStageMask = &stage; sub.commandBufferCount = 1; sub.pCommandBuffers = &cb;
        if (vkQueueSubmit(queue, 1, &sub, VK_NULL_HANDLE)) FAIL("vkQueueSubmit");
        vkQueueWaitIdle(queue);
        VkPresentInfoKHR pr = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR}; pr.swapchainCount = 1; pr.pSwapchains = &chain; pr.pImageIndices = &index;
        r = vkQueuePresentKHR(queue, &pr);
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) { printf("vulkan-upscale: present returned %d\n", r); return 1; }
        if (!frames++) printf("vulkan-upscale: ready %ux%u\n", sci.imageExtent.width, sci.imageExtent.height);
        /* the program's own count of what it presented, a second at a time, to hold against
         * what a frame counter drawn over the window (Metal's HUD) says */
        { static DWORD second_start; static unsigned in_second; DWORD now = GetTickCount();
          if (!second_start) second_start = now;
          in_second++;
          if (now - second_start >= 1000) { printf("vulkan-upscale: %.1f frames a second\n", in_second * 1000.0 / (now - second_start)); second_start = now; in_second = 0; } }
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
    }
    vkDeviceWaitIdle(dev);
    printf("vulkan-upscale: ok frames %u extent %ux%u screen %dx%d\n", frames, sci.imageExtent.width, sci.imageExtent.height,
           GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    return 0;
}
