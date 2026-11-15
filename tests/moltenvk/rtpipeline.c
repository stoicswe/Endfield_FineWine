/* rtpipeline.c: exercises VK_KHR_ray_tracing_pipeline on MoltenVK.
 *
 * The scene has four instances along the x axis, each with its own hit group:
 *   x =   0  an opaque triangle, closest-hit shader with shader record value 0.25
 *   x =  10  the same triangle and shader, shader record value 0.5
 *   x = -10  a triangle that is not opaque, with an any-hit shader that ignores every hit
 *   x =  20  a bounding box with an intersection shader that makes it a unit sphere
 *   x =  40  the same sphere, not opaque, with the any-hit shader that ignores every hit
 * The ray generation shader (tests/moltenvk/rt/) traces one ray at each of those and one at
 * nothing (x = 30), and calls a callable shader. The triangle closest-hit shader traces a second ray.
 * The results are checked against what Vulkan says each shader must see.
 * Built for macOS by scripts/test-moltenvk-raytracing.sh and for Windows by
 * scripts/test-finewine-runtime.sh. Prints "rtpipeline: ok" on success. */
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

#include "rtpipeline_spv.h"   /* generated: one static const uint32_t array per shader */

#define FAIL(...) do { printf("rtpipeline: " __VA_ARGS__); printf("\n"); return 1; } while (0)
#define CHECK(r, what) do { VkResult _r = (r); if (_r != VK_SUCCESS) FAIL("%s failed (%d)", what, _r); } while (0)

static PFN_vkGetInstanceProcAddr get_instance_proc;
static VkInstance instance; static VkDevice device; static VkPhysicalDevice gpu;
#define IFN(name) PFN_##name name = (PFN_##name)get_instance_proc(instance, #name); if (!name) FAIL("no " #name)
#define DFN(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(device, #name); if (!name) FAIL("no " #name)

static PFN_vkCreateBuffer p_vkCreateBuffer; static PFN_vkGetBufferMemoryRequirements p_vkGetBufferMemoryRequirements;
static PFN_vkAllocateMemory p_vkAllocateMemory; static PFN_vkBindBufferMemory p_vkBindBufferMemory;
static PFN_vkMapMemory p_vkMapMemory; static PFN_vkGetBufferDeviceAddress p_vkGetBufferDeviceAddress;
static VkPhysicalDeviceMemoryProperties mem_props;

typedef struct { VkBuffer buffer; VkDeviceMemory memory; void *data; VkDeviceAddress address; } Buffer;

static int make_buffer(VkDeviceSize size, VkBufferUsageFlags usage, int host_visible, Buffer *out)
{
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size; bi.usage = usage | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT; bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (p_vkCreateBuffer(device, &bi, NULL, &out->buffer)) return 0;
    VkMemoryRequirements req; p_vkGetBufferMemoryRequirements(device, out->buffer, &req);
    VkMemoryPropertyFlags want = host_visible ? (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    uint32_t type = ~0u;
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++)
        if ((req.memoryTypeBits & (1u << i)) && (mem_props.memoryTypes[i].propertyFlags & want) == want) { type = i; break; }
    if (type == ~0u) return 0;
    VkMemoryAllocateFlagsInfo fi = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO };
    fi.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fi, req.size, type };
    if (p_vkAllocateMemory(device, &ai, NULL, &out->memory)) return 0;
    if (p_vkBindBufferMemory(device, out->buffer, out->memory, 0)) return 0;
    out->data = NULL;
    if (host_visible && p_vkMapMemory(device, out->memory, 0, VK_WHOLE_SIZE, 0, &out->data)) return 0;
    VkBufferDeviceAddressInfo di = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, out->buffer };
    out->address = p_vkGetBufferDeviceAddress(device, &di);
    return 1;
}

typedef struct { float t; uint32_t custom; uint32_t marker; float extra; uint32_t aux; float call; uint32_t launch_size; uint32_t pad; } Result;

