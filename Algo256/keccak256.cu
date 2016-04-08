/*
 * Keccak 256
 *
 */

extern "C"
{
#include "sph/sph_shavite.h"
#include "sph/sph_simd.h"
#include "sph/sph_keccak.h"

#include "miner.h"
}

#include "cuda_helper.h"

extern uint32_t *d_nounce[MAX_GPUS];

extern void keccak256_cpu_init(int thr_id);
extern void keccak256_cpu_free(int thr_id);
extern void keccak256_setBlock_80(uint64_t *PaddedMessage80);
extern uint32_t keccak256_cpu_hash_80(int thr_id, uint32_t threads, uint32_t startNounce,const uint64_t highTarget);

// CPU Hash
extern "C" void keccak256_hash(void *state, const void *input)
{
	uint32_t _ALIGN(64) hash[16];
	sph_keccak_context ctx_keccak;

	sph_keccak256_init(&ctx_keccak);
	sph_keccak256 (&ctx_keccak, input, 80);
	sph_keccak256_close(&ctx_keccak, (void*) hash);

	memcpy(state, hash, 32);
}

static bool init[MAX_GPUS] = { 0 };

extern "C" int scanhash_keccak256(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done){

	uint32_t _ALIGN(64) endiandata[20];
	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;
	const uint32_t first_nonce = pdata[19];

	int dev_id = device_map[thr_id];
	int intensity = (device_sm[dev_id] >= 500 && !is_windows()) ? 28 : 25;
	uint32_t throughput = cuda_default_throughput(thr_id, 1U << intensity);
	if (init[thr_id]) throughput = min(throughput, max_nonce - first_nonce);

	const uint64_t highTarget = *(uint64_t*)&ptarget[6];
	
	if (opt_benchmark)
		ptarget[7] = 0x000f;

	if (!init[thr_id]) {
		cudaSetDevice(device_map[thr_id]);
		if (opt_cudaschedule == -1 && gpu_threads == 1) {
			cudaDeviceReset();
			// reduce cpu usage (linux)
			cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
			cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
			CUDA_LOG_ERROR();
		}
		keccak256_cpu_init(thr_id);

		init[thr_id] = true;
	}

	for (int k=0; k < 20; k++) {
		be32enc(&endiandata[k], pdata[k]);
	}

	keccak256_setBlock_80((uint64_t*)endiandata);
	cudaMemset(d_nounce[thr_id], 0xff, sizeof(uint32_t));
	do {
		uint32_t foundNonce = keccak256_cpu_hash_80(thr_id, throughput, pdata[19],highTarget);
		if (foundNonce != UINT32_MAX && bench_algo < 0)
		{
			uint32_t _ALIGN(64) vhash64[8];
			be32enc(&endiandata[19], foundNonce);
			keccak256_hash(vhash64, endiandata);

			if (vhash64[7] <= ptarget[7] && fulltest(vhash64, ptarget)) {
				*hashes_done = pdata[19] - first_nonce + throughput;
				work_set_target_ratio(work, vhash64);
				pdata[19] = foundNonce;
				return 1;
			}
			else {
				gpulog(LOG_WARNING, thr_id, "result for %08x does not validate on CPU!", foundNonce);
				cudaMemset(d_nounce[thr_id], 0xff, sizeof(uint32_t));				
			}
		}

		pdata[19] += throughput;

	} while (!work_restart[thr_id].restart && max_nonce > (uint64_t)throughput + pdata[19]);

	*hashes_done = pdata[19] - first_nonce;

	MyStreamSynchronize(NULL, 0, device_map[thr_id]);

	return 0;

}

// cleanup
extern "C" void free_keccak256(int thr_id)
{
	if (!init[thr_id])
		return;

	cudaThreadSynchronize();

	keccak256_cpu_free(thr_id);

	cudaDeviceSynchronize();
	init[thr_id] = false;
}
