#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <utility>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"
#include <iostream>
#include <iomanip>
#include <string>

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 20.0f
#define rule2Distance 4.0f
#define rule3Distance 10.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f
//  this is the number of cells that could be neighbors
//  add 1 to indicate the end of the array.
#define maxGridCells 9

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3  *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
// during the swap, we need to rearrange the positions.  This involves copying
// positions from one location to another.  A second buffer is needed, not just a single
// glm::vec3 position because it is not a simple swap.
glm::vec3 *dev_posCopy;
// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;


// print index Array matrices

static const int numPerRow{20};
static const int spacePerInt{5};
static const int numPerRowVec3{3};
static const int spacePerFloat{10};
static const int precision{2};
/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}


/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");
  cudaMemset(dev_vel1, 0.0, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("Initializing dev_vel1 failed");
  
  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");
  cudaMemset(dev_vel2, 0.0, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("Initializing dev_vel2 failed");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max({rule1Distance, rule2Distance, 
			                    rule3Distance});
  gridInverseCellWidth = 1.0f / gridCellWidth;
  int halfSideCount = static_cast<int>(scene_scale * gridInverseCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  // allocation for 2.1 arrays
  cudaMalloc(reinterpret_cast<void**>(&dev_particleArrayIndices), numObjects * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");
 
  cudaMalloc(reinterpret_cast<void**>(&dev_particleGridIndices), numObjects * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");
  
  cudaMalloc(reinterpret_cast<void**>(&dev_gridCellStartIndices), gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc devgridCellStartIndices failed!");
  
  cudaMalloc(reinterpret_cast<void**>(&dev_gridCellEndIndices), gridCellCount * sizeof(int));

  
  dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices  = thrust::device_ptr<int>(dev_particleGridIndices);
  checkCUDAErrorWithLine("Assign dev_thrust_pointers failed!");

  // allocate for the position copy
  cudaMalloc((void**)&dev_posCopy, numObjects * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_posCopy failed!");
  
  cudaThreadSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaThreadSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 rule1(int N, int iSelf, const glm::vec3 * pos, float scale)
{
	glm::vec3 pc(0.f, 0.0f, 0.0f);
	int n {0};
	for ( int i {0}; i < iSelf; ++i){
           if ( glm::length(pos[i] - pos[iSelf]) < rule1Distance) {
		pc += pos[i];
		++n;
	   }
	}
	for( int i {iSelf + 1} ; i < N; ++i){
           if ( glm::length(pos[i] - pos[iSelf]) < rule1Distance) {
		pc += pos[i];
		++n;
	   }
	}
	if ( n == 0)
	{
		return glm::vec3(0.f);
	}
        pc /= n;
	return (pc - pos[iSelf]) * scale;
}
__device__ glm::vec3 rule1Scatter(int iSelf, int const * gridCellStartIndices,
		int const * gridCellEndIndices, int const * particleArrayIndices,
		glm::vec3 const * pos, int const usedGridIndices[maxGridCells],
		float scale)
{
	glm::vec3 pc(0.0f, 0.0f, 0.0f);
	int n {0};
	for (int k{0}; usedGridIndices[k] != -1; ++k)
	{
		int gridC{ usedGridIndices[k] };
		//printf(" %d\n", gridC);
		for ( int i {gridCellStartIndices[gridC]}; i < gridCellEndIndices[gridC]; ++i){
		      int neighbor = particleArrayIndices[i];
			  //printf("neighbor: %d\n", neighbor);
			//int neighbor = i;
		      if ( neighbor == iSelf) {
			      continue;
		      }
                      if ( glm::length(pos[neighbor] - pos[iSelf]) < rule1Distance) {
		                pc += pos[neighbor];
		                  ++n;
	              }
	    }
	}
	if ( n == 0)
	{
		return glm::vec3(0.f);
	}
        pc /= n;
	return (pc - pos[iSelf]) * scale;
}
__device__ glm::vec3 rule1Coherent(int iSelf, int const * gridCellStartIndices,
		int const * gridCellEndIndices,
		glm::vec3 const * pos, int const usedGridIndices[maxGridCells],
		float scale)
{
	glm::vec3 pc(0.0f, 0.0f, 0.0f);
	int n {0};
	for (int k{0}; usedGridIndices[k] != -1; ++k)
	{
		int gridC{ usedGridIndices[k] };
		//printf(" %d\n", gridC);
		for ( int neighbor {gridCellStartIndices[gridC]}; neighbor < gridCellEndIndices[gridC]; ++neighbor){
		      if ( neighbor == iSelf) {
			      continue;
		      }
                      if ( glm::length(pos[neighbor] - pos[iSelf]) < rule1Distance) {
		                pc += pos[neighbor];
		                  ++n;
	              }
	    }
	}
	if ( n == 0)
	{
		return glm::vec3(0.f);
	}
        pc /= n;
	return (pc - pos[iSelf]) * scale;
}
__device__ glm::vec3 rule2(int N, int iSelf, const glm::vec3 * pos, float scale)
{
	glm::vec3 c{ 0.f };
	for ( int i {0}; i < iSelf; ++i){
           if ( glm::length(pos[i] - pos[iSelf]) < rule2Distance) {
		c -= pos[i]  - pos[iSelf];
	   }
	}
	for( int i {iSelf + 1}; i < N; ++i){
           if ( glm::length(pos[i] - pos[iSelf]) < rule2Distance) {
		c -= pos[i] - pos[iSelf];
	   }
	}
	return c * scale;
}
__device__ glm::vec3 rule2Scatter(int iSelf, int const * gridCellStartIndices,
		int const * gridCellEndIndices, int const * particleArrayIndices,
		glm::vec3 const * pos, int const usedGridIndices[maxGridCells],
		float scale)
{
	glm::vec3 c{ 0.f, 0.f, 0.f };
	for (int k{0}; usedGridIndices[k] != -1; ++k)
	{
	    int gridC{ usedGridIndices[k] };
	    for ( int i {gridCellStartIndices[gridC]}; i < gridCellEndIndices[gridC]; ++i){
		      int neighbor = particleArrayIndices[i];
		      if ( neighbor == iSelf) {
			      continue;
		      }
                      if ( glm::length(pos[neighbor] - pos[iSelf]) < rule2Distance) {
		                c -= pos[neighbor]  - pos[iSelf];
	              }
	    }
	}
	return c * scale;
}
__device__ glm::vec3 rule2Coherent(int iSelf, int const * gridCellStartIndices,
		int const * gridCellEndIndices,
		glm::vec3 const * pos, int const usedGridIndices[maxGridCells],
		float scale)
{
	glm::vec3 c{ 0.f, 0.f, 0.f };
	for (int k{0}; usedGridIndices[k] != -1; ++k)
	{
	    int gridC{ usedGridIndices[k] };
	    for ( int neighbor {gridCellStartIndices[gridC]}; neighbor < gridCellEndIndices[gridC];
			    ++neighbor){
		      if ( neighbor == iSelf) {
			      continue;
		      }
                      if ( glm::length(pos[neighbor] - pos[iSelf]) < rule2Distance) {
		                c -= pos[neighbor]  - pos[iSelf];
	              }
	    }
	}
	return c * scale;
}
__device__ glm::vec3 rule3(int N, int iSelf, const glm::vec3 * pos,
	                                    const glm::vec3 *vel, float scale)
{
	glm::vec3 vsum{ 0.0f, 0.0f, 0.0f };
	int n{0};
	for ( int i {0}; i < iSelf; ++i){
           if ( glm::length(pos[i] - pos[iSelf]) < rule3Distance) {
					vsum += vel[i];
					++n;
	   }
	}
	for( int i {iSelf + 1} ; i < N; ++i){
           if ( glm::length(pos[i] - pos[iSelf]) < rule3Distance) {
					vsum += vel[i];
					++n;
	   }
	}
        if (n != 0) {
		vsum *= scale / n;
	}
	return vsum;
}
__device__ glm::vec3 rule3Scatter(int iSelf, int const * gridCellStartIndices,
		int const * gridCellEndIndices, int const * particleArrayIndices,
		glm::vec3 const * pos, glm::vec3 const * vel, 
		int const usedGridIndices[maxGridCells],
		float scale)
{
	glm::vec3 vsum{ 0.0f };
	int n{0};
	for (int k{0}; usedGridIndices[k] != -1; ++k)
	{
	    int gridC{ usedGridIndices[k] };
	    for ( int i {gridCellStartIndices[gridC]}; i < gridCellEndIndices[gridC]; ++i){
		      int neighbor = particleArrayIndices[i];
		      if ( neighbor == iSelf) {
			      continue;
		      }
                      if ( glm::length(pos[neighbor] - pos[iSelf]) < rule3Distance) {
					vsum += vel[neighbor];
					++n;
	              }
	     }
	}
        if (n != 0) {
		vsum *= scale / n;
	}
	return vsum;
}
__device__ glm::vec3 rule3Coherent(int iSelf, int const * gridCellStartIndices,
		int const * gridCellEndIndices,
		glm::vec3 const * pos, glm::vec3 const * vel, 
		int const usedGridIndices[maxGridCells],
		float scale)
{
	glm::vec3 vsum{ 0.0f };
	int n{0};
	for (int k{0}; usedGridIndices[k] != -1; ++k)
	{
	    int gridC{ usedGridIndices[k] };
	    for ( int neighbor {gridCellStartIndices[gridC]}; neighbor < gridCellEndIndices[gridC]; 
			    ++neighbor){
		      if ( neighbor == iSelf) {
			      continue;
		      }
                      if ( glm::length(pos[neighbor] - pos[iSelf]) < rule3Distance) {
					vsum += vel[neighbor];
					++n;
	              }
	     }
	}
        if (n != 0) {
		vsum *= scale / n;
	}
	return vsum;
}

// compute Velocity Change Scattered will get the velocity change with the uniform grid
__device__ glm::vec3 computeVelocityChangeScattered(int iSelf, const int * gridCellStartIndices, 
		const int * gridCellEndIndices, const int * particleArrayIndices, const glm::vec3 *pos,
	const glm::vec3 *vel, int usedGridIndices[maxGridCells] ) 
{
  // Rule 1: boids fly towards their local pe:rceived center of mass, which excludes themselves
	// move towards the average
   glm::vec3 v { rule1Scatter(iSelf, gridCellStartIndices, gridCellEndIndices,
		              particleArrayIndices, pos, usedGridIndices,  rule1Scale)};
   //printf("%f %f %f\n", v.x, v.y, v.z);
   // keep a boids apart
  //Rule 2: boids try to stay a distance d away from each other
    v += rule2Scatter(iSelf, gridCellStartIndices, gridCellEndIndices,
         	             particleArrayIndices, pos, usedGridIndices,  rule2Scale);
   // Rule 3: boids try to match the speed of surrounding boids
    v += rule3Scatter(iSelf, gridCellStartIndices, gridCellEndIndices,
  		             particleArrayIndices, pos, vel, usedGridIndices, rule3Scale);
  return v;
}
// compute Velocity Change Scattered will get the velocity change with the uniform grid
__device__ glm::vec3 computeVelocityChangeCoherent(int iSelf, const int * gridCellStartIndices, 
		const int * gridCellEndIndices, const glm::vec3 *pos,
	const glm::vec3 *vel, int usedGridIndices[maxGridCells] ) 
{
  // Rule 1: boids fly towards their local pe:rceived center of mass, which excludes themselves
	// move towards the average
   glm::vec3 v { rule1Coherent(iSelf, gridCellStartIndices, gridCellEndIndices,
		              pos, usedGridIndices,  rule1Scale)};
   //printf("%f %f %f\n", v.x, v.y, v.z);
   // keep a boids apart
  //Rule 2: boids try to stay a distance d away from each other
    v += rule2Coherent(iSelf, gridCellStartIndices, gridCellEndIndices,
         	             pos, usedGridIndices,  rule2Scale);
   // Rule 3: boids try to match the speed of surrounding boids
    v += rule3Coherent(iSelf, gridCellStartIndices, gridCellEndIndices,
  		             pos, vel, usedGridIndices, rule3Scale);
  return v;
}
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos,
	const glm::vec3 *vel) 
{
  // Rule 1: boids fly towards their local pe:rceived center of mass, which excludes themselves
	// move towards the average
   glm::vec3 v { rule1(N, iSelf, pos,  rule1Scale)};
   // keep a boids apart
  //Rule 2: boids try to stay a distance d away from each other
   v += rule2(N, iSelf, pos,  rule2Scale);
  // Rule 3: boids try to match the speed of surrounding boids
   v += rule3(N, iSelf, pos, vel, rule3Scale);
  return v;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
	 int boid = threadIdx.x + blockIdx.x * blockDim.x;
	 if (boid >= N) {
	         return;
	 }
	 glm::vec3 v3{ computeVelocityChange(N, boid, pos, vel1)};
	 vel2[boid] = vel1[boid] + v3;
	 float length = glm::length(vel2[boid]);
	 if (length  > maxSpeed){
		 vel2[boid] =  maxSpeed/length * vel2[boid];
	 }
  // Clamp the speed
  // Record the new velocity into vel2. Question: why NOT vel1?
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}
// returns true if the grid location is in range
__device__ bool gridInRange(int3 val, int gridResolution) {
	return (val.x >= 0 && val.x <= gridResolution && 
	        val.y >= 0 && val.y <= gridResolution &&
		val.z >= 0 && val.z <= gridResolution);
}
	
__device__ int3 boidGrid(const glm::vec3 location, const glm::vec3 gridMin, 
		        float inverseCellWidth)
{
    glm::vec3 boidCell = (location -  gridMin) * inverseCellWidth;
    return make_int3( (int) boidCell.x, (int) boidCell.y, (int) boidCell.z);
}
/// compute the grid and index arrays
__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {

    int boid = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (boid >= N) {
	    return;
    }
    int3 gridCoord = boidGrid(pos[boid] , gridMin, inverseCellWidth);
    int gridIndex = gridIndex3Dto1D(gridCoord.x, gridCoord.y, gridCoord.z, gridResolution);
    gridIndices[boid] = gridIndex;
    indices[boid]     = boid;


    // TODO-2.1
    // - Label each boid with the index of its grid cell.
    // - Set up a parallel array of integer indices as pointers to the actual
    //   boid data in pos and vel1/vel2
}
// LOOK-2.1 Consider how this could be useful for indicating that a cell
//       :   does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}


// findGridCells will  find the neigboring grid cells relative to 
// a boid.  usedGridCells is the array of 9 gridCells that may hold
// the neighboring gridCells
// the idea here is that boidoffset is longer than the max nearest neighbor
// distance but less than a cellWidth. the two extremes of a 8 grid cell
// cube are given here and all neighbors have to be within these 8 cells.
__device__ void findGridCells(int iSelf,  int gridResolution, 
		const glm::vec3 gridMin, float inverseCellWidth,
		float cellWidth,const int *gridCellStartIndices,
                const glm::vec3 *pos, int usedGridCells[maxGridCells]) 
{
  // includes the grid cells that are used here. last indicates end of array
  int   xoffsets[4] = { 0, 1, 0, 1};
  int   yoffsets[4] = { 0, 0, 1, 1};
  int currLoc = 0;
  glm::vec3 boidOffset = glm::vec3(cellWidth * 0.5f, cellWidth * 0.5f, cellWidth * 0.5f);
  glm::vec3 extremeBoid = pos[iSelf] + boidOffset;
  int3 cellindices = boidGrid( extremeBoid,  gridMin, inverseCellWidth);
  for (int i = 0; i < 4; ++i) 
  {
	  int3 cpy = make_int3(cellindices.x - xoffsets[i], 
			      cellindices.y - yoffsets[i], cellindices.z);
	  int gridCell = gridIndex3Dto1D(cpy.x, cpy.y, cpy.z, gridResolution);
	  if (gridInRange(cpy, gridResolution) && 
	       gridCellStartIndices[gridCell] != -1) {
                 usedGridCells[currLoc++] = gridCell;
	  }
  }
  extremeBoid = pos[iSelf] - boidOffset;
  cellindices = boidGrid( extremeBoid,  gridMin, inverseCellWidth);
  for (int i = 0; i < 4; ++i) 
  {
	  int3 cpy = make_int3(cellindices.x + xoffsets[i], 
			      cellindices.y + yoffsets[i], cellindices.z);
	  int gridCell = gridIndex3Dto1D(cpy.x, cpy.y, cpy.z, gridResolution);
	  if (gridInRange(cpy, gridResolution) &&  
	       gridCellStartIndices[gridCell] != -1) {
                 usedGridCells[currLoc++] = gridCell;
	  }
  }
  usedGridCells[currLoc] = -1; 
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) 
{
   
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
  // indicates the last cell that was found
  // use the parallel structure to unroll always comparing with the prior
  // The last grid occupied must be terminated.
  // the ordering is [gridCellStartIndex gridCellEndIndex) (inclusive, exclusive).
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= N) {
	  return;
  }
  int currentGridLoc = particleGridIndices[index];
  if ( index == 0) {
	  gridCellStartIndices[currentGridLoc] = index;
	  return;
  }
  int priorGridLoc = particleGridIndices[index - 1];
  // no change indicated here
  if ( priorGridLoc == currentGridLoc) {
	  return;
  }
  // there is a change compared to the prior--update Gridindices
  gridCellEndIndices[priorGridLoc]     = index;
  gridCellStartIndices[currentGridLoc] = index;
  // add the end of the currentNow
  if (index == N - 1) {
	  gridCellEndIndices[currentGridLoc] = N;
  }
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {

  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
  int iSelf = blockIdx.x * blockDim.x + threadIdx.x;
  if (iSelf >= N) {
	  return;
  }
  int usedGridCells[maxGridCells];
  iSelf = particleArrayIndices[iSelf];
  findGridCells(iSelf, gridResolution, gridMin, inverseCellWidth,
		cellWidth, gridCellStartIndices, pos, usedGridCells);

  glm::vec3 vchange {computeVelocityChangeScattered(iSelf, gridCellStartIndices, 
		gridCellEndIndices, particleArrayIndices, pos,
	        vel1, usedGridCells) };
  vel2[iSelf] = vel1[iSelf] + vchange;
  float length = glm::length(vel2[iSelf]);
  if (length  > maxSpeed){
		 vel2[iSelf] =  maxSpeed/length * vel2[iSelf];
  }
}

// kernMakeCoherent will take the particleArrayIndices and rewrite the glm::vec3 array 
// (could be position or velocity) and put it into the to location based on the pointers in
// the particleArrayIndices.  if particleArrayIndex[10] says 5 that means that 
// posNew[10] = posOld[5]; 
__global__ void kernMakeCoherent(int N, int const * particleArrayIndices, 
		glm::vec3 * to1, glm::vec3 const * from1, glm::vec3 * to2,
		glm::vec3 const * from2)
{
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	if (index >= N)
	{
		return;
	}
	int oldLocation = particleArrayIndices[index];
	to1[index] = from1[oldLocation];
	to2[index] = from2[oldLocation];
}
/// from vel1 to vel2 where vel2 is the new one.
__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
  int iSelf = blockIdx.x * blockDim.x + threadIdx.x;
  if (iSelf >= N) {
	  return;
  }
  int usedGridCells[maxGridCells];
  findGridCells(iSelf, gridResolution, gridMin, inverseCellWidth,
		cellWidth, gridCellStartIndices, pos, usedGridCells);

  glm::vec3 vchange {computeVelocityChangeCoherent(iSelf, gridCellStartIndices, 
		gridCellEndIndices, pos,
	        vel1, usedGridCells) };
  vel2[iSelf] = vel1[iSelf] + vchange;
  float length = glm::length(vel2[iSelf]);
  if (length  > maxSpeed){
		 vel2[iSelf] =  maxSpeed/length * vel2[iSelf];
  }
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {

     dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
     kernUpdateVelocityBruteForce<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos,
			dev_vel1, dev_vel2);
	 checkCUDAErrorWithLine("brute force failed");
	 kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
	 checkCUDAErrorWithLine("update Position Function Failed");
     

     std::swap(dev_vel1, dev_vel2);
     cudaDeviceSynchronize();
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
  // TODO-1.2 ping-pong the velocity buffers
}

void Boids::stepSimulationScatteredGrid(float dt) {
  
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed

  // compute the grid index of each boid
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>
	  (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
	   dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
  
  dim3 gridBlocksPerGrid((gridCellCount + blockSize -1) / blockSize);
  // initialize to -1 all the gridCells
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(gridCellCount,
		       dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(gridCellCount,
		       dev_gridCellEndIndices, -1);
  //Boids::testGridArrays("Before sorting Grid Cells");
  thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		      dev_thrust_particleArrayIndices);
  //Boids::testGridArrays("AfterGrid Cell Sorting");
  // update the start and end indices
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid, blockSize>>>(numObjects, 
		 dev_particleGridIndices, dev_gridCellStartIndices,
		  dev_gridCellEndIndices);
  cudaDeviceSynchronize();
  //Boids::testGridArrays("After StartEnd Assignment");
  // update the velocity
  kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGrid, blockSize>>>
	  (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
           gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices,
	   dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
  
  // update the position
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
  std::swap(dev_vel1, dev_vel2);
  cudaDeviceSynchronize();

}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>
	  (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
	   dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
  
  dim3 gridBlocksPerGrid((gridCellCount + blockSize -1) / blockSize);
  // initialize to -1 all the gridCells
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(gridCellCount,
		       dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<gridBlocksPerGrid, blockSize>>>(gridCellCount,
		       dev_gridCellEndIndices, -1);
  //Boids::testGridArrays("Before sorting Grid Cells");
  thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		      dev_thrust_particleArrayIndices);
 
  //  make the position and velocity coherent-- when a grid cell uses
  //  particle indices 2 to 4 that should also be the boid number;
 // Boids::seeFloatArray("positions before Sort", numObjects, dev_pos);
  //now dev_vel2 has the coherently ordered velocity
  // dev_posCopy also is coherently ordered
  kernMakeCoherent<<<fullBlocksPerGrid, blockSize>>>(numObjects, 
		   dev_particleArrayIndices, dev_posCopy, dev_pos,
		    dev_vel2, dev_vel1);
  // swap puts the coherent position back into dev_pos
  std::swap(dev_posCopy, dev_pos);
  //Boids::seeFloatArray("Positions after Sort", numObjects, dev_posCopy);
   //Boids::testGridArrays("AfterGrid Cell Sorting");
  // update the start and end indices
  kernIdentifyCellStartEnd<<<fullBlocksPerGrid, blockSize>>>(numObjects, 
		 dev_particleGridIndices, dev_gridCellStartIndices,
		  dev_gridCellEndIndices);
  //cudaDeviceSynchronize();
 // Boids::testGridArrays("After StartEnd Assignment");
  // update the velocity
  // dev_vel1 now has the updated velocity
  kernUpdateVelNeighborSearchCoherent<<<fullBlocksPerGrid, blockSize>>>
	  (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
           gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices,
	    dev_pos, dev_vel2, dev_vel1);
  // update the position
  kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel1);
  cudaDeviceSynchronize();
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  cudaFree(dev_posCopy);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  int *intKeys = new int[N];
  int *intValues = new int[N];

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys, sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues, sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys, dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues, dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  delete[] intKeys;
  delete[] intValues;
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
void printIndexPair(std::string name, int const * arr1, int const * arr2, int N)
{

	std::cout << name << std::endl;
	for (int nleft {0}; nleft < N; nleft+=numPerRow)
	{
             for (int i{nleft}; i < N && i < nleft + numPerRow; ++i)
	     {
                 std::cout << std::setw(spacePerInt) << i;
	     }
	     std::cout << std::endl;
             for (int i{nleft}; i < N && i < nleft + numPerRow; ++i)
	     {
                 std::cout << std::setw(spacePerInt) << arr1[i];
	     }
	     std::cout << std::endl;
	     for (int i{nleft}; i < N && i < nleft + numPerRow; ++i)
	     {
		     std::cout << std::setw(spacePerInt) << arr2[i];
	     }
	     std::cout << std::endl << std::endl;
	}
}
void printFloatArray(std::string name, int N, glm::vec3 const * arr)
{

	std::cout << name << std::endl;
	std::setprecision(precision);

	for (int nleft {0}; nleft < N; nleft+=numPerRowVec3)
	{
             for (int i{nleft}; i < N && i < nleft + numPerRowVec3; ++i)
	     {
                 std::cout << std::setw(spacePerInt) << i << ':';
		 std::cout << std::fixed << std::setprecision(precision) <<
			         std::setw(spacePerFloat) << arr[i].x;
		 std::cout << std::fixed << std::setw(spacePerFloat) << 
			 std::setprecision(precision) << arr[i].y;
		 std::cout << std::fixed << std::setprecision(precision) <<
			     std::setw(spacePerFloat) << arr[i].z;
		 std::cout << ';';
	     }
	     std::cout << std::endl;
	}
	std::cout << std::endl;
}

void Boids::testGridArrays(std::string msg)
{
   
  int *host_gridCellStartIndices { new int[gridCellCount]};
  int *host_gridCellEndIndices { new int[gridCellCount]};
  int *host_particleArrayIndices { new int[numObjects]};
  int *host_particleGridIndices { new int[numObjects]};

    
  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(host_gridCellStartIndices, dev_gridCellStartIndices, sizeof(int) * gridCellCount,
		  cudaMemcpyDeviceToHost);
  cudaMemcpy(host_gridCellEndIndices, dev_gridCellEndIndices, sizeof(int) * gridCellCount,
		  cudaMemcpyDeviceToHost);
  cudaMemcpy(host_particleArrayIndices, dev_particleArrayIndices, sizeof(int) * numObjects,
		  cudaMemcpyDeviceToHost);
  cudaMemcpy(host_particleGridIndices, dev_particleGridIndices, sizeof(int) * numObjects,
		  cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back of grid arrays failed!");
  std::cout << msg << std::endl;
  printIndexPair("GridIndex/ParticleIndex", host_particleGridIndices, host_particleArrayIndices,
		      numObjects);
  printIndexPair("GridStartEndArray", host_gridCellStartIndices, host_gridCellEndIndices, 
		        gridCellCount);
  delete[] host_gridCellStartIndices;
  delete[] host_gridCellEndIndices;
  delete[] host_particleArrayIndices;
  delete[] host_particleGridIndices;
}
void Boids::seeFloatArray(std::string msg, int N, glm::vec3 const * dev_array)
{
   
  glm::vec3 *host_array { new glm::vec3[N]};

    
  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(host_array, dev_array, sizeof(glm::vec3) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back of grid arrays failed!");
  std::cout << msg << std::endl;
  printFloatArray("float Array", N, host_array);
  delete[] host_array;
}
