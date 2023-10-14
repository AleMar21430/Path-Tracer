#version 460 core

uniform float iTime;
uniform uint  iFrame;
uniform vec2  iResolution;
uniform uint  iRenderMode;
uniform bool  iBidirectional;

uniform float iCameraFocalLength;
uniform float iCameraSensorWidth;
uniform vec3  iCameraPos;
uniform vec3  iCameraFront;
uniform vec3  iCameraUp;
uniform bool  iCameraChange;

uniform sampler2D iHdri;

in vec2 fragCoord;
in vec2 fragTexCoord;

out vec4 fragColor;

// DEFINITIONS ---------------------------------------------------------------------------------------

#define TWO_PI      6.28318530718
#define PI          3.14159265359
#define DEG_RAD     0.01745329252
#define M_E         2.71828182846

#define HDRI_STRENGTH 1.0
#define AO_LENGTH     1.0

#define MAX_DIST      5000.0
#define RAY_BOUNCES   4
#define SPP           1
#define SAMPLES       2048

#define EPSILON       0.001

// CONSTANTS ---------------------------------------------------------------------------------------

const int Quad_Face[4] = int[](1,2,0,1);

// GLOBALS ---------------------------------------------------------------------------------------

uvec4 white_noise_seed;
uvec2 pixel;
vec3  rgb_noise;

// GENERIC FUNCTIONS ---------------------------------------------------------------------------------------

float cross2d( in vec2 a, in vec2 b ) { return a.x * b.y - a.y * b.x; }
vec4 conjugate(vec4 q) { return vec4(-q.x, -q.y, -q.z, q.w); }
float mapFloat(float FromMin, float FromMax, float ToMin, float ToMax, float Value) {
	if (Value > FromMax) return ToMax;
	else if (Value < FromMin) return ToMin;
	else return (ToMin + ((ToMax - ToMin) / (FromMax - FromMin)) * (Value - FromMin));
}

uvec4 hash(uvec4 seed) {
	seed = seed * 1664525u + 1013904223u;
	seed.x += seed.y*seed.w; seed.y += seed.z*seed.x; seed.z += seed.x*seed.y; seed.w += seed.y*seed.z;
	seed = seed ^ (seed>>16u);
	seed.x += seed.y*seed.w; seed.y += seed.z*seed.x; seed.z += seed.x*seed.y; seed.w += seed.y*seed.z;
	return seed;
}
float rand1() { return float(hash(white_noise_seed).x)   / float(0xffffffffu); }
float rand1r(float min_x, float max_x) { return mapFloat(0.0, 1.0, min_x, max_x, float(hash(white_noise_seed).x)   / float(0xffffffffu)); }
vec2  rand2() { return vec2 (hash(white_noise_seed).xy)  / float(0xffffffffu); }
vec3  rand3() { return vec3 (hash(white_noise_seed).xyz) / float(0xffffffffu); }
vec4  rand4() { return vec4 (hash(white_noise_seed))     / float(0xffffffffu); }
vec2 nrand2(float sigma, vec2 mean) {
	vec2 Z = rand2();
	return mean + sigma * sqrt(-2.0 * log(Z.x)) * vec2(cos(TWO_PI * Z.y), sin(TWO_PI * Z.y));
}
vec3 nrand3(float sigma, vec3 mean) {
	vec4 Z = rand4();
	return mean + sigma * sqrt(-2.0 * log(Z.xxy)) * vec3(cos(TWO_PI * Z.z), sin(TWO_PI * Z.z), cos(TWO_PI * Z.w));
}
void rng_initialize(vec2 pix, uint frame) {
	pixel = uvec2(pix);
	white_noise_seed = uvec4(pixel, frame, uint(pixel.x) + uint(pixel.y));
}

float snell (float sin_theta, float iori, float iort) {
	return iori / iort * sin_theta;
}
float fresnel(float iori, float iort, float cosi, float cost){
	float rpar = (iort * cosi - iori * cost) / (iort * cosi + iori * cost);
	float rper = (iori * cosi - iort * cost) / (iori * cosi + iort * cost);
	rpar *= rpar;
	rper *= rper;
	return (rpar + rper) / 2.;
}