static int close_to(float a, float b) { return a > b - 0.01f && a < b + 0.01f; }

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
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "finewine-rtpipeline", 1, "none", 1, VK_API_VERSION_1_2 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app };
    CHECK(vkCreateInstance(&ici, NULL, &instance), "vkCreateInstance");

    IFN(vkEnumeratePhysicalDevices); IFN(vkEnumerateDeviceExtensionProperties); IFN(vkGetPhysicalDeviceFeatures2);
    IFN(vkGetPhysicalDeviceMemoryProperties); IFN(vkGetPhysicalDeviceQueueFamilyProperties); IFN(vkCreateDevice);
    IFN(vkGetDeviceProcAddr); IFN(vkGetPhysicalDeviceProperties2);
    uint32_t n = 1; CHECK(vkEnumeratePhysicalDevices(instance, &n, &gpu) < 0 ? VK_ERROR_UNKNOWN : VK_SUCCESS, "vkEnumeratePhysicalDevices");
    if (!n) FAIL("no GPU");

    /* 1. The extension, features and properties. */
    uint32_t ext_count = 0; vkEnumerateDeviceExtensionProperties(gpu, NULL, &ext_count, NULL);
    VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
    vkEnumerateDeviceExtensionProperties(gpu, NULL, &ext_count, exts);
    int has_rtp = 0;
    for (uint32_t i = 0; i < ext_count; i++) if (!strcmp(exts[i].extensionName, VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME)) has_rtp = 1;
    if (!has_rtp) FAIL("VK_KHR_ray_tracing_pipeline is not offered");
    VkPhysicalDeviceRayTracingPipelineFeaturesKHR rtf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_FEATURES_KHR };
    VkPhysicalDeviceAccelerationStructureFeaturesKHR asf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR, &rtf };
    VkPhysicalDeviceBufferDeviceAddressFeatures bda = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES, &asf };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &bda };
    vkGetPhysicalDeviceFeatures2(gpu, &f2);
    VkPhysicalDeviceRayTracingPipelinePropertiesKHR rtp = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_PROPERTIES_KHR };
    VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &rtp };
    vkGetPhysicalDeviceProperties2(gpu, &p2);
    printf("gpu: %s\n", p2.properties.deviceName);
    printf("features: rayTracingPipeline %u, traceRaysIndirect %u; handle size %u, base alignment %u, max recursion %u\n",
           rtf.rayTracingPipeline, rtf.rayTracingPipelineTraceRaysIndirect, rtp.shaderGroupHandleSize, rtp.shaderGroupBaseAlignment, rtp.maxRayRecursionDepth);
    if (!rtf.rayTracingPipeline || !rtf.rayTracingPipelineTraceRaysIndirect || !asf.accelerationStructure) FAIL("the ray tracing pipeline features are not offered");
    if (rtp.shaderGroupHandleSize != 32 || rtp.maxRayRecursionDepth < 2) FAIL("the ray tracing pipeline properties are not usable");
    rtf.rayTracingPipelineShaderGroupHandleCaptureReplay = rtf.rayTracingPipelineShaderGroupHandleCaptureReplayMixed = VK_FALSE;
    asf.accelerationStructureCaptureReplay = asf.accelerationStructureIndirectBuild = VK_FALSE;
    bda.bufferDeviceAddressCaptureReplay = bda.bufferDeviceAddressMultiDevice = VK_FALSE;

    uint32_t qn = 16; VkQueueFamilyProperties qf[16]; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, qf);
    uint32_t family = ~0u;
    for (uint32_t i = 0; i < qn; i++) if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { family = i; break; }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &prio };
    const char *dev_exts[] = { VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME, VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME,
                               VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME, VK_KHR_BUFFER_DEVICE_ADDRESS_EXTENSION_NAME };
    VkPhysicalDeviceFeatures2 enable = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &bda };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &enable, 0, 1, &qci, 0, NULL, 4, dev_exts, NULL };
    CHECK(vkCreateDevice(gpu, &dci, NULL, &device), "vkCreateDevice");
    vkGetPhysicalDeviceMemoryProperties(gpu, &mem_props);

    DFN(vkGetDeviceQueue); DFN(vkCreateCommandPool); DFN(vkAllocateCommandBuffers); DFN(vkBeginCommandBuffer);
    DFN(vkEndCommandBuffer); DFN(vkQueueSubmit); DFN(vkQueueWaitIdle); DFN(vkResetCommandBuffer);
    DFN(vkCreateAccelerationStructureKHR); DFN(vkGetAccelerationStructureBuildSizesKHR);
    DFN(vkCmdBuildAccelerationStructuresKHR); DFN(vkGetAccelerationStructureDeviceAddressKHR);
    DFN(vkCreateShaderModule); DFN(vkCreateDescriptorSetLayout); DFN(vkCreatePipelineLayout);
    DFN(vkCreateDescriptorPool); DFN(vkAllocateDescriptorSets); DFN(vkUpdateDescriptorSets);
    DFN(vkCmdBindPipeline); DFN(vkCmdBindDescriptorSets);
    DFN(vkCreateRayTracingPipelinesKHR); DFN(vkGetRayTracingShaderGroupHandlesKHR); DFN(vkCmdTraceRaysKHR); DFN(vkCmdTraceRaysIndirectKHR);
    p_vkCreateBuffer = (PFN_vkCreateBuffer)vkGetDeviceProcAddr(device, "vkCreateBuffer");
    p_vkGetBufferMemoryRequirements = (PFN_vkGetBufferMemoryRequirements)vkGetDeviceProcAddr(device, "vkGetBufferMemoryRequirements");
    p_vkAllocateMemory = (PFN_vkAllocateMemory)vkGetDeviceProcAddr(device, "vkAllocateMemory");
    p_vkBindBufferMemory = (PFN_vkBindBufferMemory)vkGetDeviceProcAddr(device, "vkBindBufferMemory");
    p_vkMapMemory = (PFN_vkMapMemory)vkGetDeviceProcAddr(device, "vkMapMemory");
    p_vkGetBufferDeviceAddress = (PFN_vkGetBufferDeviceAddress)vkGetDeviceProcAddr(device, "vkGetBufferDeviceAddress");

    VkQueue queue; vkGetDeviceQueue(device, family, 0, &queue);
    VkCommandPool pool; VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, family };
    CHECK(vkCreateCommandPool(device, &cpi, NULL, &pool), "vkCreateCommandPool");
    VkCommandBuffer cmd; VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    CHECK(vkAllocateCommandBuffers(device, &cai, &cmd), "vkAllocateCommandBuffers");
    VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; submit.commandBufferCount = 1; submit.pCommandBuffers = &cmd;
