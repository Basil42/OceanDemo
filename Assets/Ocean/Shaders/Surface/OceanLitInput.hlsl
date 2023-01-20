
#ifndef OCEAN_LIT_INPUT
#define OCEAN_LIT_INPUT
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceInput.hlsl"

//lit template has a whole include file, i just need my one texture
TEXTURE2D_ARRAY(_DataTextureArray);
SAMPLER(bilinear_clamp_sampler);
SAMPLER(point_clamp_sampler);

CBUFFER_START(UnityPerMaterial)//actually probably don't need batching and should instead split this in multiple buffers to limit data transfers
float _MaxTessDistance = 70.0f;
float _Tess;//intensity of the effect ?
float _HeightScaleFactor;
float _HorizontalScaleDampening;// ideally it should be dependant on the local vertex density
float _Opacity;
float _Smoothness;
half4 _Color;
half4 _SpecGloss;
float4 _DataTextureArray_ST;
float UVOffsetFactor;
CBUFFER_END


#endif