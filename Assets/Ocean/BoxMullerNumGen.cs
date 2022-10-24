using System;
using Random = UnityEngine.Random;

public static class BoxMullerNumGen
{
    public static Tuple<double, double> generateGaussianNoise(double mu = 0f, double sigma = 1f)
    {
        const double epsilon = double.Epsilon;
        const double two_pi = 2.0 * Math.PI;
        
        Random.InitState(654968);//might need to replace the the unity rng by a noise texture

        double u1;
        do
        {
            u1 = Random.value;
        } while (u1 <= epsilon);

        double u2 = Random.value;

        var mag = sigma * Math.Sqrt(-2.0 * Math.Log(u1));
        var z0 = mag * Math.Cos(two_pi * u2) + mu;
        var z1 = mag * Math.Sin(two_pi * u2) + mu;

        return new Tuple<double, double>(z0, z1);
    }
}
