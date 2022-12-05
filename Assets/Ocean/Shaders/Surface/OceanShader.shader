Shader "Custom/OceanShader"
{
    Properties
    {
        _DisplacementTex ("Displacement Texture", 2D) = "black" {}
        _NormalTexture("NormalRenderTexture",2D) = "black" {}
        _Color ("MainColor", Color) =  (.5,.5,.5,1)
        _MaxTessDistance("Max Tess distance", Range(1,64)) = 20
        _Tess("Tesselation",Range(1,64)) = 20
        _HeightScaleFactor("Height scale", Range(0,32)) = 5
        _HorizontalScaleDampening("Horizontal Factor", Range(0,1)) = 0.5
        _Opacity("Opactiy", Range(0,1)) = 0.7
        _Smoothness("Smoothness", Range(0,1)) = 0.7
        [ToggleUI]NormalVis("visualize Normals?",Float) = 0
        [ToggleUI]TangentVis("visualize tangents?",Float) = 0
        [ToggleUI]normalFiltering("normal filtering",Float) = 0
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
            ZWrite On
            ZTest LEqual
            HLSLPROGRAM
            #pragma target 5.0
            #pragma vertex TesselationVertexProgram
            #pragma fragment frag
            #pragma hull hull
            #pragma domain domain
            //VFACE semantic can be used to flip normal when seeing the water surface through itself.
            //"crest" detection ? SoT has a smooth transition to it's lighter and textured crests, probably need to pass the information in the fragment input
            //Tesselation benchmark (there's probably a lot of room to optimize while keeping the look of SoT, quite difficult to retro engineer)
            
            #include "OceanLitInput.hlsl"
            #include "OceanLitForwardPass.hlsl"
            

            ENDHLSL
        }
    }
}
