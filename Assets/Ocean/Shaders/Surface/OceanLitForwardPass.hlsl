#ifndef OCEAN_LIT_PASS_INCLUDED
#define OCEAN_LIT_PASS_INCLUDED


#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

//#include "Voronoi.hlsl"
#include "OceanLitInput.hlsl"//it will be excluded, it's mostly to help Rider



struct Attributes
{
    float4 positionOS : POSITION;
    float2 uv : TEXCOORD0;
    float2 lightmapUV : TEXCOORD1;
                
    //UNITY_VERTEX_INPUT_INSTANCE_ID 
};
struct ControlPoint
{
    float4 positionOS : INTERNALTESSPOS;
    float2 uv : TEXCOORD0;
    float2 lightmapUV : TEXCOORD1;

                
};
struct Varyings
{
    float4 positionCS : SV_POSITION;
    float2 uv : TEXCOORD0;
    DECLARE_LIGHTMAP_OR_SH(lightmapUV,vertexSH,1);//this trips up rider
    float3 positionWS : TEXCOORD2;//possibly useful, but I'd like it removed
    half3 normalWS : TEXCOORD3;
    half3 normalOS :TEXCOORD5;
    //I could pack normals here and interpolate them
    #ifdef _ADDITIONAL_LIGHTS_VERTEX
    half4 fogFactorAndVertexLight : TEXCOORD6;
    #else
    half fogFactor : TEXCOORD6;
    #endif
    #ifdef REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR
    float4 shadowCoord : TEXCOORD7;
    #endif
    
};
//almost certain you can just pass attributes down the chain
ControlPoint TesselationVertexProgram(Attributes v)
{
    ControlPoint p;
    p.positionOS = v.positionOS;
    p.uv = v.uv;
    p.lightmapUV = v.lightmapUV;
    // p.dynamicLightmapUV = v.dynamicLightmapUV;
    // p.staticLightmapUV = v.staticLightmapUV;
    return  p;
}
struct TesselationFactors
{
    float edge[3] : SV_TessFactor;//Tesselation factors must be declared as arrays and don't work as vectors, probably to work with quads as well
    float inside : SV_InsideTessFactor;
};
float CalcDistanceTessFactor(float4 vertex, float minDist, float maxDist,float tess)
{
    const float3 worldPos = mul(unity_ObjectToWorld,vertex).xyz;
    const float dist = distance(worldPos,GetCameraPositionWS());
    const float f = clamp(1.0 -(dist - minDist)/(maxDist - minDist),0.01,1.0)*tess;
    return f;
}
TesselationFactors patchConstantFunction(InputPatch<ControlPoint,3> patch)
{
    const float minDist = 5.0;//move to uniform
    const float maxDist = _MaxTessDistance;

    TesselationFactors f;

    const float edge0 = CalcDistanceTessFactor(patch[0].positionOS, minDist, maxDist, _Tess);
    const float edge1 = CalcDistanceTessFactor(patch[1].positionOS, minDist, maxDist, _Tess);
    const float edge2 = CalcDistanceTessFactor(patch[2].positionOS, minDist, maxDist, _Tess);

    f.edge[0] = (edge1 + edge2)/2;
    f.edge[1] = (edge2 + edge0)/2;
    f.edge[2] = (edge0 + edge1)/2;
    f.inside = (edge0 + edge1 + edge2)/3;
    return f;
}
[domain("tri")]//triangle patch
[outputcontrolpoints(3)]
[outputtopology("triangle_cw")]//clock wise patch
[partitioning("fractional_odd")]
[patchconstantfunc("patchConstantFunction")]//function called to generate the inputs
ControlPoint hull(InputPatch<ControlPoint,3> patch, uint id : SV_OutputControlPointID)
{
    return patch[id];
}
float normalFiltering;
Varyings vert (Attributes input)
{
    
    Varyings output;
    
    
    output.uv = TRANSFORM_TEX(input.uv,_DataTextureArray);
    //data sampling, computing the normal on a map could halve these samples
    float4 Data0 = _DataTextureArray.SampleLevel(bilinear_clamp_sampler,float3(input.uv,0),0);
    float4 Data1 = _DataTextureArray.SampleLevel(bilinear_clamp_sampler,float3(input.uv,1),0);
    float4 Data2 = _DataTextureArray.SampleLevel(bilinear_clamp_sampler,float3(input.uv,2),0);
    float4 Data3 = _DataTextureArray.SampleLevel(bilinear_clamp_sampler,float3(input.uv,3),0);
    
    float3 Displacement = float3(Data0.x,Data0.z,Data1.x);
    Displacement.y *= _HeightScaleFactor;
    Displacement.xz *= _HorizontalScaleDampening;
    VertexPositionInputs position_inputs = GetVertexPositionInputs(input.positionOS.xyz + Displacement);
    output.positionWS = position_inputs.positionWS;
    output.positionCS = position_inputs.positionCS;

    //normal calculation likely faulty
    const float Y_dx = Data2.x* _HeightScaleFactor;
    const float X_dx = Data1.z* _HorizontalScaleDampening;
    const float Y_dz = Data3.x* _HeightScaleFactor;
    const float Z_dz = Data3.z* _HorizontalScaleDampening;
    const float3 normalOS = normalize(float3((Y_dx/(1+X_dx))*10.0f,1,10.0f*(Y_dz/(1+Z_dz))));
    
    VertexNormalInputs normal_inputs = GetVertexNormalInputs(normalOS);

    half fogFactor = ComputeFogFactor(position_inputs.positionCS.z);

    output.normalWS = NormalizeNormalPerVertex(normal_inputs.normalWS);
    output.normalOS = normalOS;
    //not 100% sure these are useful, hopefully they work with tesselation
    OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST,output.lightmapUV);
    OUTPUT_SH(output.normalWS.xyz,output.vertexSH);//used for light probes
    #ifdef _ADDITIONAL_LIGHTS_VERTEX
    half3 vertexLight = VertexLighting(position_inputs.positionWS,normal_inputs.normalWS);
    output.fogFactorAndVertexLight = half4(fogFactor, vertexLight);
    #else
    output.fogFactor = fogFactor;
    #endif
    
    
    #ifdef REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATION
    output.shadowCoord = GetShadowCoord(position_inputs);
    #endif
    return output;
}
[domain("tri")]
Varyings domain(TesselationFactors factors, OutputPatch<ControlPoint,3> patch, float3 barycentricCoordinates : SV_DomainLocation)
{
    Attributes v;
    //very useful trick if swizzling isn't available
    #define DomainCalc(fieldName) v.fieldName = \
        patch[0].fieldName * barycentricCoordinates.x + \
        patch[1].fieldName * barycentricCoordinates.y + \
        patch[2].fieldName * barycentricCoordinates.z;
                
    DomainCalc(positionOS)
    DomainCalc(uv)
    DomainCalc(lightmapUV)
    return vert(v);
}