mat3 eulerToRot(vec3 euler) {
	const float Yaw =   euler.x * DEG_RAD;
	const float Pitch = euler.y * DEG_RAD;
	const float Roll =  euler.z * DEG_RAD;

	const mat3 yawMat = mat3 (
		 cos(Yaw) , 0 , sin(Yaw) ,
		 0        , 1 , 0        ,
		-sin(Yaw) , 0 , cos(Yaw)
	);

	const mat3 pitchMat = mat3 (
		1 , 0          ,  0          ,
		0 , cos(Pitch) , -sin(Pitch) ,
		0 , sin(Pitch) ,  cos(Pitch)
	);

	const mat3 rollMat = mat3 (
		cos(Roll) , -sin(Roll) , 0 ,
		sin(Roll) ,  cos(Roll) , 0 ,
		0         ,  0         , 1
	);

	return pitchMat * yawMat * rollMat;
}

// STRUCTS ---------------------------------------------------------------------------------------

#define DIFFUSE  0
#define SPECULAR 1
#define EMISSIVE 2
#define GLASS    3

struct Material {
	int   Type;
	vec3  Color;
	float Emissive_Strength;
	float Roughness;
	float IOR;
};

struct Bsdf {
	float Transmission;
	float Index_Of_Refraction;
	float Refraction_Roughness;
	float Reflection_Roughness;
	float Reflection_Anisotropy;
	float Reflection_Rotation;
	float Subsurface_Distance;
	float Subsurface_IOR;
	float Subsurface_Anisotropy;
	float Emissive_Strength;
	float Iridescent;
	float Iridescent_Roughness;
	float Clearcoat_Roughness;
	float Velvet_Angle;
	float Alpha;

	vec3 Diffuse_Color;
	vec3 Reflective_Color;
	vec3 Refractive_Color;
	vec3 Subsurface_Color;
	vec3 Emissive_Color;
	vec3 Iridescent_Color_A;
	vec3 Iridescent_Color_B;
	vec3 Clearcoat_Color;
	vec3 Velvet_Color;
};
struct Sun_Light {
	float Intensity;
	vec3  Color;
	vec3  Direction;
};
struct Ray {
	vec3  Ray_Origin;
	vec3  Ray_Direction;
};
struct Hit {
	float Ray_Length;
	vec3  Hit_New_Dir;
	vec3  Hit_Pos;
	int   Hit_Obj;
	bool  Ray_Inside;
	Material Hit_Mat;
};
struct Sphere {
	vec3 Position;
	float Diameter;
	Material Mat;
};
struct Cube {
	vec3 Position;
	vec3 Rotation;
	vec3 Scale;
	Material Mat;
};
struct Quad {
	vec3 v0;
	vec3 v1;
	vec3 v2;
	vec3 v3;
	Material Mat;
};
struct Tri {
	vec3 v0;
	vec3 v1;
	vec3 v2;
	Material Mat;
};

struct Torus {
	vec3 Position;
	vec3 Rotation;
	float Inner_Radius;
	float Torus_Radius;
	Material Mat;
};

// SCENE ---------------------------------------------------------------------------------------
#define SPHERE_COUNT 3
#define QUAD_COUNT   7
#define TORUS_COUNT  1