#define RUN(what, record) do { \
    CHECK(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer"); \
    CHECK(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer"); \
    record; \
    CHECK(vkEndCommandBuffer(cmd), "vkEndCommandBuffer (" what ")"); \
    CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit (" what ")"); \
    CHECK(vkQueueWaitIdle(queue), "vkQueueWaitIdle"); \
} while (0)

    /* 2. Four bottom-level structures: an opaque triangle, the same triangle not opaque, a box, and a box that is not opaque. */
    static const float vertices[] = { -1.0f, -1.0f, 0.0f,   1.0f, -1.0f, 0.0f,   0.0f, 1.0f, 0.0f };
    static const float box[] = { -1.0f, -1.0f, -1.0f,   1.0f, 1.0f, 1.0f };
    VkBufferUsageFlags input = VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR;
    VkBufferUsageFlags storage = VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR;
    Buffer vb, bb, scratch;
    if (!make_buffer(sizeof(vertices), input, 1, &vb) || !make_buffer(sizeof(box), input, 1, &bb)) FAIL("could not make the geometry buffers");
    memcpy(vb.data, vertices, sizeof(vertices)); memcpy(bb.data, box, sizeof(box));
    if (!make_buffer(1 << 20, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 0, &scratch)) FAIL("could not make the scratch buffer");
    VkAccelerationStructureKHR blas[4]; VkDeviceAddress blas_address[4];
    uint32_t one = 1; VkAccelerationStructureBuildRangeInfoKHR range = { 1, 0, 0, 0 }; const VkAccelerationStructureBuildRangeInfoKHR *ranges = &range;
    for (int i = 0; i < 4; i++) {
        VkAccelerationStructureGeometryKHR g = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR };
        if (i < 2) {
            g.geometryType = VK_GEOMETRY_TYPE_TRIANGLES_KHR; g.flags = i == 0 ? VK_GEOMETRY_OPAQUE_BIT_KHR : 0;
            g.geometry.triangles.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
            g.geometry.triangles.vertexFormat = VK_FORMAT_R32G32B32_SFLOAT; g.geometry.triangles.vertexData.deviceAddress = vb.address;
            g.geometry.triangles.vertexStride = 12; g.geometry.triangles.maxVertex = 2; g.geometry.triangles.indexType = VK_INDEX_TYPE_NONE_KHR;
        } else {
            g.geometryType = VK_GEOMETRY_TYPE_AABBS_KHR; g.flags = i == 2 ? VK_GEOMETRY_OPAQUE_BIT_KHR : 0;
            g.geometry.aabbs.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_AABBS_DATA_KHR;
            g.geometry.aabbs.data.deviceAddress = bb.address; g.geometry.aabbs.stride = 24;
        }
        VkAccelerationStructureBuildGeometryInfoKHR bi = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR };
        bi.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR; bi.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR; bi.geometryCount = 1; bi.pGeometries = &g;
        VkAccelerationStructureBuildSizesInfoKHR sz = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR };
        vkGetAccelerationStructureBuildSizesKHR(device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, &bi, &one, &sz);
        Buffer sb; if (!sz.accelerationStructureSize || !make_buffer(sz.accelerationStructureSize, storage, 0, &sb)) FAIL("could not size or store bottom-level structure %d", i);
        VkAccelerationStructureCreateInfoKHR aci = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR };
        aci.buffer = sb.buffer; aci.size = sz.accelerationStructureSize; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
        CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &blas[i]), "vkCreateAccelerationStructureKHR (bottom)");
        bi.dstAccelerationStructure = blas[i]; bi.scratchData.deviceAddress = scratch.address;
        RUN("bottom-level build", vkCmdBuildAccelerationStructuresKHR(cmd, 1, &bi, &ranges));
        VkAccelerationStructureDeviceAddressInfoKHR adi = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR, NULL, blas[i] };
        blas_address[i] = vkGetAccelerationStructureDeviceAddressKHR(device, &adi);
    }

    /* 3. The top-level structure: five instances, each with its own hit group. */
    static const float xs[5] = { 0.0f, 10.0f, -10.0f, 20.0f, 40.0f };
    static const int which[5] = { 0, 0, 1, 2, 3 };
    VkAccelerationStructureInstanceKHR inst[5]; memset(inst, 0, sizeof(inst));
    for (int i = 0; i < 5; i++) {
        inst[i].transform.matrix[0][0] = inst[i].transform.matrix[1][1] = inst[i].transform.matrix[2][2] = 1.0f;
        inst[i].transform.matrix[0][3] = xs[i];
        inst[i].instanceCustomIndex = 42 + i; inst[i].mask = 0xFF; inst[i].instanceShaderBindingTableRecordOffset = i;
        inst[i].flags = VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR; inst[i].accelerationStructureReference = blas_address[which[i]];
    }
    Buffer inst_buf; if (!make_buffer(sizeof(inst), input, 1, &inst_buf)) FAIL("could not make the instance buffer");
    memcpy(inst_buf.data, inst, sizeof(inst));
    VkAccelerationStructureGeometryKHR ig = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR };
    ig.geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR;
    ig.geometry.instances.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;
    ig.geometry.instances.data.deviceAddress = inst_buf.address;
    VkAccelerationStructureBuildGeometryInfoKHR tbi = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR };
    tbi.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR; tbi.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR; tbi.geometryCount = 1; tbi.pGeometries = &ig;
    uint32_t four = 5;
    VkAccelerationStructureBuildSizesInfoKHR tsz = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR };
    vkGetAccelerationStructureBuildSizesKHR(device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, &tbi, &four, &tsz);
    Buffer tlas_buf; if (!tsz.accelerationStructureSize || !make_buffer(tsz.accelerationStructureSize, storage, 0, &tlas_buf)) FAIL("could not size or store the top-level structure");
    VkAccelerationStructureCreateInfoKHR taci = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR };
    taci.buffer = tlas_buf.buffer; taci.size = tsz.accelerationStructureSize; taci.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    VkAccelerationStructureKHR tlas; CHECK(vkCreateAccelerationStructureKHR(device, &taci, NULL, &tlas), "vkCreateAccelerationStructureKHR (top)");
    tbi.dstAccelerationStructure = tlas; tbi.scratchData.deviceAddress = scratch.address;
    VkAccelerationStructureBuildRangeInfoKHR trange = { 5, 0, 0, 0 }; const VkAccelerationStructureBuildRangeInfoKHR *tranges = &trange;
    RUN("top-level build", vkCmdBuildAccelerationStructuresKHR(cmd, 1, &tbi, &tranges));
    printf("acceleration structures: built\n");

    /* 4. The pipeline: eight shaders in nine groups. */
    static const struct { const uint32_t *code; size_t size; VkShaderStageFlagBits stage; } shaders[8] = {
        { scene_rgen, sizeof(scene_rgen), VK_SHADER_STAGE_RAYGEN_BIT_KHR },             /* 0 */
        { scene_rmiss, sizeof(scene_rmiss), VK_SHADER_STAGE_MISS_BIT_KHR },             /* 1 */
        { shadow_rmiss, sizeof(shadow_rmiss), VK_SHADER_STAGE_MISS_BIT_KHR },           /* 2 */
        { triangle_rchit, sizeof(triangle_rchit), VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR },/* 3 */
        { ignore_rahit, sizeof(ignore_rahit), VK_SHADER_STAGE_ANY_HIT_BIT_KHR },        /* 4 */
        { sphere_rint, sizeof(sphere_rint), VK_SHADER_STAGE_INTERSECTION_BIT_KHR },     /* 5 */
        { sphere_rchit, sizeof(sphere_rchit), VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR },    /* 6 */
        { double_rcall, sizeof(double_rcall), VK_SHADER_STAGE_CALLABLE_BIT_KHR } };     /* 7 */
    VkPipelineShaderStageCreateInfo stages[8]; memset(stages, 0, sizeof(stages));
    for (int i = 0; i < 8; i++) {
        VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, shaders[i].size, shaders[i].code };
        stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stages[i].stage = shaders[i].stage; stages[i].pName = "main";
        CHECK(vkCreateShaderModule(device, &smi, NULL, &stages[i].module), "vkCreateShaderModule");
    }
