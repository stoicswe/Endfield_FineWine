/* metalfx.c: exercises the MetalFX command of FineWine's MoltenVK, which DLSS is mapped to
 * for Direct3D 12 and Vulkan programs.
 *
 *  1. Super resolution: a 256x256 frame with a white square is upscaled to 512x512; the square
 *     must come out twice the size, in the same place.
 *  2. Frame generation: the square moves 16 pixels a frame; from the third frame on, the
 *     in-between frame must show it half way.
 *  3. With FINEWINE_GPU_VENDOR_ID / FINEWINE_GPU_DEVICE_ID set, the device reports those ids.
 * Built for macOS by scripts/test-moltenvk-raytracing.sh. Built for Windows with -DVIA_NGX by
 * scripts/test-finewine-runtime.sh, it makes the same requests the way a Vulkan game does:
 * through nvngx.dll's NVSDK_NGX_VULKAN_* entry points (needs FINEWINE_DLSS=1).
 * Prints "metalfx: ok" on success. */
#define VK_NO_PROTOTYPES
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fw_metalfx.h"

#define FAIL(...) do { printf("metalfx: " __VA_ARGS__); printf("\n"); return 1; } while (0)
#define CHECK(r, what) do { VkResult _r = (r); if (_r != VK_SUCCESS) FAIL("%s failed (%d)", what, _r); } while (0)

static PFN_vkGetInstanceProcAddr get_instance_proc;
static VkInstance instance; static VkDevice device; static VkPhysicalDevice gpu;
static VkPhysicalDeviceMemoryProperties mem_props;
#define IFN(name) PFN_##name name = (PFN_##name)get_instance_proc(instance, #name); if (!name) FAIL("no " #name)
#define DFN(name) static PFN_##name name;
DFN(vkCreateImage) DFN(vkGetImageMemoryRequirements) DFN(vkAllocateMemory) DFN(vkBindImageMemory) DFN(vkCreateBuffer)
DFN(vkGetBufferMemoryRequirements) DFN(vkBindBufferMemory) DFN(vkMapMemory) DFN(vkCmdCopyBufferToImage) DFN(vkCmdCopyImageToBuffer)
DFN(vkCmdPushConstants) DFN(vkBeginCommandBuffer) DFN(vkEndCommandBuffer) DFN(vkQueueSubmit) DFN(vkQueueWaitIdle) DFN(vkResetCommandBuffer)
#define LOAD(name) name = (PFN_##name)vkGetDeviceProcAddr(device, #name); if (!name) FAIL("no " #name)

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags want)
{
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mem_props.memoryTypes[i].propertyFlags & want) == want) return i;
    return ~0u;
}

static VkImage make_image(VkFormat format, uint32_t w, uint32_t h, VkImageUsageFlags usage)
{
    VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ii.imageType = VK_IMAGE_TYPE_2D; ii.format = format; ii.extent.width = w; ii.extent.height = h; ii.extent.depth = 1;
    ii.mipLevels = 1; ii.arrayLayers = 1; ii.samples = VK_SAMPLE_COUNT_1_BIT; ii.tiling = VK_IMAGE_TILING_OPTIMAL;
    ii.usage = usage | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    VkImage image; if (vkCreateImage(device, &ii, NULL, &image)) return VK_NULL_HANDLE;
    VkMemoryRequirements req; vkGetImageMemoryRequirements(device, image, &req);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    VkDeviceMemory mem; if (vkAllocateMemory(device, &ai, NULL, &mem) || vkBindImageMemory(device, image, mem, 0)) return VK_NULL_HANDLE;
    return image;
}

static VkBuffer staging; static void *staging_data;
static VkCommandBuffer cmd; static VkQueue queue;

