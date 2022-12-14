using System;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Serialization;
using UnityEngine.UI;

namespace Ocean
{
    public enum Samples
    {
        _64 = 64,
        _128 = 128,
        _256 = 256,
        _512 = 512,
        _1024 = 1024
    }
    public class OceanController : MonoBehaviour
    {
        [Header("Shaders")]
        [SerializeField] private ComputeShader oceanInitShader;
        [SerializeField] private ComputeShader oceanUpdateShader;

        
        [Header("Parameters")] 
        [SerializeField] private Samples sampleSize = Samples._256;
        private int _numberOfSamples = 256;//for 256 dispatch with 16x16x1 with thread num 16x16x1
        [SerializeField] private int patchSize = 1000;
        [SerializeField] private float windSpeed = 40f;
        [SerializeField] private Vector2 windDirection = Vector2.right;
        [SerializeField] private float amplitudeFactor = 4.0f;
        [FormerlySerializedAs("NoiseTexture")]
        [Header("Resources")] 
        [SerializeField] Texture2D noiseTexture;

        [Header("Scene")] [SerializeReference] private MeshRenderer surfaceRenderer;
        //GPU resources
        //using a single texture as they are always read from and written to at the same time (h0k is on rg h0minusk is ba)
        private RenderTexture _h0ValuesTexture;
        private RenderTexture _butterflyTexture;
        private RenderTexture _displacementTexture;//dx in red dy in green, dz in blue
        private RenderTexture _normalTexture;
        private ComputeBuffer _fourierComponentBuffer;//Using a buffer because I can't fit a float6 in a texture
        private ComputeBuffer _bitReverseIndexes;
        
        //constant buffers
        private ComputeBuffer _constantParamBuffer;
        private int _frequentUpdateBufferId;
        private int _permutationKernelIndex;

        private static readonly int DisplacementTextureMaterialID = Shader.PropertyToID("_DisplacementTex");
        private static readonly int NormalMapTextureMaterialID = Shader.PropertyToID("_NormalTexture");
        private static readonly int HeightScalingMaterialID = Shader.PropertyToID("_HeightScaleFactor");
        private static readonly int HorizontalScalingMaterialID = Shader.PropertyToID("_HorizontalScaleDampening");
        
        private float _t;//initialized to 0
        private int _timeSpectrumKernel = 1;
        private int _singlePassFFTKernel = 2;
        private int _normalComputeKernelIndex = 4;
        
        #region Initialization

        private void Awake()
        {
            _numberOfSamples = (int)sampleSize;
            var keywordSpace = oceanUpdateShader.keywordSpace;
            foreach (var keyword in keywordSpace.keywords)
            {
                oceanUpdateShader.DisableKeyword(keyword);
            }
            var keywordToEnable = keywordSpace.FindKeyword(string.Concat("SAMPLE_", _numberOfSamples.ToString()));

            Debug.Log(string.Concat("SAMPLE_", _numberOfSamples.ToString()));
            oceanUpdateShader.EnableKeyword(keywordToEnable);

        }

