#version 450
// E641 active character-atlas branch. This is a capture replay, not a live renderer replacement.
layout(local_size_x = 8, local_size_y = 8) in;
layout(set=0,binding=0) uniform sampler2D atlas;
layout(set=0,binding=1,std430) readonly buffer Camera { float camera[]; };
layout(set=0,binding=2,std430) readonly buffer Shadow { float shadow[]; };
layout(set=0,binding=3,std430) readonly buffer Depth { float depth[]; };
layout(set=0,binding=4,std430) readonly buffer Normal { uint normal[]; };
layout(set=0,binding=5,std430) readonly buffer Mask { uint mask[]; };
layout(set=0,binding=6,std430) readonly buffer Stencil { uint stencil[]; };
layout(set=0,binding=7,rg8) writeonly uniform image2D result;
const vec2 poisson[16]=vec2[16](vec2(-0.9420162439346313,-0.3990621566772461),vec2(0.945586085319519,-0.7689072489738464),vec2(-0.09418410062789917,-0.929388701915741),vec2(0.3449593782424927,0.29387760162353516),vec2(-0.9158858060836792,0.457714319229126),vec2(-0.8154423236846924,-0.879124641418457),vec2(-0.3827754259109497,0.27676844596862793),vec2(0.9748439788818359,0.756483793258667),vec2(0.4432332515716553,-0.9751155376434326),vec2(0.5374298095703125,-0.47373420000076294),vec2(-0.2649691104888916,-0.4189302325248718),vec2(0.7919751405715942,0.19090187549591064),vec2(-0.2418884038925171,0.9970650672912598),vec2(-0.8140995502471924,0.914375901222229),vec2(0.19984126091003418,0.7864136695861816),vec2(0.14383161067962646,-0.1410079002380371));
const vec2 rotation[16]=vec2[16](vec2(-0.39965590834617615,0.9166651964187622),vec2(0.12451229989528656,-0.9922180771827698),vec2(0.8523542881011963,0.5229647159576416),vec2(-0.2293124943971634,0.9733529090881348),vec2(-0.7724061012268066,0.6351289749145508),vec2(0.7927525043487549,-0.6095436811447144),vec2(-0.5780497193336487,0.8160015940666199),vec2(-0.8311296105384827,-0.5560787916183472),vec2(0.8077948093414307,0.5894637703895569),vec2(0.4714154005050659,0.8819112777709961),vec2(-0.3139738142490387,-0.9494317173957825),vec2(-0.9450067281723022,-0.3270510137081146),vec2(-0.18503740429878235,-0.9827315211296082),vec2(-0.9337558746337891,0.35791051387786865),vec2(-0.9976140856742859,0.06903629750013351),vec2(0.30612778663635254,0.9519904255867004));
vec4 cam4(int o) { return vec4(camera[o],camera[o+1],camera[o+2],camera[o+3]); }
vec4 sh4(int o) { return vec4(shadow[o],shadow[o+1],shadow[o+2],shadow[o+3]); }
float visibility(ivec2 pixel, int p) {
 float index = log2(float(mask[p])) - 8.0;
 if (!(index >= 0.0 && index < shadow[8864/4+2])) return 1.0;
 int i = int(index);
 vec2 oct = vec2(normal[p]&1023u,(normal[p]>>10)&1023u)/1023.0*2.0-1.0;
 vec3 n=vec3(oct.x,1.0-abs(oct.x)-abs(oct.y),oct.y);
 if(n.y<0.0) n.xz=(1.0-abs(n.zx))*mix(vec2(-1),vec2(1),greaterThanEqual(n.xz,vec2(0)));
 n=normalize(n);
 // Original reconstructs at integer pixel coordinates, while depth is sampled at the pixel center.
 vec2 uv=vec2(pixel)*cam4(1328/4).zw;
 vec4 clip=vec4(uv.x*2.0-1.0,-(uv.y*2.0-1.0),depth[p],1);
 precise vec4 world=mat4(cam4(96),cam4(100),cam4(104),cam4(108))*clip;
 vec3 light=sh4(8368/4+i*4).xyz;
 float slope=1.0-clamp(dot(n,light),0.0,0.9);
 precise vec3 biased=world.xyz/world.w-light*(slope*shadow[8128/4+i*4])+n*(slope*shadow[8128/4+i*4+1]);
 int m=7168/4+i*16;
 precise vec3 projected=(mat4(sh4(m),sh4(m+4),sh4(m+8),sh4(m+12))*vec4(biased,1)).xyz;
 projected.z=max(projected.z,0.01);
 if(any(lessThanEqual(projected,vec3(0)))||any(greaterThanEqual(projected,vec3(1)))||isnan(projected.z)) return 1.0;
 vec4 tile=sh4(8608/4+i*4);
 precise vec2 center=tile.xy+projected.xy*tile.zw;
 vec2 r=rotation[(pixel.x%4)*4+pixel.y%4];
 mat2 turn=mat2(r,vec2(-r.y,r.x));
 float count=0.0, sum_depth=0.0;
 for(int tap=0;tap<16;tap++) {
  precise vec2 offset=(turn*poisson[tap])*(4.0*shadow[8848/4]);
  vec4 delta=textureGather(atlas,center+offset,0)-vec4(projected.z);
  vec4 blocked=step(vec4(0),delta);
  count+=dot(blocked,vec4(1));
  sum_depth+=dot(delta,blocked);
 }
 // The capture produces NaN intermediates for zero blockers, but its final NMin yields 1.
 if(count==0.0) return 1.0;
 float relative_depth=clamp((sum_depth*(1.0/count))*(1.0/projected.z),0.0,1.0);
 float coverage=clamp(count*(1.0/64.0),0.0,1.0);
 float t=2.0*coverage-1.0, s=sign(t), a=1.0-s*t;
 return min(1.0,0.5-0.5*(1.0-mix(a*a*a,a,relative_depth))*s);
}
void main() {
 ivec2 pixel=ivec2(gl_GlobalInvocationID.xy);
 if(any(greaterThanEqual(pixel,ivec2(2560,1440)))) return;
 int p=pixel.y*2560+pixel.x;
 // E641: stencil Equal, reference 4, compare mask 7. E637 fills the complement.
 float g=(stencil[p*2+1]&7u)==4u ? visibility(pixel,p) : 1.0;
 imageStore(result,pixel,vec4(1,g,0,1));
}