static int run(void)
{
    VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; submit.commandBufferCount = 1; submit.pCommandBuffers = &cmd;
    return vkEndCommandBuffer(cmd) || vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE) || vkQueueWaitIdle(queue);
}
static int begin(void)
{
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    return vkResetCommandBuffer(cmd, 0) || vkBeginCommandBuffer(cmd, &bi);
}
static VkBufferImageCopy region(uint32_t w, uint32_t h, VkImageAspectFlags aspect)
{
    VkBufferImageCopy r; memset(&r, 0, sizeof(r));
    r.imageSubresource.aspectMask = aspect; r.imageSubresource.layerCount = 1; r.imageExtent.width = w; r.imageExtent.height = h; r.imageExtent.depth = 1;
    return r;
}
/* Fills an image from memory, through the staging buffer. */
static int upload(VkImage image, const void *data, size_t size, uint32_t w, uint32_t h, VkImageAspectFlags aspect)
{
    memcpy(staging_data, data, size);
    VkBufferImageCopy r = region(w, h, aspect);
    if (begin()) return 1;
    vkCmdCopyBufferToImage(cmd, staging, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
    return run();
}
#ifdef VIA_NGX
#include "../runtime/ngx-c.h"
static ngx_alloc_params_t ngx_alloc; static ngx_create_t ngx_create; static ngx_evaluate_t ngx_evaluate;
typedef struct { uint64_t view, image; } NGXVulkanResource;     /* the start of NVSDK_NGX_Resource_VK */
/* Makes the request through NGX: a feature per operation, created on first use. */
static int submit(const FWMetalFXRequest *rq, uint32_t out_size)
{
    static unsigned int *handles[3]; static NGXParams *params[3]; static NGXVulkanResource res[4];
    uint32_t op = rq->operation;
    if (op == FW_METALFX_RELEASE) return 0;
    if (!handles[op]) {
        if (ngx_alloc(&params[op]) != NGX_OK) return 1;
        NGX_SET_UINT(params[op], "Width", rq->inputWidth ? rq->inputWidth : out_size); NGX_SET_UINT(params[op], "Height", rq->inputHeight ? rq->inputHeight : out_size);
        NGX_SET_UINT(params[op], "OutWidth", out_size); NGX_SET_UINT(params[op], "OutHeight", out_size);
        NGX_SET_INT(params[op], "DLSS.Feature.Create.Flags", NGX_DLSS_FLAG_MV_LOWRES);
        if (ngx_create(cmd, op == FW_METALFX_TEMPORAL_UPSCALE ? NGX_FEATURE_SUPER_SAMPLING : NGX_FEATURE_FRAME_GENERATION, params[op], &handles[op]) != NGX_OK) return 1;
    }
    NGXParams *p = params[op]; int reset = (rq->flags & FW_METALFX_RESET_HISTORY) != 0;
    res[0].image = rq->color; res[1].image = rq->output; res[2].image = rq->depth; res[3].image = rq->motion;
    if (op == FW_METALFX_TEMPORAL_UPSCALE) {
        NGX_SET_POINTER(p, "Color", &res[0]); NGX_SET_POINTER(p, "Output", &res[1]); NGX_SET_POINTER(p, "Depth", &res[2]); NGX_SET_POINTER(p, "MotionVectors", &res[3]);
        NGX_SET_UINT(p, "DLSS.Render.Subrect.Dimensions.Width", rq->inputWidth); NGX_SET_UINT(p, "DLSS.Render.Subrect.Dimensions.Height", rq->inputHeight);
        NGX_SET_INT(p, "Reset", reset); NGX_SET_FLOAT(p, "MV.Scale.X", rq->motionScaleX); NGX_SET_FLOAT(p, "MV.Scale.Y", rq->motionScaleY);
    } else {
        NGX_SET_POINTER(p, "DLSSG.Backbuffer", &res[0]); NGX_SET_POINTER(p, "DLSSG.OutputInterpolated", &res[1]);
        NGX_SET_POINTER(p, "DLSSG.Depth", &res[2]); NGX_SET_POINTER(p, "DLSSG.MVecs", &res[3]);
        NGX_SET_INT(p, "DLSSG.EnableInterp", 1); NGX_SET_INT(p, "DLSSG.Reset", reset);
        NGX_SET_FLOAT(p, "DLSSG.MvecScaleX", rq->motionScaleX); NGX_SET_FLOAT(p, "DLSSG.MvecScaleY", rq->motionScaleY);
        NGX_SET_FLOAT(p, "DLSSG.CameraNear", rq->nearPlane); NGX_SET_FLOAT(p, "DLSSG.CameraFar", rq->farPlane);
        NGX_SET_FLOAT(p, "DLSSG.CameraFOV", rq->fieldOfView * 0.0174533f); NGX_SET_FLOAT(p, "DLSSG.CameraAspectRatio", rq->aspectRatio);
    }
    return ngx_evaluate(cmd, handles[op], p, NULL) != NGX_OK;
}
#else
/* Makes the request directly, the way nvngx.dll does on a program's behalf. */
static int submit(const FWMetalFXRequest *rq, uint32_t out_size)
{
    (void)out_size;
    vkCmdPushConstants(cmd, VK_NULL_HANDLE, FW_METALFX_MAGIC, 0, sizeof(*rq), rq);
    return 0;
}
#endif

/* The frame: dark grey with a 64-pixel white square (scaled with the frame) whose left edge is at x0. */
static void draw(uint8_t *p, uint32_t w, uint32_t h, uint32_t x0, uint32_t side)
{
    for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
        uint8_t v = (x >= x0 && x < x0 + side && y >= h / 2 - side / 2 && y < h / 2 + side / 2) ? 255 : 20;
        uint8_t *q = p + (y * w + x) * 4; q[0] = q[1] = q[2] = v; q[3] = 255;
    }
}
/* Where the bright pixels of the middle row of an RGBA image start and end. */
static void bright_span(const uint8_t *p, uint32_t w, uint32_t h, int *first, int *last)
{
    *first = *last = -1;
    for (uint32_t x = 0; x < w; x++) if (p[((h / 2) * w + x) * 4] > 128) { if (*first < 0) *first = (int)x; *last = (int)x; }
}
static uint16_t half(float f)   /* enough of a float-to-half conversion for whole numbers of pixels */
{
    union { float f; uint32_t u; } v = { f };
    if (f == 0.0f) return 0;
    uint32_t sign = (v.u >> 16) & 0x8000, exp = ((v.u >> 23) & 0xFF) - 127 + 15, man = (v.u >> 13) & 0x3FF;
    return (uint16_t)(sign | (exp << 10) | man);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
#ifdef _WIN32
    HMODULE lib = LoadLibraryA("vulkan-1.dll");
    if (!lib) FAIL("vulkan-1.dll did not load");
    get_instance_proc = (PFN_vkGetInstanceProcAddr)GetProcAddress(lib, "vkGetInstanceProcAddr");
#else
    void *lib = dlopen(getenv("MOLTENVK_DYLIB") ? getenv("MOLTENVK_DYLIB") : "libMoltenVK.dylib", RTLD_NOW);
    if (!lib) FAIL("libMoltenVK.dylib did not load: %s", dlerror());
    get_instance_proc = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
#endif
    if (!get_instance_proc) FAIL("no vkGetInstanceProcAddr");
    PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)get_instance_proc(NULL, "vkCreateInstance");
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "finewine-metalfx", 1, "none", 1, VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app };
    CHECK(vkCreateInstance(&ici, NULL, &instance), "vkCreateInstance");
    IFN(vkEnumeratePhysicalDevices); IFN(vkGetPhysicalDeviceProperties); IFN(vkGetPhysicalDeviceMemoryProperties);
    IFN(vkGetPhysicalDeviceQueueFamilyProperties); IFN(vkCreateDevice); IFN(vkGetDeviceProcAddr);
    uint32_t n = 1; if (vkEnumeratePhysicalDevices(instance, &n, &gpu) < 0 || !n) FAIL("no GPU");
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(gpu, &props);
    printf("gpu: %s, vendor %04x, device %04x\n", props.deviceName, props.vendorID, props.deviceID);
    /* 3. The ids the caller asked to be reported, if it asked. */
    const char *want_vendor = getenv("EXPECT_GPU_VENDOR_ID"), *want_device = getenv("EXPECT_GPU_DEVICE_ID");
    if (want_vendor && props.vendorID != strtoul(want_vendor, NULL, 16)) FAIL("the vendor id should be %s", want_vendor);
    if (want_device && props.deviceID != strtoul(want_device, NULL, 16)) FAIL("the device id should be %s", want_device);
    vkGetPhysicalDeviceMemoryProperties(gpu, &mem_props);
    uint32_t qn = 16; VkQueueFamilyProperties qf[16]; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, qf);
    uint32_t family = 0; for (uint32_t i = 0; i < qn; i++) if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { family = i; break; }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &prio };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci };
    CHECK(vkCreateDevice(gpu, &dci, NULL, &device), "vkCreateDevice");
    LOAD(vkCreateImage); LOAD(vkGetImageMemoryRequirements); LOAD(vkAllocateMemory); LOAD(vkBindImageMemory); LOAD(vkCreateBuffer);
    LOAD(vkGetBufferMemoryRequirements); LOAD(vkBindBufferMemory); LOAD(vkMapMemory); LOAD(vkCmdCopyBufferToImage); LOAD(vkCmdCopyImageToBuffer);
    LOAD(vkCmdPushConstants); LOAD(vkBeginCommandBuffer); LOAD(vkEndCommandBuffer); LOAD(vkQueueSubmit); LOAD(vkQueueWaitIdle); LOAD(vkResetCommandBuffer);
    PFN_vkGetDeviceQueue vkGetDeviceQueue = (PFN_vkGetDeviceQueue)vkGetDeviceProcAddr(device, "vkGetDeviceQueue");
    PFN_vkCreateCommandPool vkCreateCommandPool = (PFN_vkCreateCommandPool)vkGetDeviceProcAddr(device, "vkCreateCommandPool");
    PFN_vkAllocateCommandBuffers vkAllocateCommandBuffers = (PFN_vkAllocateCommandBuffers)vkGetDeviceProcAddr(device, "vkAllocateCommandBuffers");
    vkGetDeviceQueue(device, family, 0, &queue);
    VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, family };
    VkCommandPool pool; CHECK(vkCreateCommandPool(device, &cpi, NULL, &pool), "vkCreateCommandPool");
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    CHECK(vkAllocateCommandBuffers(device, &cai, &cmd), "vkAllocateCommandBuffers");

