/* raytracing.c: exercises VK_KHR_acceleration_structure and VK_KHR_ray_query on MoltenVK.
 *
 * Builds a bottom-level acceleration structure from one triangle and a top-level structure with
 * one instance of it (custom index 42), then runs a compute shader that traces one ray at the
 * triangle and one past it. It then goes through the rest of the acceleration structure API:
 * a compacted-size query and a compacting copy, serializing a structure and reading it back
 * (in a command buffer and with the host commands), and building on the host. Each result is
 * traced against. Built for macOS against libMoltenVK.dylib by
 * scripts/test-moltenvk-raytracing.sh, and for Windows (it then runs under Wine) by
 * scripts/test-finewine-runtime.sh. Prints "raytracing: ok" on success. */
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

#include "rayquery_spv.h"   /* generated: static const uint32_t rayquery_spv[] */

#define FAIL(...) do { printf("raytracing: " __VA_ARGS__); printf("\n"); return 1; } while (0)
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
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "finewine-rt", 1, "none", 1, VK_API_VERSION_1_2 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app };
    CHECK(vkCreateInstance(&ici, NULL, &instance), "vkCreateInstance");

    IFN(vkEnumeratePhysicalDevices); IFN(vkEnumerateDeviceExtensionProperties); IFN(vkGetPhysicalDeviceFeatures2);
    IFN(vkGetPhysicalDeviceMemoryProperties); IFN(vkGetPhysicalDeviceQueueFamilyProperties); IFN(vkCreateDevice);
    IFN(vkGetDeviceProcAddr); IFN(vkGetPhysicalDeviceProperties);
    uint32_t n = 1; CHECK(vkEnumeratePhysicalDevices(instance, &n, &gpu) < 0 ? VK_ERROR_UNKNOWN : VK_SUCCESS, "vkEnumeratePhysicalDevices");
    if (!n) FAIL("no GPU");
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(gpu, &props);
    printf("gpu: %s\n", props.deviceName);

    /* 1. The extensions and features have to be offered. */
    uint32_t ext_count = 0; vkEnumerateDeviceExtensionProperties(gpu, NULL, &ext_count, NULL);
    VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
    vkEnumerateDeviceExtensionProperties(gpu, NULL, &ext_count, exts);
    int has_as = 0, has_rq = 0;
    for (uint32_t i = 0; i < ext_count; i++) {
        if (!strcmp(exts[i].extensionName, VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME)) has_as = 1;
        if (!strcmp(exts[i].extensionName, VK_KHR_RAY_QUERY_EXTENSION_NAME)) has_rq = 1;
    }
    printf("extensions: acceleration_structure %s, ray_query %s\n", has_as ? "yes" : "NO", has_rq ? "yes" : "NO");
    if (!has_as || !has_rq) FAIL("the ray tracing extensions are not offered");

    VkPhysicalDeviceRayQueryFeaturesKHR rq = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR };
    VkPhysicalDeviceAccelerationStructureFeaturesKHR asf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR, &rq };
    VkPhysicalDeviceBufferDeviceAddressFeatures bda = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES, &asf };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &bda };
    vkGetPhysicalDeviceFeatures2(gpu, &f2);
    printf("features: accelerationStructure %u, rayQuery %u, bufferDeviceAddress %u\n", asf.accelerationStructure, rq.rayQuery, bda.bufferDeviceAddress);
    if (!asf.accelerationStructure || !rq.rayQuery || !bda.bufferDeviceAddress) FAIL("the ray tracing features are not offered");
    printf("features: accelerationStructureHostCommands %u\n", asf.accelerationStructureHostCommands);
    if (!asf.accelerationStructureHostCommands) FAIL("the host commands are not offered");
    asf.accelerationStructureCaptureReplay = asf.accelerationStructureIndirectBuild = VK_FALSE;
    bda.bufferDeviceAddressCaptureReplay = bda.bufferDeviceAddressMultiDevice = VK_FALSE;

    uint32_t qn = 16; VkQueueFamilyProperties qf[16]; vkGetPhysicalDeviceQueueFamilyProperties(gpu, &qn, qf);
    uint32_t family = ~0u;
    for (uint32_t i = 0; i < qn; i++) if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { family = i; break; }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &prio };
    const char *dev_exts[] = { VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME, VK_KHR_RAY_QUERY_EXTENSION_NAME,
                               VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME, VK_KHR_BUFFER_DEVICE_ADDRESS_EXTENSION_NAME };
    VkPhysicalDeviceFeatures2 enable = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &bda };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &enable, 0, 1, &qci, 0, NULL, 4, dev_exts, NULL };
    CHECK(vkCreateDevice(gpu, &dci, NULL, &device), "vkCreateDevice");
    vkGetPhysicalDeviceMemoryProperties(gpu, &mem_props);

    DFN(vkGetDeviceQueue); DFN(vkCreateCommandPool); DFN(vkAllocateCommandBuffers); DFN(vkBeginCommandBuffer);
    DFN(vkEndCommandBuffer); DFN(vkQueueSubmit); DFN(vkQueueWaitIdle); DFN(vkResetCommandBuffer);
    DFN(vkCreateAccelerationStructureKHR); DFN(vkGetAccelerationStructureBuildSizesKHR);
    DFN(vkCmdBuildAccelerationStructuresKHR); DFN(vkGetAccelerationStructureDeviceAddressKHR);
    DFN(vkCreateShaderModule); DFN(vkCreateDescriptorSetLayout); DFN(vkCreatePipelineLayout); DFN(vkCreateComputePipelines);
    DFN(vkCreateDescriptorPool); DFN(vkAllocateDescriptorSets); DFN(vkUpdateDescriptorSets);
    DFN(vkCmdBindPipeline); DFN(vkCmdBindDescriptorSets); DFN(vkCmdDispatch);
    DFN(vkCreateQueryPool); DFN(vkGetQueryPoolResults); DFN(vkCmdResetQueryPool); DFN(vkCmdWriteAccelerationStructuresPropertiesKHR);
    DFN(vkCmdCopyAccelerationStructureKHR); DFN(vkCmdCopyAccelerationStructureToMemoryKHR); DFN(vkCmdCopyMemoryToAccelerationStructureKHR);
    DFN(vkGetDeviceAccelerationStructureCompatibilityKHR); DFN(vkBuildAccelerationStructuresKHR);
    DFN(vkCopyAccelerationStructureToMemoryKHR); DFN(vkCopyMemoryToAccelerationStructureKHR); DFN(vkWriteAccelerationStructuresPropertiesKHR);
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

    /* 2. Bottom-level structure: one triangle in the z = 0 plane, around the origin. */
    static const float vertices[] = { -1.0f, -1.0f, 0.0f,   1.0f, -1.0f, 0.0f,   0.0f, 1.0f, 0.0f };
    static const uint32_t indices[] = { 0, 1, 2 };
    Buffer vb, ib, blas_buf, tlas_buf, scratch, inst_buf, result_buf;
    VkBufferUsageFlags input = VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR;
    if (!make_buffer(sizeof(vertices), input, 1, &vb) || !make_buffer(sizeof(indices), input, 1, &ib)) FAIL("could not make the geometry buffers");
    memcpy(vb.data, vertices, sizeof(vertices)); memcpy(ib.data, indices, sizeof(indices));

    VkAccelerationStructureGeometryKHR tri = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR };
    tri.geometryType = VK_GEOMETRY_TYPE_TRIANGLES_KHR; tri.flags = VK_GEOMETRY_OPAQUE_BIT_KHR;
    tri.geometry.triangles.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
    tri.geometry.triangles.vertexFormat = VK_FORMAT_R32G32B32_SFLOAT; tri.geometry.triangles.vertexData.deviceAddress = vb.address;
    tri.geometry.triangles.vertexStride = 12; tri.geometry.triangles.maxVertex = 2;
    tri.geometry.triangles.indexType = VK_INDEX_TYPE_UINT32; tri.geometry.triangles.indexData.deviceAddress = ib.address;
    VkAccelerationStructureBuildGeometryInfoKHR bbi = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR };
    bbi.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR; bbi.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR;
    bbi.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR; bbi.geometryCount = 1; bbi.pGeometries = &tri;
    uint32_t one = 1;
    VkAccelerationStructureBuildSizesInfoKHR bsz = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR };
    vkGetAccelerationStructureBuildSizesKHR(device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, &bbi, &one, &bsz);
    printf("bottom-level sizes: structure %llu, scratch %llu\n", (unsigned long long)bsz.accelerationStructureSize, (unsigned long long)bsz.buildScratchSize);
    if (!bsz.accelerationStructureSize || !bsz.buildScratchSize) FAIL("no build sizes for the bottom-level structure");

    VkBufferUsageFlags storage = VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR;
    if (!make_buffer(bsz.accelerationStructureSize, storage, 0, &blas_buf)) FAIL("could not make the bottom-level storage buffer");
    VkAccelerationStructureCreateInfoKHR aci = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR };
    aci.buffer = blas_buf.buffer; aci.size = bsz.accelerationStructureSize; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
    VkAccelerationStructureKHR blas; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &blas), "vkCreateAccelerationStructureKHR (bottom)");
    if (!make_buffer(bsz.buildScratchSize + 4096, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 0, &scratch)) FAIL("could not make the scratch buffer");
    bbi.dstAccelerationStructure = blas; bbi.scratchData.deviceAddress = scratch.address;
    VkAccelerationStructureBuildRangeInfoKHR range = { 1, 0, 0, 0 }; const VkAccelerationStructureBuildRangeInfoKHR *ranges = &range;
    CHECK(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer");
    vkCmdBuildAccelerationStructuresKHR(cmd, 1, &bbi, &ranges);
    CHECK(vkEndCommandBuffer(cmd), "vkEndCommandBuffer (bottom-level build)");
    CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit (bottom-level build)");
    CHECK(vkQueueWaitIdle(queue), "vkQueueWaitIdle");
    VkAccelerationStructureDeviceAddressInfoKHR adi = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR, NULL, blas };
    VkDeviceAddress blas_address = vkGetAccelerationStructureDeviceAddressKHR(device, &adi);
    if (!blas_address) FAIL("the bottom-level structure has no device address");
    printf("bottom-level structure: built\n");

    /* 3. Top-level structure: one instance of it, with custom index 42. */
    VkAccelerationStructureInstanceKHR inst; memset(&inst, 0, sizeof(inst));
    inst.transform.matrix[0][0] = inst.transform.matrix[1][1] = inst.transform.matrix[2][2] = 1.0f;
    inst.instanceCustomIndex = 42; inst.mask = 0xFF; inst.flags = VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR;
    inst.accelerationStructureReference = blas_address;
    if (!make_buffer(sizeof(inst), input, 1, &inst_buf)) FAIL("could not make the instance buffer");
    memcpy(inst_buf.data, &inst, sizeof(inst));
    VkAccelerationStructureGeometryKHR ig = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR };
    ig.geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR; ig.flags = VK_GEOMETRY_OPAQUE_BIT_KHR;
    ig.geometry.instances.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;
    ig.geometry.instances.data.deviceAddress = inst_buf.address;
    VkAccelerationStructureBuildGeometryInfoKHR tbi = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR };
    tbi.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR; tbi.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR;
    tbi.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR; tbi.geometryCount = 1; tbi.pGeometries = &ig;
    VkAccelerationStructureBuildSizesInfoKHR tsz = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR };
    vkGetAccelerationStructureBuildSizesKHR(device, VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR, &tbi, &one, &tsz);
    printf("top-level sizes: structure %llu, scratch %llu\n", (unsigned long long)tsz.accelerationStructureSize, (unsigned long long)tsz.buildScratchSize);
    if (!tsz.accelerationStructureSize) FAIL("no build sizes for the top-level structure");
    if (!make_buffer(tsz.accelerationStructureSize, storage, 0, &tlas_buf)) FAIL("could not make the top-level storage buffer");
    aci.buffer = tlas_buf.buffer; aci.size = tsz.accelerationStructureSize; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    VkAccelerationStructureKHR tlas; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &tlas), "vkCreateAccelerationStructureKHR (top)");
    Buffer scratch2; if (!make_buffer(tsz.buildScratchSize + 4096, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 0, &scratch2)) FAIL("could not make the second scratch buffer");
    tbi.dstAccelerationStructure = tlas; tbi.scratchData.deviceAddress = scratch2.address;
    CHECK(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer");
    CHECK(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer");
    vkCmdBuildAccelerationStructuresKHR(cmd, 1, &tbi, &ranges);
    CHECK(vkEndCommandBuffer(cmd), "vkEndCommandBuffer (top-level build)");
    CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit (top-level build)");
    CHECK(vkQueueWaitIdle(queue), "vkQueueWaitIdle");
    printf("top-level structure: built\n");

    /* 4. A compute shader traces one ray at the triangle and one past it. */
    VkShaderModuleCreateInfo smi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sizeof(rayquery_spv), rayquery_spv };
    VkShaderModule module; CHECK(vkCreateShaderModule(device, &smi, NULL, &module), "vkCreateShaderModule");
    VkDescriptorSetLayoutBinding bindings[2] = {
        { 0, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL } };
    VkDescriptorSetLayoutCreateInfo li = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 2, bindings };
    VkDescriptorSetLayout layout; CHECK(vkCreateDescriptorSetLayout(device, &li, NULL, &layout), "vkCreateDescriptorSetLayout");
    VkPipelineLayoutCreateInfo pli = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &layout };
    VkPipelineLayout pipeline_layout; CHECK(vkCreatePipelineLayout(device, &pli, NULL, &pipeline_layout), "vkCreatePipelineLayout");
    VkComputePipelineCreateInfo pci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    pci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; pci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pci.stage.module = module; pci.stage.pName = "main"; pci.layout = pipeline_layout;
    VkPipeline pipeline; CHECK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pci, NULL, &pipeline), "vkCreateComputePipelines (ray query shader)");
    printf("ray query shader: compiled\n");

    VkDescriptorPoolSize sizes[2] = { { VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, 1 }, { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 } };
    VkDescriptorPoolCreateInfo dpi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 2, sizes };
    VkDescriptorPool dpool; CHECK(vkCreateDescriptorPool(device, &dpi, NULL, &dpool), "vkCreateDescriptorPool");
    VkDescriptorSetAllocateInfo dai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dpool, 1, &layout };
    VkDescriptorSet set; CHECK(vkAllocateDescriptorSets(device, &dai, &set), "vkAllocateDescriptorSets");
    if (!make_buffer(16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 1, &result_buf)) FAIL("could not make the result buffer");
    memset(result_buf.data, 0xEE, 16);
    VkWriteDescriptorSetAccelerationStructureKHR was = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR, NULL, 1, &tlas };
    VkDescriptorBufferInfo dbi = { result_buf.buffer, 0, 16 };
    VkWriteDescriptorSet writes[2] = {
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, &was, set, 0, 0, 1, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR },
        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi } };
    vkUpdateDescriptorSets(device, 2, writes, 0, NULL);

    struct { uint32_t hit; float t; uint32_t miss; uint32_t custom; } r;
