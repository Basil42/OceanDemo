using System;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.UI;

namespace Ocean
{
    public class OceanController : MonoBehaviour
    {
        [Header("Shaders")]
        [SerializeField] private ComputeShader oceanInitShader;
        [SerializeField] private ComputeShader oceanUpdateShader;
        
        [Header("Parameters")]
        [SerializeField] private int numberOfSamples = 256;//for 256 dispatch with 16x16x1 with thread num 16x16x1
        [SerializeField] private int patchSize = 1000;
        [SerializeField] private float windSpeed = 40f;
        [SerializeField] private Vector2 windDirection = Vector2.one.normalized;
        [Header("Resources")]
        [SerializeField]
        private Texture2D noiseTexture;//4 channels of different white noise
        #if UNITY_EDITOR
        [Header("Debug")] [SerializeField] private RawImage displacementPrevis;
        [SerializeField] private RawImage butterFlyPrevis;
        [SerializeField] private RawImage spectrumPrevis;
        [SerializeField] bool dumpTexture =true;
        #endif
        //GPU resources
        //using a single texture as they are always read from and written to at the same time (h0k is on rg h0minusk is ba)
        private RenderTexture _h0ValuesTexture;
        private RenderTexture _butterflyTexture;
        private RenderTexture _displacementTexture;//dx in red dy in green, dz in blue
        private ComputeBuffer _fourierComponentBuffer;//Using a buffer because I can't fit a float6 in a texture
        private ComputeBuffer _pingPongBuffer;
        private ComputeBuffer _bitReverseIndexes;
        
        //constant buffers
        private ComputeBuffer _frequentlyUpdatedBuffer;
        private ComputeBuffer _constantParamBuffer;
        
        private void Start()
        {
            if (numberOfSamples <= 0) numberOfSamples = 1;
            numberOfSamples = (int)RoundingToHigherPowerOfTwo(Convert.ToUInt32(numberOfSamples));//
            //check number of sample and pad to power of 2 if necessary
            _constantParamBuffer = new ComputeBuffer(2, sizeof(int), ComputeBufferType.Constant);
            oceanInitShader.SetConstantBuffer("RarelyUpdated",_constantParamBuffer,0,sizeof(int)*4);
            oceanUpdateShader.SetConstantBuffer("RarelyUpdated",_constantParamBuffer,0,sizeof(int)*4);
            _constantParamBuffer.SetData(new [] {numberOfSamples,patchSize });
            InitialSpectrumGeneration();
            
            ButterFlyTextureGeneration();
            BindTimeDependentBuffers();
            
            #if UNITY_EDITOR
            //debug
            displacementPrevis.texture = _displacementTexture;
            butterFlyPrevis.texture = _butterflyTexture;
            spectrumPrevis.texture = _h0ValuesTexture;
#endif
        }

