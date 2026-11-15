#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"

layout(location = 0) rayPayloadInEXT Payload payload;
hitAttributeEXT vec3 normal;

void main()
{
    payload.t = gl_HitTEXT;
    payload.custom = uint(gl_InstanceCustomIndexEXT);
    payload.marker = 3u;
    payload.extra = normal.z;
    payload.aux = gl_HitKindEXT;
}