const Sphere Scene_Spheres[SPHERE_COUNT] = Sphere[SPHERE_COUNT](
		// POSITION                      , RADIUS  ,          Type     , Color              , Emissiveness, Roughness, IOR
	Sphere(vec3( -1    ,  0.3   ,  0    ), 0.2     , Material(DIFFUSE  , vec3(1  , 1  , 1  ), 0           , 0        , 1.2 )),
	Sphere(vec3(  0    ,  0.3   ,  0    ), 0.2     , Material(SPECULAR , vec3(1  , 1  , 1  ), 0           , 0        , 1.2 )),
	Sphere(vec3(  1    ,  0.3   ,  0    ), 0.2     , Material(GLASS    , vec3(1  , 1  , 1  ), 0           , 0        , 1.2 ))
);
const Quad Scene_Quads[QUAD_COUNT] = Quad[QUAD_COUNT](
	  // VERT_A               , VERT_B               , VERT_C               , VERT_D                 ,          Type     , Color              , Emissiveness, Roughness, IOR
	Quad(vec3( -2 , 0  , -15 ), vec3(  2 , 0  , -15 ), vec3(  2 , 0  ,  5  ), vec3( -2 , 0  ,  5  ), Material(DIFFUSE  , vec3(1  , 1  , 1  ), 0           , 0        , 1.0 )), // Floor
	Quad(vec3(  2 , 0  , -15 ), vec3(  2 , 0  ,  5  ), vec3(  2 , 3  ,  5  ), vec3(  2 , 3  , -15 ), Material(DIFFUSE  , vec3(1  , 0  , 0  ), 0           , 0        , 1.0 )), // Right Wall
	Quad(vec3( -2 , 0  , -15 ), vec3( -2 , 0  ,  5  ), vec3( -2 , 3  ,  5  ), vec3( -2 , 3  , -15 ), Material(DIFFUSE  , vec3(0  , 1  , 0  ), 0           , 0        , 1.0 )), // Left  Wall
	Quad(vec3( -2 , 0  , -15 ), vec3(  2 , 0  , -15 ), vec3(  2 , 3  , -15 ), vec3( -2 , 3  , -15 ), Material(DIFFUSE  , vec3(1  , 1  , 1  ), 0           , 0        , 1.0 )), // Back  Wall
	Quad(vec3( -2 , 3  , -15 ), vec3(  2 , 3  , -15 ), vec3(  2 , 3  ,  5  ), vec3( -2 , 3  ,  5  ), Material(DIFFUSE  , vec3(1  , 1  , 1  ), 0           , 0        , 1.0 )), // Ceiling
	Quad(vec3( -2 , 2.9, -10 ), vec3( -1 , 2.9, -10 ), vec3( -1 , 2.9,  3  ), vec3( -2 , 2.9,  3  ), Material(EMISSIVE , vec3(1  , 1  , 1  ), 1           , 0        , 1.0 )), // Light Right
	Quad(vec3(  2 , 2.9, -10 ), vec3(  1 , 2.9, -10 ), vec3(  1 , 2.9,  3  ), vec3(  2 , 2.9,  3  ), Material(EMISSIVE , vec3(1  , 1  , 1  ), 1           , 0        , 1.0 ))  // Light Left
);

const Torus Scene_Tori[TORUS_COUNT] = Torus[TORUS_COUNT](
	  // Position           , Rotation, Inner Radius, Torus Radius,          Type     , Color              , Emissiveness, Roughness, IOR
	Torus(vec3( 0, 1 , -1 ) , vec3(0) , 0.5         , 0.25        , Material(GLASS    , vec3(1  , 1  , 1  ), 0           , 0        , 1.1 ))
);

// INTERSECTIONS ---------------------------------------------------------------------------------------

bool f_SphereIntersection(in Ray ray, in Sphere sphere, inout float ray_length) {
	ray.Ray_Origin = ray.Ray_Origin - sphere.Position;

	float b = dot(ray.Ray_Origin, ray.Ray_Direction);
	float delta = b * b - dot(ray.Ray_Origin, ray.Ray_Origin) + sphere.Diameter * sphere.Diameter;
	
	if (delta < 0) {
		return false;
	}
	float sqdelta = sqrt(delta);

	if (-b - sqdelta > 0.001) {
		ray_length = -b - sqdelta;
		return true;
	}
	else if (-b + sqdelta > 0.001) {
		ray_length = -b + sqdelta;
		return true;
	}
	return false;
}

