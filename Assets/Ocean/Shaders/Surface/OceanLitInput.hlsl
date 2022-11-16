#ifndef OCEAN_LIT_INPUT
#define OCEAN_LIT_INPUT
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceInput.hlsl"


CBUFFER_START(UnityPerMaterial)//actually probably don't need batching and should instead split this in multiple buffers to limit data transfers
float _MaxTessDistance = 70.0f;
float _Tess;//intensity of the effect ?
float _Weight = 10.0f;
float _HeightScaleFactor;
float _HorizontalScaleDampening;// ideally it should be dependant on the local vertex density
float _Opacity;
half4 _Color;
CBUFFER_END

//Skipping all dots stuff

//here there is a "specular setup" using textures

//lit template has a whole include file, i just need my one texture
sampler2D _MainTex;
float4 _MainTex_ST;

//the urp lit also has all helper sampling function here



inline void InitializeOceanLitSurfaceData(float2 uv, out SurfaceData outSurfaceData, half3 normalTS)
{
    
    outSurfaceData.alpha = _Opacity;
    outSurfaceData.albedo = _Color.rgb;
    half4 specGloss = half4(1.0h,1.0h,1.0h,_Opacity);
    outSurfaceData.metallic = 1.0h;
    outSurfaceData.specular = specGloss.rgb;

    outSurfaceData.smoothness = 1.0h;
    outSurfaceData.normalTS = half3(0.0h,0.0h,0.0h);
    outSurfaceData.occlusion = 1.0h;
    outSurfaceData.emission = half3(0.0h,0.0h,0.0h);

    outSurfaceData.clearCoatMask = 0.0h;
    outSurfaceData.clearCoatSmoothness = 0.0h;

    
}
#endif