        private void Start()
        {
            if (_numberOfSamples <= 0) _numberOfSamples = 1;
            _numberOfSamples = (int)RoundingToHigherPowerOfTwo(Convert.ToUInt32(_numberOfSamples));//
            //check number of sample and pad to power of 2 if necessary
            _constantParamBuffer = new ComputeBuffer(6, sizeof(int), ComputeBufferType.Constant);
            oceanInitShader.SetConstantBuffer("RarelyUpdated",_constantParamBuffer,0,sizeof(int)*6);
            oceanUpdateShader.SetConstantBuffer("RarelyUpdated",_constantParamBuffer,0,sizeof(int)*6);
            var meshpatchSize = GetComponent<MeshRenderer>().bounds.size.x;
            var patchStep =  meshpatchSize/ _numberOfSamples;
            Debug.Log($"Lattice step is {patchStep}, total patch length {meshpatchSize}, step-L ratio {patchStep/((windSpeed*windSpeed)/9.81f)}");
            byte[] bufferData = new byte[24];
            BitConverter.GetBytes(_numberOfSamples).CopyTo(bufferData,0);
            BitConverter.GetBytes((int)Mathf.Log(_numberOfSamples, 2)).CopyTo(bufferData,4);
            BitConverter.GetBytes(patchSize).CopyTo(bufferData,8);
            BitConverter.GetBytes(patchStep).CopyTo(bufferData,12);
            //scaling factors
            BitConverter.GetBytes(surfaceRenderer.material.GetFloat(HorizontalScalingMaterialID)).CopyTo(bufferData,16);
            BitConverter.GetBytes(surfaceRenderer.material.GetFloat(HeightScalingMaterialID)).CopyTo(bufferData,20);
            
            
            _constantParamBuffer.SetData(bufferData);
            InitialSpectrumGeneration();
            
            ButterFlyTextureGeneration();
            BindTimeDependentBuffers();
            surfaceRenderer.material.SetTexture(DisplacementTextureMaterialID,_displacementTexture,RenderTextureSubElement.Default);
            surfaceRenderer.material.SetTexture(NormalMapTextureMaterialID,_normalTexture,RenderTextureSubElement.Default);
            #if UNITY_EDITOR || DEVELOPMENT_BUILD
            DebugBidings();
            #endif
        }
        private void BindTimeDependentBuffers()
        {
            //some of these values could be packed in constant buffers (although they sadly updated out of sync)
            oceanUpdateShader.SetFloat("t",0f);
            oceanUpdateShader.SetInt("direction",0);
            
            
            var buffersSize = _numberOfSamples * _numberOfSamples * 2;
            
            _timeSpectrumKernel = oceanUpdateShader.FindKernel("TimeSpectrum");
            
            oceanUpdateShader.SetTexture(_timeSpectrumKernel,"h0", _h0ValuesTexture);

            _fourierComponentBuffer = new ComputeBuffer(buffersSize, sizeof(float) * 6);
            oceanUpdateShader.SetBuffer(_timeSpectrumKernel,"tilde_hkt",_fourierComponentBuffer);


            _singlePassFFTKernel = oceanUpdateShader.FindKernel("FFTCompute");
            oceanUpdateShader.SetTexture(_singlePassFFTKernel,"_butterflyTexture",_butterflyTexture);
            oceanUpdateShader.SetBuffer(_singlePassFFTKernel,"InOutFFTBuffer",_fourierComponentBuffer);
            
            _permutationKernelIndex = oceanUpdateShader.FindKernel("InversionAndPermutation");
            //Not convinced yet that the input buffer can't be predicted at build time, binding both ping pong buffer for now
            oceanUpdateShader.SetBuffer(_permutationKernelIndex,"InOutFFTBuffer",_fourierComponentBuffer);
            //textures
            _displacementTexture =
                new RenderTexture(_numberOfSamples, _numberOfSamples, 0,RenderTextureFormat.ARGBFloat) {enableRandomWrite = true, filterMode = FilterMode.Point};//Default format, wasting the alpha channel but R32G32B32 isn't supported everywhere
            oceanUpdateShader.SetTexture(_permutationKernelIndex,"displacement",_displacementTexture);
            _normalComputeKernelIndex = oceanUpdateShader.FindKernel("ComputeNormal");
            _normalTexture = new RenderTexture(_numberOfSamples, _numberOfSamples, 0, RenderTextureFormat.ARGBFloat)//probably don't need full float32
                { enableRandomWrite = true, filterMode = FilterMode.Point };
            oceanUpdateShader.SetTexture(_normalComputeKernelIndex,"normalMap",_normalTexture);
            oceanUpdateShader.SetTexture(_normalComputeKernelIndex,"displacement",_displacementTexture);
           
        }
        private void ButterFlyTextureGeneration()
        {
            try
            {
                var kernel = oceanInitShader.FindKernel("ButterflyTextureGen");
                _bitReverseIndexes = new ComputeBuffer(_numberOfSamples, sizeof(uint));
                var reversedIndexArray = GetReverseBitOrderedArray((uint)_numberOfSamples);
                _bitReverseIndexes.SetData(reversedIndexArray);
                oceanInitShader.SetBuffer(kernel, "bitReversedBuffer", _bitReverseIndexes);
                
                //texture setup
                var nlog2 = 0; 
                var n = _numberOfSamples;


                while ((n >>= 1) != 0) nlog2++;
                _butterflyTexture = new RenderTexture(nlog2, _numberOfSamples, 0,RenderTextureFormat.ARGBFloat)
                {
                    enableRandomWrite = true,filterMode = FilterMode.Point
                };
                _butterflyTexture.Create();
                oceanInitShader.SetTexture(kernel,"ButterflyTexture",_butterflyTexture,0);
                oceanInitShader.Dispatch(kernel,nlog2 ,_numberOfSamples / 16,1);
                
            }
            catch(InvalidOperationException ex)
            {
                if(_numberOfSamples == 0)Debug.LogError("Number of sample cannot be 0. Please set it to a power of 2");
                Debug.LogException(ex);
            }
            
        }
        private void InitialSpectrumGeneration()
        {

            int kernel = oceanInitShader.FindKernel("SpectrumGen");

            //assuming this L is the patch size, but it is a bit unclear in the paper, it could just be a precomputed value
            oceanInitShader.SetTexture(kernel,"noise", noiseTexture);
            oceanInitShader.SetFloat("A",amplitudeFactor);//this is a numerical constant that likely doesn't represent anything concrete, at a glance the amplitude of waves is linearly dependant on the square root of A
            oceanInitShader.SetFloat("windSpeed",windSpeed);
            //oceanInitShader.SetFloats("WindDirection",windDirection.x,windDirection.y);
            oceanInitShader.SetVector("WindDirection", windDirection);

            
            _h0ValuesTexture = new RenderTexture(_numberOfSamples, _numberOfSamples, 0,RenderTextureFormat.ARGBFloat/*GraphicsFormat.R32G32B32A32_SFloat*/) {enableRandomWrite = true, filterMode = FilterMode.Point};//defaults to float4
            oceanInitShader.SetTexture(kernel,"h0",_h0ValuesTexture);
            oceanInitShader.Dispatch(kernel,_numberOfSamples/16,_numberOfSamples/16,1);
            
            noiseTexture = null;//the garbage collection should free the gpu memory
        }
        private uint RoundingToHigherPowerOfTwo(uint number)//returns number if number is already a power of two
        {
            //portable though not the most efficient way of rounding to next power of two
            number--;
            number |= number >> 1;
            number |= number >> 2;
            number |= number >> 4;
            number |= number >> 8;
            number |= number >> 16;
            number++;
            return number;
        }
        private uint[] GetReverseBitOrderedArray(uint length)//length of the returned array is padded to the next power of two
        {
            //This is far from the most efficient algorithm(and it allocates a LOT), but it works on any power of two, on any hardware, for any byte length
            //If we need to compute this every frame, I'd make NumberOfSample constant (likely 256, as the max int16 is already very large)
            length = RoundingToHigherPowerOfTwo(length);
            
            if (length <= 1)
            {
                return new uint[] { 0 };
            }
            else
            {
                var result = new uint[length];
                var previousSequence = GetReverseBitOrderedArray(length / 2);//recursively getting the bit reversed sequence from the previous power of two
                for (var i = 0; i < previousSequence.Length; i++)
                {
                    previousSequence[i] *= 2;
                    result[i] = previousSequence[i];
                }

                var offset = length / 2;
                for (var i = 0; i < previousSequence.Length; i++)
                {
                    result[i + offset] = result[i] + 1;
                }

                return result;
            }

            
        }
        #endregion