bool f_CubeIntersection(in Ray ray, in Cube cube, inout float ray_length) {
	mat3 invScaleMatrix = mat3(
		1.0 / cube.Scale.x, 0.0, 0.0,
		0.0, 1.0 / cube.Scale.y, 0.0,
		0.0, 0.0, 1.0 / cube.Scale.z
	);

	vec3 scaledRayOrigin = (ray.Ray_Origin - cube.Position) * invScaleMatrix;
	vec3 scaledRayDirection = ray.Ray_Direction * invScaleMatrix;

	vec3 tMin = (-0.5 - scaledRayOrigin) / scaledRayDirection;
	vec3 tMax = (0.5 - scaledRayOrigin) / scaledRayDirection;

	float tNear = max(max(tMin.x, tMin.y), tMin.z);
	float tFar = min(min(tMax.x, tMax.y), tMax.z);

	if (tNear > tFar || tFar < 0.0) {
		return false;
	}

	return true;
}

bool f_QuadIntersection(in Ray ray, in Quad quad, inout float ray_length) {
	vec3 normal = normalize(cross(quad.v1 - quad.v0, quad.v3 - quad.v0));
	float denom = dot(ray.Ray_Direction, normal);
	if (abs(denom) < 0.0001) {
		return false;
	}
	float t = dot(quad.v0 - ray.Ray_Origin, normal) / denom;

	if (t < 0.0) {
		return false;
	}
	vec3 intersectionPoint = ray.Ray_Origin + t * ray.Ray_Direction;

	vec3 e1 = quad.v1 - quad.v0;
	vec3 e2 = quad.v2 - quad.v1;
	vec3 e3 = quad.v3 - quad.v2;
	vec3 e4 = quad.v0 - quad.v3;

	vec3 c1 = intersectionPoint - quad.v0;
	vec3 c2 = intersectionPoint - quad.v1;
	vec3 c3 = intersectionPoint - quad.v2;
	vec3 c4 = intersectionPoint - quad.v3;
	
	if (dot(normal, cross(e1, c1)) >= 0.0 && dot(normal, cross(e2, c2)) >= 0.0 && dot(normal, cross(e3, c3)) >= 0.0 && dot(normal, cross(e4, c4)) >= 0.0) {
		ray_length = t;
		return true;
	}
	return false;
}