        private void BindTimeDependentBuffers()
        {
            //some of these values could be packed in constant buffers (although they sadly updated out of sync)
            oceanUpdateShader.SetFloat("t",0f);
            oceanUpdateShader.SetInt("direction",0);
            
            
            var buffersSize = numberOfSamples * numberOfSamples;
            
            _timeSpectrumKernel = oceanUpdateShader.FindKernel("TimeSpectrum");
            oceanUpdateShader.SetTexture(_timeSpectrumKernel,"h0", _h0ValuesTexture);

            _fourierComponentBuffer = new ComputeBuffer(buffersSize, sizeof(float) * 6);
            oceanUpdateShader.SetBuffer(_timeSpectrumKernel,"tilde_hkt",_fourierComponentBuffer);

            _pingPongBuffer = new ComputeBuffer(buffersSize, sizeof(float) * 6);
            
            _verticalButterflyPassKernelIndex = oceanUpdateShader.FindKernel("ButterflyVerticalCompute");
            oceanUpdateShader.SetTexture(_verticalButterflyPassKernelIndex,"_butterflyTexture", _butterflyTexture);
            oceanUpdateShader.SetBuffer(_verticalButterflyPassKernelIndex,"pingPong0",_fourierComponentBuffer);
            oceanUpdateShader.SetBuffer(_verticalButterflyPassKernelIndex,"pingPong1",_pingPongBuffer);
            
            _horizontalButterflyPassKernelIndex = oceanUpdateShader.FindKernel("ButterflyHorizontalCompute");
            oceanUpdateShader.SetTexture(_horizontalButterflyPassKernelIndex,"_butterflyTexture", _butterflyTexture);
            oceanUpdateShader.SetBuffer(_horizontalButterflyPassKernelIndex,"pingPong0",_fourierComponentBuffer);
            oceanUpdateShader.SetBuffer(_horizontalButterflyPassKernelIndex,"pingPong1",_pingPongBuffer);
            
            _permutationKernelIndex = oceanUpdateShader.FindKernel("InversionAndPermutation");
            //Not convinced yet that the input buffer can't be predicted at build time, binding both ping pong buffer for now
            oceanUpdateShader.SetBuffer(_permutationKernelIndex,"pingPong0",_fourierComponentBuffer);
            oceanUpdateShader.SetBuffer(_permutationKernelIndex,"pingPong1",_pingPongBuffer);
            _displacementTexture =
                new RenderTexture(numberOfSamples, numberOfSamples, 0) {enableRandomWrite = true};//Default format, wasting the alpha channel but R32G32B32 isn't supported everywhere
            oceanUpdateShader.SetTexture(_permutationKernelIndex,"displacement",_displacementTexture);

            _frequentlyUpdatedBuffer = new ComputeBuffer(2, sizeof(int),ComputeBufferType.Constant);
            _frequentUpdateBufferId = Shader.PropertyToID("FrequentUpdatesVariables");
            _frequentUpdateData = new [] { 0, 0};
            oceanUpdateShader.SetConstantBuffer(_frequentUpdateBufferId,_frequentlyUpdatedBuffer,0,sizeof(int)*4);//8 bytes ints of padding
        }

        private void ButterFlyTextureGeneration()
        {
            try
            {
                var kernel = oceanInitShader.FindKernel("ButterflyTextureGen");
                _bitReverseIndexes = new ComputeBuffer(numberOfSamples, sizeof(uint));
                oceanInitShader.SetBuffer(kernel, "bitReversedBuffer", _bitReverseIndexes);

                //texture setup
                var nlog2 = 0; //horizontal dimension of the texture
                var n = numberOfSamples;


                while ((n >>= 1) != 0) nlog2++;
                _butterflyTexture = new RenderTexture(nlog2, numberOfSamples, 0)
                {
                    enableRandomWrite = true
                };
                _butterflyTexture.Create();
                oceanInitShader.SetTexture(kernel,"ButterflyTexture",_butterflyTexture,0);
                oceanInitShader.Dispatch(kernel,nlog2 ,numberOfSamples / 16,1);
                
            }
            catch(InvalidOperationException ex)
            {
                if(numberOfSamples == 0)Debug.LogError("Number of sample cannot be 0. Please set it to a power of 2");
                Debug.LogException(ex);
            }
            
        }