#define U VK_SHADER_UNUSED_KHR
#define GROUP(type, general, closest, any, isect) { VK_STRUCTURE_TYPE_RAY_TRACING_SHADER_GROUP_CREATE_INFO_KHR, NULL, type, general, closest, any, isect, NULL }
    VkRayTracingShaderGroupCreateInfoKHR groups[9] = {
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_GENERAL_KHR, 0, U, U, U),                /* 0: ray generation */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_GENERAL_KHR, 1, U, U, U),                /* 1: miss */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_GENERAL_KHR, 2, U, U, U),                /* 2: miss of the second ray */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_TRIANGLES_HIT_GROUP_KHR, U, 3, U, U),    /* 3: triangle at x = 0 */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_TRIANGLES_HIT_GROUP_KHR, U, 3, U, U),    /* 4: triangle at x = 10 */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_TRIANGLES_HIT_GROUP_KHR, U, U, 4, U),    /* 5: ignored triangle */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_PROCEDURAL_HIT_GROUP_KHR, U, 6, U, 5),   /* 6: sphere */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_PROCEDURAL_HIT_GROUP_KHR, U, 6, 4, 5),   /* 7: ignored sphere */
        GROUP(VK_RAY_TRACING_SHADER_GROUP_TYPE_GENERAL_KHR, 7, U, U, U) };              /* 8: callable */
    VkDescriptorSetLayoutBinding bindings[2] = {
        { 0, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1, VK_SHADER_STAGE_RAYGEN_BIT_KHR | VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR, NULL },
        { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_RAYGEN_BIT_KHR, NULL } };
    VkDescriptorSetLayoutCreateInfo li = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 2, bindings };
    VkDescriptorSetLayout layout; CHECK(vkCreateDescriptorSetLayout(device, &li, NULL, &layout), "vkCreateDescriptorSetLayout");
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &layout };
    VkPipelineLayout pipeline_layout; CHECK(vkCreatePipelineLayout(device, &pli, NULL, &pipeline_layout), "vkCreatePipelineLayout");
    VkRayTracingPipelineCreateInfoKHR rpi = { VK_STRUCTURE_TYPE_RAY_TRACING_PIPELINE_CREATE_INFO_KHR };
    rpi.stageCount = 8; rpi.pStages = stages; rpi.groupCount = 9; rpi.pGroups = groups; rpi.maxPipelineRayRecursionDepth = 2; rpi.layout = pipeline_layout;
    VkPipeline pipeline; CHECK(vkCreateRayTracingPipelinesKHR(device, VK_NULL_HANDLE, VK_NULL_HANDLE, 1, &rpi, NULL, &pipeline), "vkCreateRayTracingPipelinesKHR");
    printf("ray tracing pipeline: created\n");

    /* 5. The shader binding table. Each record is a handle, then (for the triangle groups) a float. */
    uint8_t handles[9 * 32];
    CHECK(vkGetRayTracingShaderGroupHandlesKHR(device, pipeline, 0, 9, sizeof(handles), handles), "vkGetRayTracingShaderGroupHandlesKHR");
    enum { STRIDE = 64 };
    Buffer sbt; if (!make_buffer(9 * STRIDE, VK_BUFFER_USAGE_SHADER_BINDING_TABLE_BIT_KHR, 1, &sbt)) FAIL("could not make the shader binding table");
    memset(sbt.data, 0, 9 * STRIDE);
    for (int i = 0; i < 9; i++) memcpy((char *)sbt.data + i * STRIDE, handles + i * 32, 32);     /* in group order */
    float bias0 = 0.25f, bias1 = 0.5f;
    memcpy((char *)sbt.data + 3 * STRIDE + 32, &bias0, 4); memcpy((char *)sbt.data + 4 * STRIDE + 32, &bias1, 4);
    VkStridedDeviceAddressRegionKHR raygen = { sbt.address + 0 * STRIDE, STRIDE, STRIDE }, miss = { sbt.address + 1 * STRIDE, STRIDE, 2 * STRIDE },
                                    hit = { sbt.address + 3 * STRIDE, STRIDE, 5 * STRIDE }, callable = { sbt.address + 8 * STRIDE, STRIDE, STRIDE };

    VkDescriptorPoolSize sizes[2] = { { VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1 }, { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 } };
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 2, sizes };
    VkDescriptorPool dpool; CHECK(vkCreateDescriptorPool(device, &dpi, NULL, &dpool), "vkCreateDescriptorPool");
    VkDescriptorSetAllocateInfo dai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dpool, 1, &layout };
    VkDescriptorSet set; CHECK(vkAllocateDescriptorSets(device, &dai, &set), "vkAllocateDescriptorSets");
    Buffer result_buf; if (!make_buffer(6 * sizeof(Result), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 1, &result_buf)) FAIL("could not make the result buffer");
    VkWriteDescriptorSetAccelerationStructureKHR was = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR, NULL, 1, &tlas };
    VkDescriptorBufferInfo dbi = { result_buf.buffer, 0, 6 * sizeof(Result) };
    VkWriteDescriptorSet writes[2] = {
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, &was, set, 0, 0, 1, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR },
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi } };
    vkUpdateDescriptorSets(device, 2, writes, 0, NULL);

    /* 6. Trace, twice: with the size given directly, and read from a buffer. */
    Buffer indirect; if (!make_buffer(sizeof(VkTraceRaysIndirectCommandKHR), VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT, 1, &indirect)) FAIL("could not make the indirect buffer");
    VkTraceRaysIndirectCommandKHR icmd = { 6, 1, 1 }; memcpy(indirect.data, &icmd, sizeof(icmd));
    for (int pass = 0; pass < 2; pass++) {
        const char *how = pass ? "vkCmdTraceRaysIndirectKHR" : "vkCmdTraceRaysKHR";
        memset(result_buf.data, 0xEE, 6 * sizeof(Result));
        RUN("trace", (vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_RAY_TRACING_KHR, pipeline),
                      vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_RAY_TRACING_KHR, pipeline_layout, 0, 1, &set, 0, NULL),
                      pass ? vkCmdTraceRaysIndirectKHR(cmd, &raygen, &miss, &hit, &callable, indirect.address)
                           : vkCmdTraceRaysKHR(cmd, &raygen, &miss, &hit, &callable, 6, 1, 1)));
        Result r[6]; memcpy(r, result_buf.data, sizeof(r));
        static const char *names[6] = { "opaque triangle", "second triangle", "ignored triangle", "sphere", "nothing", "ignored sphere" };
        for (int i = 0; i < 6; i++)
            printf("%s, ray at the %s: t %.3f, custom index %u, marker %u, extra %.3f, aux %u, callable %.1f, launch size %u\n",
                   how, names[i], r[i].t, r[i].custom, r[i].marker, r[i].extra, r[i].aux, r[i].call, r[i].launch_size);
        for (int i = 0; i < 6; i++) {
            if (!close_to(r[i].call, 2.0f * (i + 1))) FAIL("ray %d: the callable shader should have doubled %d", i, i + 1);
            if (r[i].launch_size != 6) FAIL("ray %d: the launch size should be 6", i);
        }
        /* Closest hit, shader record, barycentrics (0.25, 0.5), and the second ray's miss shader (1.0).
         * Marker 11: primitive 0, seen from behind. The triangle's vertices run counter-clockwise
         * as this ray sees them with x to the right and y up, which Vulkan calls back-facing. */
        if (!close_to(r[0].t, 5.0f) || r[0].custom != 42 || r[0].marker != 11 || !close_to(r[0].extra, 1.25f) || r[0].aux != 50)
            FAIL("the ray at the opaque triangle did not report what its closest-hit shader computes");
        /* The instance's shader binding table offset selects the second record. */
        if (!close_to(r[1].t, 5.0f) || r[1].custom != 43 || r[1].marker != 11 || !close_to(r[1].extra, 1.5f) || r[1].aux != 50)
            FAIL("the ray at the second triangle did not use the second hit group's record");
        /* The any-hit shader ran once, on the payload the miss shader then saw. */
        if (r[2].marker != 100 || !close_to(r[2].t, 100.0f) || r[2].aux != 1) FAIL("the ignored triangle should have run its any-hit shader, then missed");
        /* The intersection shader's hit distance, hit kind and attribute reach the closest-hit shader. */
        if (!close_to(r[3].t, 4.0f) || r[3].custom != 45 || r[3].marker != 3 || !close_to(r[3].extra, -1.0f) || r[3].aux != 7)
            FAIL("the ray at the sphere did not report what its intersection shader found");
        if (r[4].marker != 100 || !close_to(r[4].t, 100.0f) || r[4].aux != 0) FAIL("the ray at nothing should have run the miss shader only");
        /* The intersection shader reported a hit, the any-hit shader ran on it and ignored it. */
        if (r[5].marker != 100 || !close_to(r[5].t, 100.0f) || r[5].aux != 1) FAIL("the ignored sphere should have run its any-hit shader, then missed");
    }
    printf("rtpipeline: ok\n");
    return 0;
}
