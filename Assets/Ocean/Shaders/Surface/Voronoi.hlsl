
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