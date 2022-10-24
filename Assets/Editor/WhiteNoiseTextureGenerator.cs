using UnityEditor;
using UnityEngine;
using UnityEngine.Windows;
using Random = UnityEngine.Random;

namespace Editor
{
    public class WhiteNoiseTextureGenerator : MonoBehaviour
    {
        [MenuItem("Utilities/Generate White Noise Texture")]
        public static void GenerateWhiteNoise()
        {
            Texture2D noiseTexture = new Texture2D(256, 256);
            for (int j = 0; j < noiseTexture.width; j++)
            {
                for (int i = 0; i < noiseTexture.height; i++)
                {
                    float randomNumber = Random.value;
                    noiseTexture.SetPixel(i, j, new Color(randomNumber, randomNumber, randomNumber, 1));
                }
            }
            noiseTexture.Apply();
            //texture check
            if (!TextureWhiteNoiseCheck(noiseTexture))
            {
                Debug.LogError("Texture was not white noise, discarding it, please try again");
                return;
            }
            var savePath = EditorUtility.SaveFilePanel("Save generated texture", Application.dataPath, "NewWhiteNoise", "TGA");
            if (string.IsNullOrEmpty(savePath)) return;
            byte[] textureData = noiseTexture.EncodeToTGA();
            if (textureData != null)
            {
                Debug.Log("Saved to: " + savePath);
                File.WriteAllBytes(savePath,textureData);
            
            }
            else
            {
                Debug.LogWarning("could not encode texture");
            
            }
            AssetDatabase.Refresh();

        }

        [MenuItem("Utilities/Generate 4 channel white noise")]
        public static void Generate4ChannelWhiteNoise()
        {
            Texture2D noiseTexture = new Texture2D(256, 256);
            
            for (int j = 0; j < noiseTexture.width; j++)
            {
                for(int i = 0; i < noiseTexture.height;i++)
                {
                    noiseTexture.SetPixel(i,j,new Color(Random.value,Random.value,Random.value,1));
                }
            }
            noiseTexture.Apply();
            if (!TextureWhiteNoiseCheck(noiseTexture))
            {
                Debug.LogError("texture wasn't white noise, discarding it.");
                return;
            }
            var savePath = EditorUtility.SaveFilePanel("Save generated texture", Application.dataPath,
                "NewWhiteNoiseFourChannel", "TGA");
            if (string.IsNullOrEmpty(savePath)) return;
            byte[] textureData = noiseTexture.EncodeToTGA();
            if (textureData != null)
            {
                Debug.Log("Saved to: " + savePath);
                File.WriteAllBytes(savePath,textureData);
            
            }
            else
            {
                Debug.LogWarning("could not encode texture");
            
            }
            AssetDatabase.Refresh();
        }

        private static bool TextureWhiteNoiseCheck(Texture2D noiseTexture)
        {
            if (!noiseTexture.isReadable)
            {
                Debug.LogError("can't read the texture");
                return false;
            }
            var pixels = noiseTexture.GetPixels();
            var sum = 0.0f;
            foreach (var color in pixels)
            {
                sum += color.r;
            }

            var mean = sum / pixels.Length;
            Debug.Log("mean value :" + mean);
            if (mean < 0.4f || mean > 0.6f)
            {
                return false;
            }

            return true;
        }


        [MenuItem("Assets/Check if white noise")]
        private static void WhiteNoiseCheck()
        {
            if (TextureWhiteNoiseCheck(Selection.activeObject as Texture2D))
            {
                Debug.Log("Texture seems to be white noise (check is currently only a mean check)");
            }
            else
            {
                Debug.LogWarning("Texture isn't white noise");
            }
            
        }

        [MenuItem("Assets/Check if white noise", true)]
        private static bool TextureValidation()
        {
            return Selection.activeObject is Texture2D;
        }
    }
}
