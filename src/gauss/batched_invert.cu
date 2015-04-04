#include <stdio.h>
#include <errno.h>
#include <stdlib.h>

#include <cuda.h>
#include "cublas_v2.h"

#include "../../include/types.h"
#include "../../include/helper.h"
#include "../../include/inverse.h"

#define SWAP(x, y, z)	((z) = (x),(x) = (y),(y) = (z))

void pivotRow(cublasHandle_t &handle, int n, Array *a, Array *a_inv, int col, int batchSize) {
	cudaStream_t *streams = (cudaStream_t *) malloc(sizeof(cudaStream_t) * batchSize);
	for(int i = 0; i < batchSize; i++)
		cudaStreamCreate(&streams[i]);

	int *pivot = (int *) malloc(sizeof(int) * batchSize);
	for(int i = 0; i < batchSize; i++) {
		cublasSetStream(handle, streams[i]);
		cublasIsamax(handle,
				n - col,			// Number of elements to be searched
				a[i] + (col * n) + col,		// Starting position
				1,				// Increment in words (NOT BYTES)
				&pivot[i]);			// Maximum element in the col
	}
	cudaDeviceSynchronize();

	for(int i = 0; i < batchSize; i++) {
		int row = pivot[i] - 1 + col;		// Row number with maximum element (starts with 1)
		if(row == col)
			return;
		cublasSetStream(handle, streams[i]);
		cublasSswap(handle,
				n,				// Nuber of elements to be swapped
				a[i] + col,			// Current row
				n,				// Increment (becuase of column major)
				a[i] + row,			// Row with max pivot
				n);
		cublasSswap(handle, n, a_inv[i] + col, n, a_inv[i] + row, n);
	}
	cudaDeviceSynchronize();

	for(int i = 0; i < batchSize; i++)
		cudaStreamDestroy(streams[i]);
	free(pivot);
	free(streams);
}

__global__
void normalizeRow(Array *a, Array *a_inv, int n, int row) {
	__shared__ DataType scalar;

	if(threadIdx.x == 0)
		scalar = 1 / a[blockIdx.x][row * n + row];
	__syncthreads();

	a[blockIdx.x][threadIdx.x * n + row] *= scalar;
	a_inv[blockIdx.x][threadIdx.x * n + row] *= scalar;
}

__global__
void transform_matrix(Array *a, Array *a_inv, int row, int n, int batchSize) {
	extern __shared__ DataType shared[];

	DataType *scalars = &shared[0];
	DataType *currRowA = &shared[n];
	DataType *currRowI = &shared[2 * n];

	// store the scalars corresponding to the column 'row'
	scalars[threadIdx.x] = a[blockIdx.x][row * n + threadIdx.x];
	currRowA[threadIdx.x] = a[blockIdx.x][threadIdx.x * n + row];
	currRowI[threadIdx.x] = a_inv[blockIdx.x][threadIdx.x * n + row];
	__syncthreads();

	// no need to transform 'row'th row
	if(threadIdx.x == row)
		return;

	// Each thread transforms row
	for(int i = 0; i < n; i++) {
		a[blockIdx.x][i * n + threadIdx.x] -= (scalars[threadIdx.x] * currRowA[i]);
		a_inv[blockIdx.x][i * n + threadIdx.x] -= (scalars[threadIdx.x] * currRowI[i]);
	}
}

void invert(cublasHandle_t &handle, int n, Array *a, Array *a_inv, int batchSize) {
	for(int i = 0; i < n; i++) {
		// Pivot the matrix
		pivotRow(handle, n, a, a_inv, i, batchSize);

		// Make column entry to be one
		normalizeRow<<<batchSize, n>>>(a, a_inv, n, i);

		// number of threads equals number of rows
		transform_matrix<<<batchSize, n, 3 * n>>>(a, a_inv, i, n, batchSize);
	}
}

cudaError_t batchedCudaMalloc(Array* devArrayPtr, size_t *pitch, size_t arraySize, int batchSize) {
	char *devPtr;

	cudaError_t result = cudaMallocPitch((void**)&devPtr, pitch, arraySize, batchSize);

	if (cudaSuccess != result) {
		return result;
	}

	for (int i = 0; i < batchSize; ++i) {
		devArrayPtr[i] = (Array)devPtr;
		devPtr += *pitch;
	}

	return cudaSuccess;
}

extern "C" void inverse_gauss_batched_gpu(
		cublasHandle_t handle,
		int n,
		Array As,
		Array aInvs,
		int batchSize) {

	int k, i;
	Array *devAs;
	size_t pitchAs;
	Array *devAInvs;
	size_t pitchAInvs;

	const size_t ArraySize = sizeof(DataType) * n * n;

	gpuErrchk( cudaHostAlloc((void**)&devAs, sizeof(Array)*batchSize, cudaHostAllocDefault) );
	gpuErrchk( cudaHostAlloc((void**)&devAInvs, sizeof(Array)*batchSize, cudaHostAllocDefault) );

	gpuErrchk( batchedCudaMalloc(devAs, &pitchAs, ArraySize, batchSize) );
	gpuErrchk( batchedCudaMalloc(devAInvs, &pitchAInvs, ArraySize, batchSize) );

    memset(aInvs, 0, batchSize*ArraySize);

	for (k = 0; k < batchSize; ++k) {
	    for (i = 0; i < n; ++i) {
	    	aInvs[k*n*n + i*n + i] = 1.f;
    	}
	}

	gpuErrchk( cudaMemcpy2D(devAs[0], pitchAs, As, ArraySize, ArraySize, batchSize,
				cudaMemcpyHostToDevice) );
	gpuErrchk( cudaMemcpy2D(devAInvs[0], pitchAInvs, aInvs, ArraySize, ArraySize, batchSize,
				cudaMemcpyHostToDevice) );

	// Calculate Minv = Madd^-1, store result in Bs
	invert(handle, n, devAs, devAInvs, batchSize);
	// devAs: As
	// devAs: Minv
	// devAInvs: Madd

	gpuErrchk( cudaMemcpy2D(aInvs, ArraySize, devAInvs[0], pitchAInvs, ArraySize, batchSize,
				cudaMemcpyDeviceToHost) );
	gpuErrchk( cudaFree((void*)devAs[0]) );
	gpuErrchk( cudaFree((void*)devAInvs[0]) );
	gpuErrchk( cudaFreeHost((void*)devAs) );
	gpuErrchk( cudaFreeHost((void*)devAInvs) );
}

// int main(int argc, char *argv[]) {
// 	cublasHandle_t handle;
// 	int numMatrices, n;
// 	Array a, a_inv;

// 	cublasErrchk( cublasCreate(&handle) );

// 	readMatricesFile(argv[1], &numMatrices, &n, &n, &a);
// 	a_inv = (Array) malloc(sizeof(DataType) * numMatrices * n * n);
// 	printMatrixList(a, n, numMatrices);
// 	for(int i = 0; i < numMatrices; i++)
// 		for(int j = 0; j < n; j++)
// 			for(int k = 0; k < n; k++)
// 				if(j == k)
// 					a_inv[i * n * n + j * n + k] = 1;
// 				else
// 					a_inv[i * n * n + j * n + k] = 0;
// 	batchedInverse(handle, n, a, a_inv, numMatrices);
// 	printMatrixList(a_inv, n, numMatrices);

// 	gpuErrchk( cudaPeekAtLastError() );
// 	gpuErrchk( cudaDeviceSynchronize() );

// 	return 0;
// }
