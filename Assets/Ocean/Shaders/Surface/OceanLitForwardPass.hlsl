﻿#ifndef OCEAN_LIT_PASS_INCLUDED
#define OCEAN_LIT_PASS_INCLUDED
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Voronoi.hlsl"
#include "OceanLitInput.hlsl"//it will be excluded, it's mostly to help Rider
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ParallaxMapping.hlsl"

struct Attributes
{
    float4 positionOS : POSITION;
    float2 uv : TEXCOORD0;
    float3 normalOS : NORMAL;
    float4 tangentOS : TANGENT;
    float2 staticLightmapUV   : TEXCOORD1;
    float2 dynamicLightmapUV  : TEXCOORD2;
                
    //UNITY_VERTEX_INPUT_INSTANCE_ID 
};
struct ControlPoint
{
    float4 positionOS : INTERNALTESSPOS;
    float2 uv : TEXCOORD0;
    float3 normalOS : NORMAL;
    float4 tangentOS : TANGENT;
    float2 staticLightmapUV   : TEXCOORD1;
    float2 dynamicLightmapUV  : TEXCOORD2;
    //do not need a color, as it is global
                
};
struct Varyings
{
    float4 positionCS : SV_POSITION;
    float2 uv : TEXCOORD0;
    float3 positionWS : TEXCOORD2;//possibly useful, but I'd like it removed
    float3 normalWS : NORMAL;
    half4 tangentWS : TANGENT;//xyz is the vector, w is a sign
    #ifdef _ADDITIONAL_LIGHTS_VERTEX
    half4 fogFactorAndVertexLight : TEXCOORD5;// x: fogFactor, yzw: vertex light
    #else
    half fogFactor : TEXCOORD5;
    #endif
    half3 viewDirTS : TEXCOORD7;//almost certainly useful
    DECLARE_LIGHTMAP_OR_SH(staticLightmapUV, vertexSH, 8);
    //vertex id can also be included here
};
//almost certain you can just pass attributes down the chain
ControlPoint TesselationVertexProgram(Attributes v)
{
    ControlPoint p;
    p.positionOS = v.positionOS;
    p.uv = v.uv;
    p.normalOS = v.normalOS;
    p.tangentOS = v.tangentOS;
    p.dynamicLightmapUV = v.dynamicLightmapUV;
    p.staticLightmapUV = v.staticLightmapUV;
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

Varyings vert (Attributes input)
{
    Varyings output = (Varyings)0;
    output.uv = TRANSFORM_TEX(input.uv,_DisplacementTex);

    
    float3 Displacement = _DisplacementTex.SampleLevel(sampler_DisplacementTex,output.uv,0);//tex2Dlod(sampler_DisplacementTex,float4(input.uv,0,0)).rgb;
    Displacement.y *= _HeightScaleFactor;
    Displacement.xz *= _HorizontalScaleDampening;
    VertexPositionInputs position_inputs = GetVertexPositionInputs(input.positionOS.xyz + Displacement);
    VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS,input.tangentOS);
    
    output.positionCS = position_inputs.positionCS;
    output.positionWS = position_inputs.positionWS;
    //here I need an ifdef for normal maps. See cyan lit
    
    output.normalWS = normalInputs.normalWS;//need to recalculate normals here
    //this is wrapped in keywords in the lit shader
    real sign = input.tangentOS.w * GetOddNegativeScale();
    output.tangentWS = half4(normalInputs.tangentWS.xyz,sign);
    
    

    const half3 viewDirWS = GetWorldSpaceNormalizeViewDir(position_inputs.positionWS);
    const half3 viewDirTS = GetViewDirectionTangentSpace(output.tangentWS, output.normalWS,viewDirWS);
    output.viewDirTS = viewDirTS;
    half fogFactor = 0;//set to 0 to be computed in the fragment shader
    #ifdef _ADDITIONAL_LIGHTS_VERTEX
    half3 vertexLight = VertexLighting(position_inputs.positionWS,normalInputs.normalWS);
    fogFactorAndVertexLight = half4(fogFactor, vertexLight);
    #else
    output.fogFactor = fogFactor;
    #endif
    //assuming the _FOG_FRAGMENT check is an internal sanity check
    
    //not sure what SH is, possibly just shadows
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
    DomainCalc(normalOS)
    DomainCalc(tangentOS)
    DomainCalc(staticLightmapUV);
    DomainCalc(dynamicLightmapUV);
    return vert(v);
}
void InitializeInputData(Varyings input, half3 normalTS,out InputData inputData)
{
    inputData = (InputData)0;
    inputData.positionWS = input.positionWS;
    const half3 viewDirWS = GetWorldSpaceNormalizeViewDir(input.positionWS);//I already have a call of this at a previous stage
    inputData.normalWS = input.normalWS;
    inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
    inputData.viewDirectionWS = viewDirWS;
    #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    inputData.shadowCoord = input.shadowCoord;
    #elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
    #else
    inputData.shadowCoord = float4(0, 0, 0, 0);
    #endif
    #ifdef _ADDITIONAL_LIGHTS_VERTEX
    inputData.fogCoord = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogFactorAndVertexLight.x);
    inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
    #else
    inputData.fogCoord = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogFactor);
    #endif

    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(staticLightmapUV);
}

half4 frag (Varyings IN) : SV_Target
{
    // float3 pos_dx = ddx(IN.positionWS);
    // float3 pos_dy = ddy(IN.positionWS) * _ProjectionParams.x;
    //
    // IN.normalWS = cross(pos_dx,pos_dy);//this isn't a world normal, probably a clip one(ish)
    // float3 normalTS = TransformWorldToTangent(IN.normalWS,CreateTangentToWorld(IN.normalWS,pos_dx,1.0f));
    //No need for ids
    SurfaceData surface_data;
    InitializeOceanLitSurfaceData(IN.uv,surface_data,IN.normalWS);

    InputData input_data;
    InitializeInputData(IN,surface_data.normalTS,input_data);

    half4 color = UniversalFragmentPBR(input_data,surface_data);
    
    color.rgb = MixFog(color.rgb, input_data.fogCoord);
    //color = half4(IN.normalWS,_Opacity);
    return color;
}
#endif