#include "q4_mlp.cuh"
#include "q4_matmul.cuh"
#include "rope.cuh"
#include "rms_norm.cuh"
#include "../cuda_buffers.cuh"
#include "../util.cuh"
#include "../matrix.cuh"
#if defined(USE_ROCM)
#include "../hip_compat.cuh"
#endif

const int THREADS_X = 32;
const int THREADS_Y = 1;
const int THREADS_Z = 4;
const int BLOCKSIZE_X = 2; // 2*half == 1*uint32_t
const int BLOCKSIZE_Z = 4;

__global__ void update_cache_kernel
(
    const half* __restrict__ key_states,
    const half* __restrict__ value_states,
    half* __restrict__ key_cache,
    half* __restrict__ value_cache,
    const int head_dim,
    const int num_heads,
    const int q_len,
    const int max_seq_len,
    const int past_len
)
{
    //int state_shape[]  = {              num_heads,                  q_len, head_dim };
    int state_stride[] = {               head_dim,   head_dim * num_heads,        1 };
    int state_pos[]    = {                      0,                      0,        0 };

    //int cache_shape[]  = {              num_heads,            max_seq_len, head_dim };
    int cache_stride[] = { max_seq_len * head_dim,               head_dim,        1 };
    int cache_pos[]    = {                      0,               past_len,        0 };

    int size[]         = {              num_heads,                  q_len, head_dim };

    int x = (blockIdx.x * THREADS_X + threadIdx.x) * BLOCKSIZE_X; 
    int y = blockIdx.y * THREADS_Y + threadIdx.y;
    int z = (blockIdx.z * THREADS_Z + threadIdx.z) * BLOCKSIZE_Z;
    
    if (x >= size[2]) return;
    if (y >= size[1]) return;
    if (z >= size[0]) return;

    int state_offset = (z + state_pos[0]) * state_stride[0] + (y + state_pos[1]) * state_stride[1] + (x + state_pos[2]) * state_stride[2];
    int cache_offset = (z + cache_pos[0]) * cache_stride[0] + (y + cache_pos[1]) * cache_stride[1] + (x + cache_pos[2]) * cache_stride[2];

    const uint32_t* key_ptr = (uint32_t*) (key_states + state_offset);
    const uint32_t* value_ptr = (uint32_t*) (value_states + state_offset);
    uint32_t* key_cache_ptr = (uint32_t*) (key_cache + cache_offset);
    uint32_t* value_cache_ptr = (uint32_t*) (value_cache + cache_offset);

    #pragma unroll
    for (int k = 0; k < BLOCKSIZE_Z; k++)
    {
        *key_cache_ptr = *key_ptr;
        key_ptr += state_stride[0] / BLOCKSIZE_X;
        key_cache_ptr += cache_stride[0] / BLOCKSIZE_X;
    }
    #pragma unroll
    for (int k = 0; k < BLOCKSIZE_Z; k++)
    {
        *value_cache_ptr = *value_ptr;
        value_ptr += state_stride[0] / BLOCKSIZE_X;
        value_cache_ptr += cache_stride[0] / BLOCKSIZE_X;
    }
}

void q4_attn_cuda
(
    ExLlamaTuning* tuningParams,
    cudaStream_t stream,
    cublasHandle_t handle,
    half* x,
    const half* rms_norm_weight,    // shape == (x.shape[1],) == (dim,)
    float epsilon,
    half* query_states,
    half* key_states,
    half* value_states,
    Q4Matrix* q_proj,
    Q4Matrix* k_proj,
    Q4Matrix* v_proj,
    half* sin,
    half* cos,
    const int q_len,
    const int dim,
    const int head_dim,
    const int num_heads,
    const int past_len,
    half* key_cache,
    half* value_cache,
    const int max_seq_len,
    const int device_index
)
{
    CudaBuffers* buffers = get_buffers(device_index);

    half* temp_x = buffers->temp_state + q_len * dim; // TODO: ..
    rms_norm_cuda(tuningParams, x, rms_norm_weight, temp_x, epsilon, q_len, dim, device_index);

    // Project q, k, v

    q4_matmul_cuda(tuningParams, temp_x, q_len, q_proj, query_states);
    q4_matmul_cuda(tuningParams, temp_x, q_len, k_proj, key_states);
    q4_matmul_cuda(tuningParams, temp_x, q_len, v_proj, value_states);

    // Positional embeddings
    // TODO: these can be fused to reduce launch overhead by about 1500 ns and kernel time by a little, too

    int _rows = q_len * num_heads;
    rope_cuda(tuningParams, query_states, sin, cos, _rows, head_dim, num_heads, past_len);
    rope_cuda(tuningParams, key_states, sin, cos, _rows, head_dim, num_heads, past_len);

    // Update cache tensors with projected k, v

    dim3 threads(THREADS_X, THREADS_Y, THREADS_Z);

    dim3 blocks
    (
        head_dim / THREADS_X / BLOCKSIZE_X,
        q_len,
        num_heads / THREADS_Z / BLOCKSIZE_Z
    );

    update_cache_kernel<<<blocks, threads>>>
    (
        key_states,
        value_states,
        key_cache,
        value_cache,
        head_dim,
        num_heads,
        q_len,
        max_seq_len,
        past_len
    );
}

void q4_attn_2_cuda
(
    ExLlamaTuning* tuningParams,
    half* x,
    half* attn_output,
    Q4Matrix* o_proj,
    const int height
)
{
    q4_matmul_cuda(tuningParams, attn_output, height, o_proj, x, true);
}