bool f_TorusIntersection(in Ray ray, in Torus torus, inout float ray_length) {
	ray.Ray_Origin = ray.Ray_Origin - torus.Position;
	float po = 1.0;
	
	float Ra2 = torus.Inner_Radius*torus.Inner_Radius;
	float ra2 = torus.Torus_Radius*torus.Torus_Radius;
	
	float m = dot(ray.Ray_Origin,ray.Ray_Origin);
	float n = dot(ray.Ray_Origin,ray.Ray_Direction);


	float k = (m - ra2 - Ra2)/2.0;
	float k3 = n;
	float k2 = n*n + Ra2*ray.Ray_Direction.z*ray.Ray_Direction.z + k;
	float k1 = k*n + Ra2*ray.Ray_Origin.z*ray.Ray_Direction.z;
	float k0 = k*k + Ra2*ray.Ray_Origin.z*ray.Ray_Origin.z - Ra2*ra2;

	if( abs(k3*(k3*k3 - k2) + k1) < 0.01 ) {
		po = -1.0;
		float tmp=k1; k1=k3; k3=tmp;
		k0 = 1.0/k0;
		k1 = k1*k0;
		k2 = k2*k0;
		k3 = k3*k0;
	}

	float c2 = 2.0*k2 - 3.0*k3*k3;
	float c1 = k3*(k3*k3 - k2) + k1;
	float c0 = k3*(k3*(-3.0*k3*k3 + 4.0*k2) - 8.0*k1) + 4.0*k0;

	c2 /= 3.0;
	c1 *= 2.0;
	c0 /= 3.0;

	float Q = c2*c2 + c0;
	float R = 3.0*c0*c2 - c2*c2*c2 - c1*c1;

	float h = R*R - Q*Q*Q;
	float z = 0.0;
	if( h < 0.0 ) {
		float sQ = sqrt(Q);
		z = 2.0*sQ*cos( acos(R/(sQ*Q)) / 3.0 );
	}
	else {
		float sQ = pow( sqrt(h) + abs(R), 1.0/3.0 );
		z = sign(R)*abs( sQ + Q/sQ );
	}
	z = c2 - z;

	float d1 = z   - 3.0*c2;
	float d2 = z*z - 3.0*c0;
	if( abs(d1) < 1.0e-4 ) {
		if( d2 < 0.0 ) return false;
		d2 = sqrt(d2);
	}
	else {
		if( d1 < 0.0 ) return false;
		d1 = sqrt( d1/2.0 );
		d2 = c1/d1;
	}

	float result = 1e20;
	h = d1*d1 - z + d2;
	if( h > 0.0 ) {
		h = sqrt(h);
		float t1 = -d1 - h - k3; t1 = (po<0.0)?2.0/t1:t1;
		float t2 = -d1 + h - k3; t2 = (po<0.0)?2.0/t2:t2;
		if( t1 > 0.0 ) result=t1; 
		if( t2 > 0.0 ) result=min(result,t2);
	}

	h = d1*d1 - z - d2;
	if( h > 0.0 ) {
		h = sqrt(h);
		float t1 = d1 - h - k3;  t1 = (po<0.0)?2.0/t1:t1;
		float t2 = d1 + h - k3;  t2 = (po<0.0)?2.0/t2:t2;
		if( t1 > 0.0 ) result=min(result,t1);
		if( t2 > 0.0 ) result=min(result,t2);
	}

	ray_length = result;
	return true;
}

// FUNCTIONS ---------------------------------------------------------------------------------------

float DispersionLaw(float wv_a, float wv_b, float wv, float strength) {
	return mapFloat(wv_a, wv_b, -1, 1, wv) * strength;
}

vec3 cosine_weighted_hemi_sample() {
	vec2 p = rand2();
	p = vec2(2. * PI * p.x, sqrt(p.y));
	return normalize(vec3(sin(p.x) * p.y, cos(p.x) * p.y, sqrt(1. - p.y * p.y)));
}

vec3 f_ConeRoughness(vec3 dir, float theta) {
	vec3 left = cross(dir, vec3(0., 1., 0.));
	left = length(left) > 0.1 ? normalize(left) : normalize(cross(dir, vec3(0., 0., 1.)));
	vec3 up = normalize(cross(dir, left));

	vec2 u = rand2();
	float cos_theta = (1. - u.x) + u.x * cos(theta);
	float sin_theta = sqrt(1. - cos_theta * cos_theta);
	float phi = u.y * 2.0 * PI;
	return normalize(
		left * cos(phi) * sin_theta +
		up   * sin(phi) * sin_theta +
		dir  * cos_theta);
}

