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
            //VFACE semantic can be used to flip normal when seeing the water surface through itself. However, I'm skeptical that SoT does it this way and the "back" of the water must be shaded another way.
            //Z ordering: if I'm rendering a 
            //are specular lights in SoT faked ?(rn surface is unlit)
            //"crest" detection ? SoT has a smooth transition to it's lighter and textured crests, probably need to pass the information in the fragment input
            //Tesselation benchmark (there's probably a lot of room to optimize while keeping the look of SoT, quite difficult to retro engineer)
            //I might need to generate a normal map from the displacement maps for specular reflections
            

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            //pre tesselation output. Suspicious that the only difference is semantics
            struct ControlPoint
            {
                float4 vertex : INTERNALTESSPOS;
                float2 uv : TEXCOORD0;
                float3 normal : NORMAL;
            };
            struct Attributes
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
                float3 normal : NORMAL;
            };

            struct Varyings
            {
                float4 vertex : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 normal : NORMAL;
                half facing : V_FACE;
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
                p.vertex = v.vertex;
                p.uv = v.uv;
                p.normal = v.normal;
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

                const float edge0 = CalcDistanceTessFactor(patch[0].vertex, minDist, maxDist, _Tess);
                const float edge1 = CalcDistanceTessFactor(patch[1].vertex, minDist, maxDist, _Tess);
                const float edge2 = CalcDistanceTessFactor(patch[2].vertex, minDist, maxDist, _Tess);

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
                Varyings output;
                float3 Displacement = tex2Dlod(_MainTex, float4(input.uv,0,0)).rgb;
                Displacement.y *= _HeightScaleFactor;
                Displacement.xz *= _HorizontalScaleDampening;
                output.vertex = TransformObjectToHClip(input.vertex.xyz + Displacement);//could add a multiplicative factor here
                output.normal = input.normal;
                output.uv = input.uv;
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

                DomainCalc(vertex)
                DomainCalc(uv)
                DomainCalc(normal)

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
                // sample the texture
                half4 col = _Color;
                col.a = _Opacity;
                
                return col;
            }
            ENDHLSL
        }
    }
}
