/* vulkan-device.c: loads vulkan-1.dll the way a Windows game does, creates an instance, finds
 * the GPU and creates a logical device. Uses its own minimal declarations so it builds without
 * the Vulkan SDK. Prints the GPU and "vulkan-device: ok" on success. */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

typedef struct { int sType; const void *pNext; const char *name; uint32_t appVersion; const char *engine; uint32_t engineVersion; uint32_t apiVersion; } AppInfo;
typedef struct { int sType; const void *pNext; uint32_t flags; const AppInfo *app; uint32_t layerCount; const char *const *layers; uint32_t extCount; const char *const *exts; } InstanceInfo;
typedef struct { int sType; const void *pNext; uint32_t flags; uint32_t family; uint32_t count; const float *priorities; } QueueInfo;
typedef struct { int sType; const void *pNext; uint32_t flags; uint32_t queueCount; const QueueInfo *queues; uint32_t layerCount; const char *const *layers; uint32_t extCount; const char *const *exts; const void *features; } DeviceInfo;
typedef struct { uint32_t flags, count, timestampBits, extent[3]; } QueueFamily;
typedef struct { uint32_t apiVersion, driverVersion, vendorID, deviceID, deviceType; char name[256]; unsigned char rest[1024]; } GpuProps;

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    HMODULE vk = LoadLibraryA("vulkan-1.dll");
    if (!vk) { printf("vulkan-device: vulkan-1.dll did not load (%lu)\n", GetLastError()); return 1; }
#define FN(ret, name, args) ret (WINAPI *name) args = (void *)GetProcAddress(vk, #name); if (!name) { printf("vulkan-device: no " #name "\n"); return 1; }
    FN(int, vkCreateInstance, (const InstanceInfo *, const void *, void **))
    FN(int, vkEnumeratePhysicalDevices, (void *, uint32_t *, void **))
    FN(void, vkGetPhysicalDeviceProperties, (void *, GpuProps *))
    FN(void, vkGetPhysicalDeviceQueueFamilyProperties, (void *, uint32_t *, QueueFamily *))
    FN(int, vkCreateDevice, (void *, const DeviceInfo *, const void *, void **))
    FN(void, vkDestroyDevice, (void *, const void *))
    FN(void, vkDestroyInstance, (void *, const void *))

    AppInfo app = { 0 /* APPLICATION_INFO */, NULL, "finewine-test", 1, "none", 1, (1u << 22) | (1u << 12) /* 1.1 */ };
    InstanceInfo info = { 1 /* INSTANCE_CREATE_INFO */, NULL, 0, &app };
    void *instance = NULL, *gpus[8] = {0}, *device = NULL;
    int r = vkCreateInstance(&info, NULL, &instance);
    if (r) { printf("vulkan-device: vkCreateInstance failed %d\n", r); return 1; }

    uint32_t count = 8;
    r = vkEnumeratePhysicalDevices(instance, &count, gpus);
    if (r < 0 || !count) { printf("vulkan-device: no physical devices (%d)\n", r); return 1; }
    GpuProps props; memset(&props, 0, sizeof(props));
    vkGetPhysicalDeviceProperties(gpus[0], &props);
    printf("gpu: %s (Vulkan %u.%u.%u)\n", props.name, props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff, props.apiVersion & 0xfff);

    QueueFamily families[16]; uint32_t nfam = 16, graphics = ~0u;
    vkGetPhysicalDeviceQueueFamilyProperties(gpus[0], &nfam, families);
    for (uint32_t i = 0; i < nfam; i++) if (families[i].flags & 1 /* GRAPHICS */) { graphics = i; break; }
    if (graphics == ~0u) { printf("vulkan-device: no graphics queue\n"); return 1; }

    float priority = 1.0f;
    QueueInfo queue = { 2 /* DEVICE_QUEUE_CREATE_INFO */, NULL, 0, graphics, 1, &priority };
    DeviceInfo dev = { 3 /* DEVICE_CREATE_INFO */, NULL, 0, 1, &queue };
    r = vkCreateDevice(gpus[0], &dev, NULL, &device);
    if (r) { printf("vulkan-device: vkCreateDevice failed %d\n", r); return 1; }
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    printf("vulkan-device: ok\n");
    return 0;
}