Hit f_SceneIntersection(const in Ray ray) {
	Hit hit_data;
	hit_data.Ray_Length = MAX_DIST;
	hit_data.Ray_Inside = false;

	for (int i = 0; i < SPHERE_COUNT; i++) {
		float resultRayLength;
		if (f_SphereIntersection(ray, Scene_Spheres[i], resultRayLength)) {
			if(resultRayLength < hit_data.Ray_Length && resultRayLength > 0.001) {
				Sphere sphere = Scene_Spheres[i];
				hit_data.Ray_Length = resultRayLength;
				hit_data.Hit_Pos = ray.Ray_Origin + ray.Ray_Direction * resultRayLength;
				hit_data.Hit_New_Dir = normalize(hit_data.Hit_Pos - sphere.Position);
				hit_data.Hit_Mat = sphere.Mat;
				hit_data.Hit_Obj = i;
				if (distance(ray.Ray_Origin, sphere.Position) <=sphere.Diameter) {
					hit_data.Ray_Inside = true;
					hit_data.Hit_New_Dir *= -1.0;
				}
			}
		}
	}
	for (int i = 0; i < QUAD_COUNT; i++) {
		float resultRayLength;
		if (f_QuadIntersection(ray, Scene_Quads[i], resultRayLength)) {
			if(resultRayLength < hit_data.Ray_Length && resultRayLength > 0.001) {
				Quad quad = Scene_Quads[i];
				hit_data.Ray_Length = resultRayLength;
				hit_data.Hit_Pos = ray.Ray_Origin + ray.Ray_Direction * resultRayLength;
				vec3 nor = normalize(cross(quad.v2 - quad.v1, quad.v3 - quad.v1));
				hit_data.Hit_New_Dir = faceforward( nor, ray.Ray_Direction, nor );
				hit_data.Hit_Mat = quad.Mat;
				hit_data.Hit_Obj = i + SPHERE_COUNT;
			}
		}
	}
	for (int i = 0; i < TORUS_COUNT; i++) {
		float resultRayLength;
		if (f_TorusIntersection(ray, Scene_Tori[i], resultRayLength)) {
			if(resultRayLength < hit_data.Ray_Length && resultRayLength > 0.001) {
				Torus torus = Scene_Tori[i];
				hit_data.Ray_Length = resultRayLength;
				hit_data.Hit_Pos = ray.Ray_Origin + ray.Ray_Direction * resultRayLength;

				vec2 q = vec2(length(hit_data.Hit_Pos.xz), hit_data.Hit_Pos.y);
				hit_data.Hit_New_Dir = normalize(vec3(hit_data.Hit_Pos.x - 2.0 * torus.Torus_Radius * q.x, 2.0 * torus.Torus_Radius * q.y, hit_data.Hit_Pos.z));
				hit_data.Hit_Mat = torus.Mat;
				hit_data.Hit_Obj = i + SPHERE_COUNT + QUAD_COUNT;
				if (distance(ray.Ray_Origin, torus.Position) <=torus.Inner_Radius) {
					hit_data.Ray_Inside = true;
					//hit_data.Hit_New_Dir *= -1.0;
				}
			}
		}
	}
	return hit_data;
}

vec3 f_EnvironmentHDR(in Ray r) {
	r.Ray_Direction = eulerToRot(vec3(0,-90,0)) * r.Ray_Direction;

	float phi = atan(r.Ray_Direction.y, r.Ray_Direction.x);
	float theta = acos(r.Ray_Direction.z);
	float u = phi / TWO_PI + 0.5;
	float v = theta / PI;

	return texture(iHdri, vec2(u,v)).rgb * HDRI_STRENGTH;
}

vec3 f_AmbientOcclusion(in Ray r) {
	float distPercent;
	for (int b = 0; b < 2; b++){
		Hit hit_data = f_SceneIntersection(r);
		if (hit_data.Ray_Length >= MAX_DIST) {
			return vec3(0.0); // MISS;
		}
		r.Ray_Direction = f_ConeRoughness(hit_data.Hit_New_Dir, 10.0);
		r.Ray_Origin = hit_data.Hit_Pos + r.Ray_Direction * 0.001;
		distPercent = min(hit_data.Ray_Length / AO_LENGTH, 1.0);
	}
	return vec3(distPercent, distPercent, distPercent);
}

