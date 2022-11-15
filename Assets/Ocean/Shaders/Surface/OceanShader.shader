Shader "Custom/OceanShader"
{
    Properties
    {
        _MainTex ("Displacement Texture", 2D) = "white" {}
        _Color ("MainColor", Color) =  (.5,.5,.5,1)
        _Weight ("Displacement amount", Range(0,1)) = 0
        _MaxTessDistance("Max Tess distance", Range(1,32)) = 20
        _Tess("Tesselation",Range(1,32)) = 20
        _HeightScaleFactor("Height scale", Range(0,32)) = 5
        _HorizontalScaleDampening("Horizontal Factor", Range(0,1)) = 0.5
        _Opacity("Opactiy", Range(0,1)) = 0.7
        [Toggle(_NORMALMAP)] _NormalMapToggle("Normal maps mode", Float) = 0
    }
    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderPipeline" = "UniversalRenderPipeline" }
        LOD 100

        Pass
        {
            Blend SrcAlpha OneMinusSrcAlpha //"traditional" transparency
            BlendOp Add
            HLSLPROGRAM
            #pragma vertex TesselationVertexProgram
            #pragma fragment frag
            #pragma hull hull
            #pragma domain domain
            //pragmas founds in https://github.com/Cyanilux/URP_ShaderCodeTemplates/blob/main/URP_SimpleLitTemplate.shader
            //material keywords
            #pragma shader_feature_local _RECEIVE_SHADOWS_OFF
            #pragma shader_feature_local _NORMALMAP//might need it eventually
            //URP keywords
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _SHADOWS_SOFT
			// #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            //no light map support for now
			//#pragma multi_compile _ LIGHTMAP_SHADOW_MIXING // v10+ only, renamed from "_MIXED_LIGHTING_SUBTRACTIVE"
			//#pragma multi_compile _ SHADOWS_SHADOWMASK // v10+ only
            #define _SPECULAR_COLOR //always on in the template, remove if not referenced by URP code
            

            
            //VFACE semantic can be used to flip normal when seeing the water surface through itself. However, I'm skeptical that SoT does it this way and the "back" of the water must be shaded another way.
            //Z ordering: if I'm rendering a 
            //are specular lights in SoT faked ?(rn surface is unlit)
            //"crest" detection ? SoT has a smooth transition to it's lighter and textured crests, probably need to pass the information in the fragment input
            //Tesselation benchmark (there's probably a lot of room to optimize while keeping the look of SoT, quite difficult to retro engineer)
            //I might need to generate a normal map from the displacement maps for specular reflections
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceInput.hlsl"
            //pre tesselation output. Suspicious that the only difference is semantics
            struct ControlPoint
            {
                float4 positionOS : INTERNALTESSPOS;
                float2 uv : TEXCOORD0;
                float3 normalOS : NORMAL;
                #ifdef _NORMALMAP
                float4 tangentOS : TANGENT;
                #endif
                //do not need a color, as it is global
                
            };
            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float3 normalOS : NORMAL;
                #ifdef _NORMALMAP
                float4 tangentOS : TANGENT;
                #endif
                //do not need a color, as it is global
                
                //UNITY_VERTEX_INPUT_INSTANCE_ID //mentionned by Cyanilux, leaving it here for reference, it could be useful
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                //here Cyan uses a lightmap related macro, skipping it for now
                float3 positionWS : TEXCOORD2;//possibly useful, but I'd like it removed
               
                float3 normalWS : NORMAL;
                float3 tangentWS : TANGENT;
                //float3 bitangentWS : BITANGENT;
                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPLATOR)
                float4 shadowCoord : TEXCOORD7;
                #endif
                //vertex id can also be included here
            };
            CBUFFER_START(UnityPerMaterial)//actually probably don't need batching and should instead split this in multiple buffers to limit data transfers
            float _MaxTessDistance = 70.0f;
            float _Tess;//intensity of the effect ?
            float _Weight = 10.0f;
            float _HeightScaleFactor;
            float _HorizontalScaleDampening;// ideally it should be dependant on the local vertex density
            float _Opacity;
            half4 _Color;
            CBUFFER_END
            
            sampler2D _MainTex;
            float4 _MainTex_ST;
            //Surely you can get rid of this stage and just use the inital input with correct semantics
            ControlPoint TesselationVertexProgram(Attributes v)
            {
                ControlPoint p;
                p.positionOS = v.positionOS;
                p.uv = v.uv;
                p.normalOS = v.normalOS;
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
            
            //templates have 2 includes that cannot be found
            Varyings vert (Attributes input)
            {
                Varyings output;
                float3 Displacement = tex2Dlod(_MainTex, float4(input.uv,0,0)).rgb;
                Displacement.y *= _HeightScaleFactor;
                Displacement.xz *= _HorizontalScaleDampening;
                VertexPositionInputs position_inputs = GetVertexPositionInputs(input.positionOS.xyz + Displacement);
                #ifdef _NORMALMAP
					VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS.xyz, input.tangentOS);
				#else
					VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS.xyz);
				#endif
                
                
                
                output.positionCS = position_inputs.positionCS;
                output.positionWS = position_inputs.positionWS;
                //here I need an ifdef for normal maps. See cyan lit
                output.normalWS = NormalizeNormalPerVertex(normalInputs.normalWS);
                output.tangentWS = NormalizeNormalPerVertex(normalInputs.tangentWS);
                //output.bitangentWS = NormalizeNormalPerVertex(normalInputs.bitangentWS);
                output.uv = input.uv;
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
                #ifdef _NORMALMAP
                DomainCalc(tangentOS)
                #endif
                
                return vert(v);
            }

            float2 randomVector(float2 UV)//taken from shader graph doc
            {
                float2x2 m = float2x2(15.27,47.63,99.41,89.98);
                UV = frac(sin(mul(UV,m)) * 46839.32);
                return float2(sin(UV.y)*0.5+0.5,cos(UV.x)*0.5+0.5);//removed offset, the fact that the shown code is wrong is a little worrying
            }

            void voronoi(const float2 UV,const float CellDensity, out float noiseValue)//Removed the double output, don't need the cells. A bit worried by the code output by shader graph
            {
                
                float2 g = floor(UV * CellDensity);
                float2 f = frac (UV * CellDensity);
                
                noiseValue = 8.0;//init
                
                for(int y = -1; y<=1;y++)//this should get unrolled by the compiler
                {
                    for(int x = -1;x <=1;x++)
                    {
                        const float2 lattice = float2(x,y);
                        const float2 offset = randomVector(lattice + g);
                        const float d = distance(lattice+ offset,f);
                        if(d<noiseValue)
                        {
                            noiseValue = d;
                        }
                    }
                }
            }
            
            void CrestShading(Varyings IN, inout half4 col)
            {
                //Can't generate the noise here without the whole cell system
                //Y displacement threshold, easy but naive, and probably not pretty
                //dY displacement threshold, more expensive, and makes areas between waves are to sort out from the crests
                
            }
            
            
            half4 frag (Varyings IN) : SV_Target
            {
                //all of this smells like a complicated cast, probably can be avoided with good semantics
                SurfaceData surface_data = (SurfaceData)0;
                //"initialize surface data"
                surface_data.alpha = _Opacity;
                surface_data.albedo = _Color.rgb;
                surface_data.normalTS = TransformWorldToTangent(IN.normalWS,CreateTangentToWorld(IN.normalWS,IN.tangentWS,1));
                surface_data.metallic = 1.0h;
                //wild guess about what would be on a gloss map
                surface_data.specular = half3(1.0h,1.0h,1.0h);//might need to just be white
                surface_data.smoothness = 1.0h;

                InputData input_data = (InputData)0;
                input_data.positionWS = IN.positionWS;

                half3 viewDirWS = GetWorldSpaceNormalizeViewDir(input_data.positionWS);
                input_data.normalWS = IN.normalWS;
                viewDirWS = SafeNormalize(viewDirWS);
                input_data.viewDirectionWS = viewDirWS;
                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPLATOR)
                input_data.shadowCoord = IN.shadowCoord;
                #elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
                input_data.shadowCoord = TransformWorldToShadowCoord(input_data.positionWS);
                #else
                input_data.shadowCoord = float4(0,0,0,0);
                #endif
                //ignoring fog

                //ignoring lightmap stuff
                //end of data init
                half4 col = UniversalFragmentBlinnPhong(input_data,surface_data);
                //col.a = _Opacity;
                //ignoring fog
                return col;
            }
            ENDHLSL
        }
    }
}
