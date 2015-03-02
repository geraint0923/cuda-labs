#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <cutil.h>
#include "util.h"
#include "ref_2dhisto.h"



void* allocCudaMem(size_t size) {
	void *ptr;
	cudaMalloc(&ptr, size);
	return ptr;
}

void freeCudaMem(void *ptr) {
	cudaFree(ptr);
}

void copyToDevice(void *src, void *dst, size_t size) {
	cudaMemcpy(dst, src, size, cudaMemcpyHostToDevice);
	cudaThreadSynchronize();
}

void copyFromDevice(void *src, void *dst, size_t size) {
	cudaMemcpy(dst, src, size, cudaMemcpyDeviceToHost);
	cudaThreadSynchronize();
}

__global__ void clear_bins(uint32_t *bins) {
	const int idx = threadIdx.x + threadIdx.y * blockDim.x + blockIdx.x * blockDim.x * blockDim.y
		+ blockIdx.y * gridDim.x * blockDim.x * blockDim.y,
	    tsz = blockDim.x * blockDim.y * gridDim.x * gridDim.y;
#pragma unroll
	for(int i = idx; i < HISTO_WIDTH * HISTO_HEIGHT; i += tsz) {
		bins[i] = 0;
	}
}

__global__ void do_histogram(uint32_t *input, size_t height, size_t width, uint32_t *bins) {
	const int idx = threadIdx.x + threadIdx.y * blockDim.x + blockIdx.x * blockDim.x * blockDim.y
		+ blockIdx.y * gridDim.x * blockDim.x * blockDim.y,
	    bsz = blockDim.x * blockDim.y, sz = height * width,
	    tsz = blockDim.x * blockDim.y * gridDim.x * gridDim.y;
	const int hsz = HISTO_WIDTH * HISTO_HEIGHT;
	__shared__ uint32_t histo[(hsz + 2) / 3][32];

#pragma unroll
	for(int i = threadIdx.x + threadIdx.y * blockDim.x; i < ((hsz + 2) / 3) * 32; i += bsz) {
		((uint32_t*)histo)[i] = 0;
	}

	__syncthreads();

#pragma unroll
	for(int i = idx; i < sz; i += tsz) {
		const uint32_t value = input[i];
		const uint32_t x = value / 3, y = value % 3;
		atomicAdd(&histo[x][threadIdx.x], 1 << (y * 10));
	}

	__syncthreads();

	uint32_t *hptr = (uint32_t*)histo;
#pragma unroll
	for(int i = threadIdx.x + threadIdx.y * blockDim.x; i < (hsz + 2) / 3; i += bsz) {
		const uint32_t val = hptr[32 * i + threadIdx.x];
		uint32_t sum0 = val & 0x3ff;
		uint32_t sum1 = (val >> 10) & 0x3ff;
		uint32_t sum2 = (val >> 20) & 0x3ff;
#pragma unroll
		for(int j = 1; j < 32; j++) {
			const uint32_t vv = hptr[32 * i + (threadIdx.x + j) % 32];
			sum0 += vv & 0x3ff;
			sum1 += (vv >> 10) & 0x3ff;
			sum2 += (vv >> 20) & 0x3ff;
		}
		atomicAdd(&bins[i*3], sum0);
		atomicAdd(&bins[i*3+1], sum1);
		atomicAdd(&bins[i*3+2], sum2);
	}
}

__global__ void copy_bins(uint32_t *bins32, uint8_t *bins8) {
	const int idx = threadIdx.x + threadIdx.y * blockDim.x + blockIdx.x * blockDim.x * blockDim.y
		+ blockIdx.y * gridDim.x * blockDim.x * blockDim.y,
	    tsz = blockDim.x * blockDim.y * gridDim.x * gridDim.y;
#pragma unroll
	for(int i = idx; i < HISTO_WIDTH * HISTO_HEIGHT; i += tsz) {
		bins8[i] = bins32[i] > UINT8_MAX ? UINT8_MAX : bins32[i];
	}
}

void opt_2dhisto(uint32_t *input, size_t height, size_t width, uint8_t *bins8, uint32_t *bins32)
{
    /* This function should only contain a call to the GPU 
       histogramming kernel. Any memory allocations and
       transfers must be done outside this function */
    clear_bins<<<dim3(1, 1), dim3(32, 32)>>>(bins32);
    do_histogram<<<dim3(height*width/((1023/32)*32*32)+1,1), dim3(32, 32)>>>(input, height, width, bins32);
    copy_bins<<<dim3(1, 1), dim3(32, 32)>>>(bins32, bins8);
    cudaThreadSynchronize();
}

/* Include below the implementation of any other functions you need */