vec3 f_BidirectionalSampling(const in Hit hit_data, in int object_id, out float inv_prob) {
	if (object_id < SPHERE_COUNT) {
		Sphere sphere = Scene_Spheres[object_id];
		vec3 dir = normalize(sphere.Position - hit_data.Hit_Pos);
		float dist = length(sphere.Position - hit_data.Hit_Pos);
		float theta = asin(sphere.Diameter / dist);
		Ray r = Ray(hit_data.Hit_Pos + hit_data.Hit_New_Dir * EPSILON, f_ConeRoughness(dir, theta));

		inv_prob = (2.0 * (1.0 - cos(theta)));

		Hit hit = f_SceneIntersection(r);
		if (hit.Hit_Mat.Type == EMISSIVE && hit.Hit_Obj == object_id) {
			return sphere.Mat.Color * sphere.Mat.Emissive_Strength * max(0.0, dot(r.Ray_Direction, hit_data.Hit_New_Dir)) * inv_prob;
		}
	}
	else if (object_id < SPHERE_COUNT + QUAD_COUNT) {
		Quad quad = Scene_Quads[object_id - SPHERE_COUNT];
		vec3 dir = normalize(quad.v0 - hit_data.Hit_Pos);
		float dist = length(quad.v0 - hit_data.Hit_Pos);
		float theta = asin(1.0 / dist);
		Ray r = Ray(hit_data.Hit_Pos + hit_data.Hit_New_Dir * EPSILON, f_ConeRoughness(dir, theta));
		inv_prob = (2.0 * (1.0 - cos(theta)));
		Hit hit = f_SceneIntersection(r);
		if (hit.Hit_Mat.Emissive_Strength > 0 && hit.Hit_Obj == object_id) {
			return quad.Mat.Color * quad.Mat.Emissive_Strength * max(0.0, dot(r.Ray_Direction, hit_data.Hit_New_Dir)) * inv_prob;
		}
	}
	else if (object_id < SPHERE_COUNT + QUAD_COUNT + TORUS_COUNT) {
		Torus torus = Scene_Tori[object_id - SPHERE_COUNT - QUAD_COUNT];
		vec3 dir = normalize(torus.Position - hit_data.Hit_Pos);
		float dist = length(torus.Position - hit_data.Hit_Pos);
		float theta = asin(1.0 / dist);
		Ray r = Ray(hit_data.Hit_Pos + hit_data.Hit_New_Dir * EPSILON, f_ConeRoughness(dir, theta));
		inv_prob = (2.0 * (1.0 - cos(theta)));
		Hit hit = f_SceneIntersection(r);
		if (hit.Hit_Mat.Emissive_Strength > 0 && hit.Hit_Obj == object_id) {
			return torus.Mat.Color * torus.Mat.Emissive_Strength * max(0.0, dot(r.Ray_Direction, hit_data.Hit_New_Dir)) * inv_prob;
		}
	}
	else {
		return f_EnvironmentHDR(Ray(hit_data.Hit_Pos + hit_data.Hit_New_Dir * EPSILON, hit_data.Hit_New_Dir));
	}
}

vec3 f_Radiance(in Ray r){
	vec3 rad = vec3(0);
	vec3 brdf = vec3(1);

	for (int b = 0; b < RAY_BOUNCES; b++) {
		Hit hit_data = f_SceneIntersection(r);

		if (hit_data.Ray_Length >= MAX_DIST) {
			return rad + brdf * f_EnvironmentHDR(r); // MISS;
		}
		float prob = 0.;
		if (hit_data.Hit_Mat.Type == DIFFUSE) {
			vec3 tangent = normalize(cross(r.Ray_Direction, hit_data.Hit_New_Dir));
			vec3 bitangent = normalize(cross(hit_data.Hit_New_Dir, tangent));
			vec3 nr = cosine_weighted_hemi_sample();;
			r.Ray_Direction = normalize(tangent * nr.x + bitangent * nr.y + hit_data.Hit_New_Dir * nr.z);
			brdf *= hit_data.Hit_Mat.Color;
			if (iBidirectional) {
				for (int i = 0; i < SPHERE_COUNT; i++) {
					rad += brdf * f_BidirectionalSampling(hit_data, i, prob);
				}
			}
		}
		else if (hit_data.Hit_Mat.Type == SPECULAR) {
			r.Ray_Direction = reflect(r.Ray_Direction, hit_data.Hit_New_Dir);
			brdf *= hit_data.Hit_Mat.Color;
		}
		else if (hit_data.Hit_Mat.Type == GLASS) {
			float cosi = abs(dot(hit_data.Hit_New_Dir, r.Ray_Direction));
			float sini = sqrt(1. - cosi * cosi);
			float iort = hit_data.Hit_Mat.IOR;
			float iori = 1.0;
			if (hit_data.Ray_Inside){
				iori = iort;
				iort = 1.0;
			}
			float sint = snell(sini, iori, iort);
			float cost = sqrt(1.0 - sint * sint);
			float frsn = fresnel(iori, iort, cosi, cost);

			if (rand1() > frsn){
				vec3 bitangent = normalize(r.Ray_Direction - dot(hit_data.Hit_New_Dir, r.Ray_Direction) * hit_data.Hit_New_Dir);
				r.Ray_Direction = normalize(bitangent * sint - cost * hit_data.Hit_New_Dir);
				brdf *= hit_data.Hit_Mat.Color;
			}
			else {
				r.Ray_Direction = reflect(r.Ray_Direction, normalize(hit_data.Hit_New_Dir + rgb_noise * hit_data.Hit_Mat.Roughness));
			}
		}
		else if (hit_data.Hit_Mat.Type == EMISSIVE) { // EMISSIVE
			return rad + brdf * hit_data.Hit_Mat.Color * hit_data.Hit_Mat.Emissive_Strength;
		}
		r.Ray_Origin = hit_data.Hit_Pos + r.Ray_Direction * 0.001;
	}
	return rad;
}