        #region Runtime
        private void Update()
        {
            FourierComponents();
            
            oceanUpdateShader.SetInt("direction",0);
            oceanUpdateShader.Dispatch(_singlePassFFTKernel,1,_numberOfSamples,1);
            oceanUpdateShader.SetInt("direction",1);
            oceanUpdateShader.Dispatch(_singlePassFFTKernel,1,_numberOfSamples,1);
            

            #if UNITY_EDITOR || DEVELOPMENT_BUILD
            if(amplitudeDebug)oceanUpdateShader.Dispatch(_amplitudeDebugKernel,_numberOfSamples,_numberOfSamples*2,1);
            #endif
            

          
            //inversion and permutation pass
            oceanUpdateShader.Dispatch(_permutationKernelIndex, _numberOfSamples / 16, _numberOfSamples / 16, 1);
            oceanUpdateShader.Dispatch(_normalComputeKernelIndex, _numberOfSamples/16,_numberOfSamples/16,1);
        }
        
        

        private void FourierComponents()
        {
            
            _t += Time.deltaTime;//might need to be looped back to 0
            oceanUpdateShader.SetFloat("t",_t);
            oceanUpdateShader.Dispatch(_timeSpectrumKernel,_numberOfSamples/16,_numberOfSamples/16,1);
            
        }
        #endregion

        #region CleanUp
        private void OnDestroy()
        {
            //TODO: Release buffers only used for initialisation at the end of start
            _h0ValuesTexture.Release();
            _fourierComponentBuffer.Release();
            _bitReverseIndexes.Release();//this could be released earlier
            _constantParamBuffer.Release();
            #if UNITY_EDITOR || DEVELOPMENT_BUILD
            if(_textureDebugAmplitudeTexture != null)_textureDebugAmplitudeTexture.Release();
            #endif
            
        }
        #endregion

        #region textureDebug

        [SerializeField] private bool amplitudeDebug;
        [SerializeField] private bool spectrumDebug;
        [FormerlySerializedAs("TextureDebugAmplitudeDisplay")] [SerializeField] private RawImage textureDebugAmplitudeDisplay;
        [SerializeField] private RawImage textureDebugSpectrumDisplay;
        private RenderTexture _textureDebugAmplitudeTexture;
        private int _amplitudeDebugKernel;
        private void DebugBidings()
        {
            //spectrum
            if (spectrumDebug && textureDebugSpectrumDisplay != null)
            {
                textureDebugSpectrumDisplay.texture = _h0ValuesTexture;
            }
            //amplitude
            if (textureDebugAmplitudeDisplay == null || amplitudeDebug == false)
            {
                Debug.Log("no display for the debug texture");
                return;
            }
            _textureDebugAmplitudeTexture = new RenderTexture(_numberOfSamples, _numberOfSamples * 2, 0,
                GraphicsFormat.R32G32B32A32_SFloat) {enableRandomWrite = true, filterMode = FilterMode.Point};
            _textureDebugAmplitudeTexture.Create();
            textureDebugAmplitudeDisplay.texture = _textureDebugAmplitudeTexture;
            _amplitudeDebugKernel = oceanUpdateShader.FindKernel("DebugAmplitude");
            oceanUpdateShader.SetBuffer(_amplitudeDebugKernel,"tilde_hkt",_fourierComponentBuffer);
            oceanUpdateShader.SetTexture(_amplitudeDebugKernel,"DebugAmplitudeTexture",_textureDebugAmplitudeTexture);
            
        }

        #endregion
    }
    
}
