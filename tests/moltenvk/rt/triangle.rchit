#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"

// Reports the hit, reads a value from its shader record, and traces a second ray back the way
// the first came, which hits nothing.
layout(location = 0) rayPayloadInEXT Payload payload;
layout(location = 1) rayPayloadEXT float visible;
hitAttributeEXT vec2 bary;
layout(shaderRecordEXT) buffer Record { float bias; } record;
layout(set = 0, binding = 0) uniform accelerationStructureEXT scene;

void main()
{
    payload.t = gl_HitTEXT;
    payload.custom = uint(gl_InstanceCustomIndexEXT);
    payload.marker = 1u + uint(gl_PrimitiveID) + (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT ? 0u : 10u);
    payload.aux = uint(bary.y * 100.0 + 0.5);
    visible = 0.0;
    vec3 p = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;
    traceRayEXT(scene, gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT, 0xFF, 0, 0, 1,
                p, 0.01, vec3(0.0, 0.0, -1.0), 50.0, 1);
    payload.extra = visible + record.bias;
}
