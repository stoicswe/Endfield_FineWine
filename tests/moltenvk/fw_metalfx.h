/* fw_metalfx.h: the request FineWine's MoltenVK takes through vkCmdPushConstants().
 *
 * A copy of MVKMetalFXRequest in patches/moltenvk (Commands/MVKCmdMetalFX.h); keep the two the
 * same. vkCmdPushConstants(cmd, VK_NULL_HANDLE, FW_METALFX_MAGIC, 0, sizeof(request), &request)
 * records a MetalFX upscale or frame interpolation at that point of the command buffer. */
#ifndef FW_METALFX_H
#define FW_METALFX_H
#include <stdint.h>

#define FW_METALFX_MAGIC 0x584D5746u    /* "FWMX", as the stage flags */

enum { FW_METALFX_TEMPORAL_UPSCALE = 1, FW_METALFX_FRAME_INTERPOLATE = 2, FW_METALFX_RELEASE = 3 };
enum { FW_METALFX_DEPTH_REVERSED = 1, FW_METALFX_AUTO_EXPOSURE = 2, FW_METALFX_RESET_HISTORY = 4, FW_METALFX_MOTION_AT_OUTPUT_SIZE = 8 };

typedef struct FWMetalFXRequest {
    uint32_t size, operation, flags, reserved;
    uint64_t feature;
    uint64_t color, depth, motion, exposure, output;    /* VkImage handles */
    uint32_t inputWidth, inputHeight;
    float jitterX, jitterY, motionScaleX, motionScaleY, preExposure;
    float deltaTime, nearPlane, farPlane, fieldOfView, aspectRatio;
} FWMetalFXRequest;

#endif