#ifdef VIA_NGX
    HMODULE ngx = LoadLibraryA("nvngx.dll");
    if (!ngx) FAIL("nvngx.dll did not load (%lu)", GetLastError());
    ngx_alloc = (ngx_alloc_params_t)GetProcAddress(ngx, "NVSDK_NGX_VULKAN_AllocateParameters");
    ngx_create = (ngx_create_t)GetProcAddress(ngx, "NVSDK_NGX_VULKAN_CreateFeature");
    ngx_evaluate = (ngx_evaluate_t)GetProcAddress(ngx, "NVSDK_NGX_VULKAN_EvaluateFeature");
    if (!ngx_alloc || !ngx_create || !ngx_evaluate) FAIL("nvngx.dll has no Vulkan entry points");
    printf("requests go through nvngx.dll\n");
#endif
    enum { LOW = 256, HIGH = 512 };
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO }; bci.size = HIGH * HIGH * 4;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    CHECK(vkCreateBuffer(device, &bci, NULL, &staging), "vkCreateBuffer");
    VkMemoryRequirements breq; vkGetBufferMemoryRequirements(device, staging, &breq);
    VkMemoryAllocateInfo bai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, breq.size, memory_type(breq.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    VkDeviceMemory bmem; CHECK(vkAllocateMemory(device, &bai, NULL, &bmem), "vkAllocateMemory");
    CHECK(vkBindBufferMemory(device, staging, bmem, 0), "vkBindBufferMemory"); CHECK(vkMapMemory(device, bmem, 0, VK_WHOLE_SIZE, 0, &staging_data), "vkMapMemory");

    /* The images a game would hand to DLSS: colour, depth, motion vectors, and where the result goes. */
    VkImage color = make_image(VK_FORMAT_R8G8B8A8_UNORM, LOW, LOW, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    VkImage depth = make_image(VK_FORMAT_D32_SFLOAT, LOW, LOW, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
    VkImage motion = make_image(VK_FORMAT_R16G16_SFLOAT, LOW, LOW, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    VkImage upscaled = make_image(VK_FORMAT_R8G8B8A8_UNORM, HIGH, HIGH, VK_IMAGE_USAGE_STORAGE_BIT);
    VkImage full = make_image(VK_FORMAT_R8G8B8A8_UNORM, HIGH, HIGH, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    VkImage full_depth = make_image(VK_FORMAT_D32_SFLOAT, HIGH, HIGH, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
    VkImage full_motion = make_image(VK_FORMAT_R16G16_SFLOAT, HIGH, HIGH, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    VkImage between = make_image(VK_FORMAT_R8G8B8A8_UNORM, HIGH, HIGH, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    if (!color || !depth || !motion || !upscaled || !full || !full_depth || !full_motion || !between) FAIL("could not make the images");

    uint8_t *pixels = malloc(HIGH * HIGH * 4); float *depths = malloc(HIGH * HIGH * sizeof(float)); uint16_t *vectors = calloc(HIGH * HIGH * 2, sizeof(uint16_t));
    for (int i = 0; i < HIGH * HIGH; i++) depths[i] = 0.5f;
    int first, last;

    /* 1. Super resolution. Several frames of a still image, as the scaler accumulates over time. */
    draw(pixels, LOW, LOW, 96, 64);
    if (upload(color, pixels, LOW * LOW * 4, LOW, LOW, VK_IMAGE_ASPECT_COLOR_BIT) || upload(depth, depths, LOW * LOW * 4, LOW, LOW, VK_IMAGE_ASPECT_DEPTH_BIT) ||
        upload(motion, vectors, LOW * LOW * 4, LOW, LOW, VK_IMAGE_ASPECT_COLOR_BIT)) FAIL("could not fill the input images");
    for (int f = 0; f < 4; f++) {
        FWMetalFXRequest rq; memset(&rq, 0, sizeof(rq));
        rq.size = sizeof(rq); rq.operation = FW_METALFX_TEMPORAL_UPSCALE; rq.feature = 1; rq.flags = f == 0 ? FW_METALFX_RESET_HISTORY : 0;
        rq.color = (uint64_t)color; rq.depth = (uint64_t)depth; rq.motion = (uint64_t)motion; rq.output = (uint64_t)upscaled;
        rq.inputWidth = LOW; rq.inputHeight = LOW; rq.motionScaleX = rq.motionScaleY = 1.0f; rq.preExposure = 1.0f;
        if (begin()) FAIL("could not begin a command buffer");
        if (submit(&rq, HIGH)) FAIL("the upscale request was refused");
        if (run()) FAIL("the upscale did not run");
    }
    VkBufferImageCopy r = region(HIGH, HIGH, VK_IMAGE_ASPECT_COLOR_BIT);
    memset(staging_data, 0, HIGH * HIGH * 4);
    if (begin()) FAIL("could not begin a command buffer");
    vkCmdCopyImageToBuffer(cmd, upscaled, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &r);
    if (run()) FAIL("could not read the upscaled image back");
    bright_span(staging_data, HIGH, HIGH, &first, &last);
    printf("super resolution: the square at 96..159 of 256 comes out at %d..%d of 512\n", first, last);
    if (first < 188 || first > 196 || last < 315 || last > 323) FAIL("the upscaled square should be at about 192..319");

    /* 2. Frame generation. The square moves 16 pixels to the right each frame. */
    if (upload(full_depth, depths, HIGH * HIGH * 4, HIGH, HIGH, VK_IMAGE_ASPECT_DEPTH_BIT)) FAIL("could not fill the depth image");
    int good = 0;
    for (int f = 0; f < 5; f++) {
        uint32_t x0 = 64 + 16 * f;
        draw(pixels, HIGH, HIGH, x0, 128);
        /* Each pixel of the square was 16 pixels further left in the last frame. */
        memset(vectors, 0, HIGH * HIGH * 2 * sizeof(uint16_t));
        for (uint32_t y = HIGH / 2 - 64; y < HIGH / 2 + 64; y++) for (uint32_t x = x0; x < x0 + 128; x++) vectors[(y * HIGH + x) * 2] = half(-16.0f);
        if (upload(full, pixels, HIGH * HIGH * 4, HIGH, HIGH, VK_IMAGE_ASPECT_COLOR_BIT) || upload(full_motion, vectors, HIGH * HIGH * 4, HIGH, HIGH, VK_IMAGE_ASPECT_COLOR_BIT))
            FAIL("could not fill a frame");
        FWMetalFXRequest rq; memset(&rq, 0, sizeof(rq));
        rq.size = sizeof(rq); rq.operation = FW_METALFX_FRAME_INTERPOLATE; rq.feature = 2; rq.flags = f == 0 ? FW_METALFX_RESET_HISTORY : 0;
        rq.color = (uint64_t)full; rq.depth = (uint64_t)full_depth; rq.motion = (uint64_t)full_motion; rq.output = (uint64_t)between;
        rq.motionScaleX = rq.motionScaleY = 1.0f; rq.deltaTime = 1.0f / 60.0f; rq.nearPlane = 0.1f; rq.farPlane = 100.0f; rq.fieldOfView = 60.0f; rq.aspectRatio = 1.0f;
        if (begin()) FAIL("could not begin a command buffer");
        if (submit(&rq, HIGH)) FAIL("the frame generation request was refused");
        vkCmdCopyImageToBuffer(cmd, between, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &r);
        if (run()) FAIL("the frame interpolation did not run");
        bright_span(staging_data, HIGH, HIGH, &first, &last);
        printf("frame generation, frame %d: square at %u (was at %u); the in-between frame has it at %d\n", f, x0, x0 - 16, first);
        /* Somewhere between where the square was and where it is; the moving edge is blurred. */
        if (f >= 2 && first > (int)x0 - 15 && first < (int)x0 - 1) good++;
    }
    if (good < 3) FAIL("from the third frame on the in-between frame should show the square between its last two positions");

    FWMetalFXRequest release; memset(&release, 0, sizeof(release));
    release.size = sizeof(release); release.operation = FW_METALFX_RELEASE;
    if (begin()) FAIL("could not begin a command buffer");
    release.feature = 1; submit(&release, HIGH);
    release.feature = 2; submit(&release, HIGH);
    if (run()) FAIL("the release did not run");
    printf("metalfx: ok\n");
    return 0;
}