vec3 f_ZDepth(in Ray r) {
	Hit hit_data = f_SceneIntersection(r);
	if (hit_data.Ray_Length >= MAX_DIST) {
		return vec3(0.0); // MISS;
	}
	return vec3(1 - min(hit_data.Ray_Length / 50.0, 0.9));
}

Ray f_CameraRay(vec2 uv) {
	vec3 projection_center = iCameraPos + iCameraFocalLength * iCameraFront;
	vec3 projection_u = normalize(cross(iCameraFront, iCameraUp)) * iCameraSensorWidth;
	vec3 projection_v = normalize(cross(projection_u, iCameraFront)) * (iCameraSensorWidth / 1.0);
	return Ray(iCameraPos, normalize(projection_center + (projection_u * uv.x) + (projection_v * uv.y) - iCameraPos) );
}

// Main ---------------------------------------------------------------------------------------
void main() {
	if (iFrame < SAMPLES) {
		rng_initialize(gl_FragCoord.xy, iFrame);
		const vec2 uv = (gl_FragCoord.xy - 1.0 - iResolution.xy /2.0) / max(iResolution.x, iResolution.y);
		const vec2 pixel_size = 1/ iResolution.xy;

		// -------------------------- Ambient Occlusion
		if (iRenderMode == 0) {
			vec3 col;
			for (int x = 0; x < SPP; x++) {
				for (int y = 0; y < SPP; y++) {
					vec2 subpixelUV = uv - (vec2(0.5) * pixel_size) + (vec2(float(x) / float(SPP), float(y) / float(SPP)) * pixel_size);
					col += f_AmbientOcclusion(f_CameraRay(subpixelUV));
				}
			}
			col /= float(SPP * SPP);
			fragColor = vec4(col , 1);
		}
		// -------------------------- PathTracer
		else if (iRenderMode == 1) {
			vec3 col;
			for (int x = 0; x < SPP; x++) {
				for (int y = 0; y < SPP; y++) {
					vec2 subpixelUV = uv - (vec2(0.5) * pixel_size) + (vec2(float(x) / float(SPP), float(y) / float(SPP)) * pixel_size);
					col += f_Radiance(f_CameraRay(subpixelUV));
				}
			}

			col /= float(SPP * SPP);
			fragColor = vec4(col, 1);
		}
		// -------------------------- Z-Depth
		else if (iRenderMode == 2) {
			fragColor = vec4(f_ZDepth(f_CameraRay(uv)) , 1);
		}
	}
	else {
		fragColor = vec4(0);
	}
}