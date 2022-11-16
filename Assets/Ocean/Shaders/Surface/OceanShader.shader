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
            
            //trying to reproduce the Unity way of splitting files, not a fan
            Blend SrcAlpha OneMinusSrcAlpha //"traditional" transparency
            BlendOp Add
            HLSLPROGRAM
            #pragma target 5.0
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
            
            #include "OceanLitInput.hlsl"
            #include "OceanLitForwardPass.hlsl"
            //pre tesselation output. Suspicious that the only difference is semantics
            

            ENDHLSL
        }
    }
}