/* Points the shader at a top-level structure, traces the two rays and checks what comes back. */
#define TRACE(structure, what, want_t, want_custom) do { \
    VkAccelerationStructureKHR _tl = (structure); \
    VkWriteDescriptorSetAccelerationStructureKHR _was = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR, NULL, 1, &_tl }; \
    VkWriteDescriptorSet _w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, &_was, set, 0, 0, 1, VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR }; \
    vkUpdateDescriptorSets(device, 1, &_w, 0, NULL); \
    memset(result_buf.data, 0xEE, 16); \
    CHECK(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer"); \
    CHECK(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer"); \
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline); \
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout, 0, 1, &set, 0, NULL); \
    vkCmdDispatch(cmd, 1, 1, 1); \
    CHECK(vkEndCommandBuffer(cmd), "vkEndCommandBuffer (trace)"); \
    CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit (trace)"); \
    CHECK(vkQueueWaitIdle(queue), "vkQueueWaitIdle"); \
    memcpy(&r, result_buf.data, sizeof(r)); \
    printf("%s: ray at the triangle %s, distance %.3f, custom index %u; ray past it %s\n", what, r.hit == 1 ? "hit" : "no hit", r.t, r.custom, r.miss == 0 ? "no hit" : "hit"); \
    if (r.hit != 1 || r.miss != 0) FAIL("%s: the rays did not report the expected hit and miss", what); \
    if (r.t < (want_t) - 0.01f || r.t > (want_t) + 0.01f) FAIL("%s: the hit distance should be %.1f", what, (double)(want_t)); \
    if (r.custom != (want_custom)) FAIL("%s: the instance custom index should be %u", what, (unsigned)(want_custom)); \
} while (0)
/* Records with the statement in between, submits and waits. */
#define RUN(what, record) do { \
    CHECK(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer"); \
    CHECK(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer"); \
    record; \
    CHECK(vkEndCommandBuffer(cmd), "vkEndCommandBuffer (" what ")"); \
    CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit (" what ")"); \
    CHECK(vkQueueWaitIdle(queue), "vkQueueWaitIdle"); \
} while (0)

    TRACE(tlas, "built in a command buffer", 5.0f, 42);

    /* 5. Compacted size, then a compacting copy. */
    VkQueryPoolCreateInfo qpi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, NULL, 0, VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR, 1 };
    VkQueryPool compact_pool; CHECK(vkCreateQueryPool(device, &qpi, NULL, &compact_pool), "vkCreateQueryPool (compacted size)");
    RUN("compacted size", (vkCmdResetQueryPool(cmd, compact_pool, 0, 1),
                           vkCmdWriteAccelerationStructuresPropertiesKHR(cmd, 1, &blas, VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR, compact_pool, 0)));
    VkDeviceSize compact_size = 0;
    CHECK(vkGetQueryPoolResults(device, compact_pool, 0, 1, sizeof(compact_size), &compact_size, sizeof(compact_size), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT), "vkGetQueryPoolResults (compacted size)");
    VkDeviceSize host_compact_size = 0;
    CHECK(vkWriteAccelerationStructuresPropertiesKHR(device, 1, &blas, VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR, sizeof(host_compact_size), &host_compact_size, sizeof(host_compact_size)), "vkWriteAccelerationStructuresPropertiesKHR");
    printf("compacted size: %llu in a command buffer, %llu on the host (built as %llu)\n", (unsigned long long)compact_size, (unsigned long long)host_compact_size, (unsigned long long)bsz.accelerationStructureSize);
    if (!compact_size || compact_size > bsz.accelerationStructureSize || compact_size != host_compact_size) FAIL("the compacted size is not plausible");
    Buffer blas2_buf; if (!make_buffer(compact_size, storage, 0, &blas2_buf)) FAIL("could not make the compacted storage buffer");
    aci.buffer = blas2_buf.buffer; aci.size = compact_size; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
    VkAccelerationStructureKHR blas2; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &blas2), "vkCreateAccelerationStructureKHR (compacted)");
    VkCopyAccelerationStructureInfoKHR cpy = { VK_STRUCTURE_TYPE_COPY_ACCELERATION_STRUCTURE_INFO_KHR, NULL, blas, blas2, VK_COPY_ACCELERATION_STRUCTURE_MODE_COMPACT_KHR };
    RUN("compacting copy", vkCmdCopyAccelerationStructureKHR(cmd, &cpy));

    /* 6. Serialize the compacted structure in a command buffer, and read it back into a new one. */
    qpi.queryType = VK_QUERY_TYPE_ACCELERATION_STRUCTURE_SERIALIZATION_SIZE_KHR;
    VkQueryPool serial_pool; CHECK(vkCreateQueryPool(device, &qpi, NULL, &serial_pool), "vkCreateQueryPool (serialization size)");
    RUN("serialization size", (vkCmdResetQueryPool(cmd, serial_pool, 0, 1),
                               vkCmdWriteAccelerationStructuresPropertiesKHR(cmd, 1, &blas2, VK_QUERY_TYPE_ACCELERATION_STRUCTURE_SERIALIZATION_SIZE_KHR, serial_pool, 0)));
    VkDeviceSize serial_size = 0;
    CHECK(vkGetQueryPoolResults(device, serial_pool, 0, 1, sizeof(serial_size), &serial_size, sizeof(serial_size), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT), "vkGetQueryPoolResults (serialization size)");
    if (serial_size < 56) FAIL("the serialization size %llu is too small to hold the header", (unsigned long long)serial_size);
    Buffer serial_buf; if (!make_buffer(serial_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 1, &serial_buf)) FAIL("could not make the serialization buffer");
    memset(serial_buf.data, 0, serial_size);
    VkCopyAccelerationStructureToMemoryInfoKHR to_mem = { VK_STRUCTURE_TYPE_COPY_ACCELERATION_STRUCTURE_TO_MEMORY_INFO_KHR, NULL, blas2 };
    to_mem.dst.deviceAddress = serial_buf.address; to_mem.mode = VK_COPY_ACCELERATION_STRUCTURE_MODE_SERIALIZE_KHR;
    RUN("serialize", vkCmdCopyAccelerationStructureToMemoryKHR(cmd, &to_mem));
    /* The header Vulkan defines: two UUIDs, then the serialized size, the size to create, and a handle count. */
    uint64_t hdr[3]; memcpy(hdr, (char *)serial_buf.data + 32, sizeof(hdr));
    printf("serialized: %llu bytes, header says %llu bytes, deserialized size %llu, %llu handles\n", (unsigned long long)serial_size, (unsigned long long)hdr[0], (unsigned long long)hdr[1], (unsigned long long)hdr[2]);
    if (hdr[0] != serial_size || !hdr[1] || hdr[2] != 0) FAIL("the serialized header is wrong");
    VkAccelerationStructureVersionInfoKHR ver = { VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_VERSION_INFO_KHR, NULL, serial_buf.data };
    VkAccelerationStructureCompatibilityKHR compat = VK_ACCELERATION_STRUCTURE_COMPATIBILITY_INCOMPATIBLE_KHR;
    vkGetDeviceAccelerationStructureCompatibilityKHR(device, &ver, &compat);
    if (compat != VK_ACCELERATION_STRUCTURE_COMPATIBILITY_COMPATIBLE_KHR) FAIL("the serialized structure is reported as incompatible");
    Buffer blas3_buf; if (!make_buffer(hdr[1], storage, 0, &blas3_buf)) FAIL("could not make the deserialized storage buffer");
    aci.buffer = blas3_buf.buffer; aci.size = hdr[1];
    VkAccelerationStructureKHR blas3; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &blas3), "vkCreateAccelerationStructureKHR (deserialized)");
    VkCopyMemoryToAccelerationStructureInfoKHR from_mem = { VK_STRUCTURE_TYPE_COPY_MEMORY_TO_ACCELERATION_STRUCTURE_INFO_KHR };
    from_mem.src.deviceAddress = serial_buf.address; from_mem.dst = blas3; from_mem.mode = VK_COPY_ACCELERATION_STRUCTURE_MODE_DESERIALIZE_KHR;
    RUN("deserialize", vkCmdCopyMemoryToAccelerationStructureKHR(cmd, &from_mem));
    adi.accelerationStructure = blas3;
    VkDeviceAddress blas3_address = vkGetAccelerationStructureDeviceAddressKHR(device, &adi);

    /* 7. A top-level structure built on the host, over the structure that was just read back. */
    inst.instanceCustomIndex = 7; inst.accelerationStructureReference = blas3_address;
    ig.geometry.instances.data.hostAddress = &inst;
    Buffer tlas2_buf; if (!make_buffer(tsz.accelerationStructureSize, storage, 0, &tlas2_buf)) FAIL("could not make a top-level storage buffer");
    aci.buffer = tlas2_buf.buffer; aci.size = tsz.accelerationStructureSize; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    VkAccelerationStructureKHR tlas2; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &tlas2), "vkCreateAccelerationStructureKHR (host top)");
    void *host_scratch = malloc(tsz.buildScratchSize + bsz.buildScratchSize + 4096);
    tbi.dstAccelerationStructure = tlas2; tbi.scratchData.hostAddress = host_scratch;
    CHECK(vkBuildAccelerationStructuresKHR(device, VK_NULL_HANDLE, 1, &tbi, &ranges), "vkBuildAccelerationStructuresKHR (top)");
    TRACE(tlas2, "compacted, serialized, read back, instanced on the host", 5.0f, 7);

    /* 8. Serialize that top-level structure on the host. Its one handle is the bottom-level structure. */
    VkDeviceSize tserial_size = 0;
    CHECK(vkWriteAccelerationStructuresPropertiesKHR(device, 1, &tlas2, VK_QUERY_TYPE_ACCELERATION_STRUCTURE_SERIALIZATION_SIZE_KHR, sizeof(tserial_size), &tserial_size, sizeof(tserial_size)), "vkWriteAccelerationStructuresPropertiesKHR (serialization size)");
    if (tserial_size < 64) FAIL("the top-level serialization size %llu is too small", (unsigned long long)tserial_size);
    uint64_t *tserial = calloc(1, tserial_size);
    VkCopyAccelerationStructureToMemoryInfoKHR to_host = { VK_STRUCTURE_TYPE_COPY_ACCELERATION_STRUCTURE_TO_MEMORY_INFO_KHR, NULL, tlas2 };
    to_host.dst.hostAddress = tserial; to_host.mode = VK_COPY_ACCELERATION_STRUCTURE_MODE_SERIALIZE_KHR;
    CHECK(vkCopyAccelerationStructureToMemoryKHR(device, VK_NULL_HANDLE, &to_host), "vkCopyAccelerationStructureToMemoryKHR");
    printf("top-level serialized on the host: %llu bytes, %llu handle(s), first %s the bottom-level structure\n", (unsigned long long)tserial[4], (unsigned long long)tserial[6], tserial[7] == blas3_address ? "is" : "IS NOT");
    if (tserial[4] != tserial_size || tserial[6] != 1 || tserial[7] != blas3_address) FAIL("the top-level serialized header is wrong");

    /* 9. A bottom-level structure built on the host from plain memory: the same triangle, two units further away. */
    static const float far_vertices[] = { -1.0f, -1.0f, 2.0f,   1.0f, -1.0f, 2.0f,   0.0f, 1.0f, 2.0f };
    tri.geometry.triangles.vertexData.hostAddress = far_vertices; tri.geometry.triangles.indexData.hostAddress = indices;
    Buffer blas4_buf; if (!make_buffer(bsz.accelerationStructureSize, storage, 0, &blas4_buf)) FAIL("could not make a bottom-level storage buffer");
    aci.buffer = blas4_buf.buffer; aci.size = bsz.accelerationStructureSize; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
    VkAccelerationStructureKHR blas4; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &blas4), "vkCreateAccelerationStructureKHR (host bottom)");
    bbi.dstAccelerationStructure = blas4; bbi.scratchData.hostAddress = host_scratch;
    CHECK(vkBuildAccelerationStructuresKHR(device, VK_NULL_HANDLE, 1, &bbi, &ranges), "vkBuildAccelerationStructuresKHR (bottom)");
    adi.accelerationStructure = blas4;
    VkDeviceAddress blas4_address = vkGetAccelerationStructureDeviceAddressKHR(device, &adi);

    /* 10. Read the serialized top-level structure back on the host, with its handle pointed at the new one. */
    tserial[7] = blas4_address;
    Buffer tlas3_buf; if (!make_buffer(tserial[5], storage, 0, &tlas3_buf)) FAIL("could not make a top-level storage buffer");
    aci.buffer = tlas3_buf.buffer; aci.size = tserial[5]; aci.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    VkAccelerationStructureKHR tlas3; CHECK(vkCreateAccelerationStructureKHR(device, &aci, NULL, &tlas3), "vkCreateAccelerationStructureKHR (read back top)");
    VkCopyMemoryToAccelerationStructureInfoKHR from_host = { VK_STRUCTURE_TYPE_COPY_MEMORY_TO_ACCELERATION_STRUCTURE_INFO_KHR };
    from_host.src.hostAddress = tserial; from_host.dst = tlas3; from_host.mode = VK_COPY_ACCELERATION_STRUCTURE_MODE_DESERIALIZE_KHR;
    CHECK(vkCopyMemoryToAccelerationStructureKHR(device, VK_NULL_HANDLE, &from_host), "vkCopyMemoryToAccelerationStructureKHR");
    TRACE(tlas3, "top level read back on the host over a host-built triangle", 7.0f, 7);

    printf("raytracing: ok\n");
    return 0;
}
