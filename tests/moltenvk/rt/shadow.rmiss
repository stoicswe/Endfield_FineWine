#version 460
#extension GL_EXT_ray_tracing : require

// The miss shader of the secondary ray: nothing was in the way.
layout(location = 1) rayPayloadInEXT float visible;

void main()
{
    visible = 1.0;
}