        private int _frequentUpdateBufferId;
        private int[] _frequentUpdateData;
        private int _horizontalButterflyPassKernelIndex;
        private int _verticalButterflyPassKernelIndex;
        private int _permutationKernelIndex;

        
        private void Update()
        {
            FourierComponents();
            var pingPong = 0;//keeping these values outside the array is redundant, but is kept for clarity (ideally I'd prefer passing a struct to the buffer but unity doesn't allow it

            for (int i = 0; i < MathF.Log(numberOfSamples, 2); i++)
            {
                //horizontal butterfly pass
                _frequentUpdateData[0] = i;
                _frequentUpdateData[1] = pingPong;
                _frequentlyUpdatedBuffer.SetData(_frequentUpdateData,0,0,2);
                oceanUpdateShader.Dispatch(_horizontalButterflyPassKernelIndex,numberOfSamples/16,numberOfSamples/16,1);
                pingPong = pingPong == 1 ? 0 : 1;
                
            }

            
            for (int i = 0; i < Mathf.Log(numberOfSamples, 2); i++)
            {
                //Vertical butterfly pass
                _frequentUpdateData[0] = i;
                _frequentUpdateData[1] = pingPong;
                _frequentlyUpdatedBuffer.SetData(_frequentUpdateData,0,0,2);
                oceanUpdateShader.Dispatch(_verticalButterflyPassKernelIndex,numberOfSamples/16,numberOfSamples/16,1);
                
                pingPong = pingPong == 1 ? 0 : 1;
            }
            //inversion and permutation pass
            oceanUpdateShader.Dispatch(_permutationKernelIndex, numberOfSamples / 16, numberOfSamples / 16, 1);
            #if UNITY_EDITOR
            if (dumpTexture)
            {
                dumpTexture = false;
                Texture2D SavedTex = new Texture2D(numberOfSamples, numberOfSamples);
                RenderTexture.active = _displacementTexture;
                SavedTex.ReadPixels(new Rect(Vector2.zero, new Vector2(numberOfSamples,numberOfSamples)),0,0);
                Texture2D butterFlyReadout = new Texture2D(_butterflyTexture.width, numberOfSamples);
                RenderTexture.active = _butterflyTexture;
                butterFlyReadout.ReadPixels(new Rect(0,0,_butterflyTexture.width,numberOfSamples),0,0);
                Texture2D spectrumReadout = new Texture2D(numberOfSamples, numberOfSamples);
                RenderTexture.active = _h0ValuesTexture;
                spectrumReadout.ReadPixels(new Rect(0,0,numberOfSamples,numberOfSamples),0,0);
                var spectrumPixel = spectrumReadout.GetPixels();
                var pixels = SavedTex.GetPixels();
                var ping = new Vector2[numberOfSamples*numberOfSamples*3];
                var pong = new Vector2[numberOfSamples*numberOfSamples*3];
                _fourierComponentBuffer.GetData(ping);
                _pingPongBuffer.GetData(pong);
                var butterflypixels = butterFlyReadout.GetPixels();
                Debug.Log("dumping some buffers for debug");
            }
            #endif
        }

        private float _t;//initialized to 0
        private int _timeSpectrumKernel = 1;
        private void FourierComponents()
        {
            
            _t += Time.deltaTime;//might need to be looped back to 0
            oceanUpdateShader.SetFloat("t",_t);
            oceanUpdateShader.Dispatch(_timeSpectrumKernel,numberOfSamples/16,numberOfSamples/16,1);
        }

        
        private void InitialSpectrumGeneration()
        {

            int kernel = oceanInitShader.FindKernel("SpectrumGen");
            
            oceanInitShader.SetTexture(kernel, "noise", noiseTexture);
            
            //assuming this L is the patch size, but it is a bit unclear in the paper, it could just be a precomputed value
            
            oceanInitShader.SetFloat("A",4f);//this is a numerical constant that likely doesn't represent anything concrete, at a glance the amplitude of waves is linearly dependant on the square root of A
            oceanInitShader.SetFloat("windSpeed",windSpeed);
            oceanInitShader.SetFloats("WindDirection",windDirection.x,windDirection.y);

            
            _h0ValuesTexture = new RenderTexture(numberOfSamples, numberOfSamples, 0,GraphicsFormat.R32G32B32A32_SFloat) {enableRandomWrite = true};//defaults to float4
            oceanInitShader.SetTexture(kernel,"h0",_h0ValuesTexture);
            oceanInitShader.Dispatch(kernel,numberOfSamples/16,numberOfSamples/16,1);
            
            //should make the GC remove the texture from the gpu
            noiseTexture = null;



        }
        #if UNITY_EDITOR
        [ContextMenu("Reverse bit ordering test")]
        private void ReverseTest()
        {
            var testArray = GetReverseBitOrderedArray((uint)numberOfSamples);
            string arrayPrint = "";
            foreach (var index in testArray)
            {
                arrayPrint += " " + index;
            }
            Debug.Log(arrayPrint);
        }
        #endif
        
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
        private void OnDestroy()
        {
            //TODO: Release buffers only used for initialisation at the end of start
            _h0ValuesTexture.Release();
            _fourierComponentBuffer.Release();
            _bitReverseIndexes.Release();//this could be released earlier
            _pingPongBuffer.Release();
            _frequentlyUpdatedBuffer.Release();
            _constantParamBuffer.Release();
            
        }
    }
    
}
