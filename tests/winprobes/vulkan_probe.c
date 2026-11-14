/* Vulkan through winevulkan → MoltenVK: create an instance and list GPUs.
 * Declares the handful of types it needs so no Vulkan SDK is required. */
#include "probe.h"
#include <stdint.h>

typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef int32_t VkResult;
typedef struct { int sType; const void *pNext; const char *pApplicationName; uint32_t applicationVersion;
                 const char *pEngineName; uint32_t engineVersion; uint32_t apiVersion; } VkApplicationInfo;
typedef struct { int sType; const void *pNext; uint32_t flags; const VkApplicationInfo *pApplicationInfo;
                 uint32_t enabledLayerCount; const char *const *ppEnabledLayerNames;
                 uint32_t enabledExtensionCount; const char *const *ppEnabledExtensionNames; } VkInstanceCreateInfo;
typedef struct { uint32_t apiVersion, driverVersion, vendorID, deviceID; int deviceType; char deviceName[256];
                 uint8_t pipelineCacheUUID[16]; uint8_t rest[1024]; } VkPhysicalDeviceProperties;

typedef VkResult (WINAPI *PFN_vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (WINAPI *PFN_vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (WINAPI *PFN_vkGetPhysicalDeviceProperties)(VkPhysicalDevice, VkPhysicalDeviceProperties *);

int main(void)
{
    probe_name = "vulkan";
    HMODULE vk = LoadLibraryA("vulkan-1.dll");
    if (!vk) FAIL("vulkan-1.dll not loadable");
    PFN_vkCreateInstance createInstance = (PFN_vkCreateInstance)GetProcAddress(vk, "vkCreateInstance");
    PFN_vkEnumeratePhysicalDevices enumDevices = (PFN_vkEnumeratePhysicalDevices)GetProcAddress(vk, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties getProps = (PFN_vkGetPhysicalDeviceProperties)GetProcAddress(vk, "vkGetPhysicalDeviceProperties");
    if (!createInstance || !enumDevices || !getProps) FAIL("missing Vulkan entry points");

    VkApplicationInfo app = {0, NULL, "isthmus-probe", 1, "isthmus", 1, (1u << 22) | (1u << 12)}; /* 1.1 */
    VkInstanceCreateInfo ci = {1, NULL, 0, &app, 0, NULL, 0, NULL};
    VkInstance inst;
    VkResult r = createInstance(&ci, NULL, &inst);
    if (r != 0) FAIL("vkCreateInstance returned %d", r);
    uint32_t n = 0;
    enumDevices(inst, &n, NULL);
    if (n == 0) FAIL("no Vulkan physical devices (is MoltenVK bundled?)");
    VkPhysicalDevice devs[8];
    if (n > 8) n = 8;
    enumDevices(inst, &n, devs);
    VkPhysicalDeviceProperties props;
    getProps(devs[0], &props);
    PASS("%u device(s), \"%s\", api %u.%u", n, props.deviceName, props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff);
    return 0;
}