float NormalVis;
float TangentVis;
half4 frag (Varyings IN) : SV_Target
{
    SurfaceData surface_data = (SurfaceData)0;
    surface_data.albedo = _Color.rgb;
    surface_data.alpha = _Opacity;
    surface_data.normalTS = SampleNormal(IN.uv,TEXTURE2D_ARGS(_BumpMap,sampler_BumpMap),1 );
    surface_data.emission = half3(0,0,0);
    surface_data.occlusion = 1.0h;//ignoring occlusion for now
    #if _SPECULAR_SETUP
    surface_data.metallic = 1.0h;
    surface_data.specular = _SpecGloss.rgb;
    #else
    surface_data.metallic = _SpecGloss.r;
    #endif
    surface_data.smoothness = _Smoothness;

    InputData inputData = (InputData)0;
    inputData.positionWS = IN.positionWS;
    inputData.viewDirectionWS = SafeNormalize(GetWorldSpaceViewDir(IN.positionWS));
    inputData.normalWS = NormalizeNormalPerPixel(IN.normalOS);
    #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    inputData.shadowCoord = IN.shadowCoord;//for some reason unity trips up on this
    #elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
    #else
    inputData.shadowCoord = float4(0, 0, 0, 0);
    #endif

    #ifdef _ADDITIONAL_LIGHTS_VERTEX
    inputData.fogCoord = IN.fogFactorAndVertexLight.x;
    inputData.vertexLighting = IN.fogFactorAndVertexLight.yzw;
    #else
    inputData.fogCoord = IN.fogFactor;
    inputData.vertexLighting = half3(0, 0, 0);
    #endif
    inputData.bakedGI = SAMPLE_GI(IN.lightmapUV,IN.vertexSH,inputData.normalWS);
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(IN.positionCS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(IN.lightmapUV);

    half4 color = UniversalFragmentPBR(inputData,surface_data);
    color.rgb = MixFog(color.rgb, inputData.fogCoord);
    return NormalVis ? float4(IN.normalWS.r,0,0,1) : color;
}
#endif