#include "namegen.h"
#include "util.h"

#include <cassert>
#include <math.h>
#include <vector>

#define CHECK_CUDA(call)                                                 \
  do {                                                                   \
    cudaError_t status_ = call;                                          \
    if (status_ != cudaSuccess) {                                        \
      fprintf(stderr, "CUDA error (%s:%d): %s:%s\n", __FILE__, __LINE__, \
              cudaGetErrorName(status_), cudaGetErrorString(status_));   \
      exit(EXIT_FAILURE);                                                \
    }                                                                    \
  } while (0)

// You can modify the data structure as you want
struct Tensor {

  /* Alloc memory */
  Tensor(std::vector<int> shape_) {
    ndim = shape_.size();
    for (size_t i = 0; i < ndim; i++) {
      shape[i] = shape_[i];
    }

    N = num_elem();
//    buf = (float *)malloc(n * sizeof(float));
    CHECK_CUDA(cudaMalloc(&buf, N * sizeof(float)));
  }

  /* Alloc memory and copy */
  Tensor(std::vector<int> shape_, float *buf_) {
    ndim = shape_.size();
    for (size_t i = 0; i < ndim; i++) {
      shape[i] = shape_[i];
    }

    N = num_elem();
//    buf = (float *)malloc(n * sizeof(float));
    CHECK_CUDA(cudaMalloc(&buf, N * sizeof(float)));
    CHECK_CUDA(cudaMemcpy(buf, buf_, N * sizeof(float), cudaMemcpyHostToDevice));
  }

  ~Tensor() {
    if (buf != nullptr)
      cudaFree(buf);
  }

  size_t num_elem() {
    size_t sz = 1;
    for (size_t i = 0; i < ndim; i++)
      sz *= shape[i];
    return sz;
  }

  // gpu Pointer to data
  float *buf = nullptr;

  // Shape of tensor, from outermost dimension to innermost dimension.
  // e.g., {{1.0, -0.5, 2.3}, {4.3, 5.6, -7.8}} => shape = {2, 3}
  size_t ndim = 0;
  size_t N = 0;
  size_t shape[4];
};

/* Network parameters */
Tensor *character_embedding;
Tensor *W_ir0, *W_iz0, *W_in0, *W_ir1, *W_iz1, *W_in1;
Tensor *W_hr0, *W_hz0, *W_hn0, *W_hr1, *W_hz1, *W_hn1;
Tensor *b_ir0, *b_iz0, *b_in0, *b_ir1, *b_iz1, *b_in1;
Tensor *b_hr0, *b_hz0, *b_hn0, *b_hr1, *b_hz1, *b_hn1;
Tensor *W_fc, *b_fc;
float *rfloats;

/* input, activations, output */
Tensor *input, *emb_out;
Tensor *hidden0, *hidden1;
Tensor *r0, *r1, *z0, *z1, *n0, *n1, *f, *char_prob;
Tensor *rtmp00, *rtmp01, *rtmp02, *rtmp03, *rtmp04;
Tensor *rtmp10, *rtmp11, *rtmp12, *rtmp13, *rtmp14;
Tensor *ztmp00, *ztmp01, *ztmp02, *ztmp03, *ztmp04;
Tensor *ztmp10, *ztmp11, *ztmp12, *ztmp13, *ztmp14;
Tensor *ntmp00, *ntmp01, *ntmp02, *ntmp03, *ntmp04, *ntmp05;
Tensor *ntmp10, *ntmp11, *ntmp12, *ntmp13, *ntmp14, *ntmp15;
Tensor *htmp00, *htmp01, *htmp02;
Tensor *htmp10, *htmp11, *htmp12;
Tensor *ftmp0;

float* exps;
float* sm_output_gpu;

/* Operations */
/*
 * Embedding
 * input: [1] (scalar)
 * weight: [NUM_CHAR x EMBEDDING_DIM]
 * output: [EMBEDDING_DIM]
 */
__global__ void gpu_embedding(float* input, float* weight, float* output, size_t n){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= n){
    return;
  }
  int x = (int)input[0];
  output[tidx] = weight[x * n + tidx];
}

void embedding(Tensor *input, Tensor *weight, Tensor *output) {
  size_t n = weight->shape[1];
  dim3 gridDim((n + 1024 - 1) / 1024);
  dim3 blockDim(1024);
  gpu_embedding<<<gridDim, blockDim>>>(input->buf, weight->buf, output->buf, n);
}

/*
 * Elementwise addition
 * input1: [*]
 * input2: [*] (same shape as input1)
 * output: [*] (same shape as input1)
 */

__global__ void gpu_elemwise_add(float* input1, float* input2, float* output, size_t sn){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= sn){
    return;
  }
  output[tidx] = input1[tidx] + input2[tidx];
}

void elemwise_add(Tensor *input1, Tensor *input2, Tensor *output) {
  size_t sn = input1->num_elem();
  dim3 gridDim((sn + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_elemwise_add<<<gridDim, blockDim>>>(input1->buf, input2->buf, output->buf, sn);
}

__global__ void gpu_elemwise_add3(float* input1, float* input2, float* input3, float* input4, float* output, size_t sn){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= sn){
    return;
  }
  output[tidx] = input1[tidx];
  output[tidx] += input2[tidx];
  output[tidx] += input3[tidx];
  output[tidx] += input4[tidx];
}

void elemwise_add3(Tensor *input1, Tensor *input2, Tensor *input3, Tensor *input4,Tensor *output) {
  size_t sn = input1->num_elem();
  dim3 gridDim((sn + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_elemwise_add3<<<gridDim, blockDim>>>(input1->buf, input2->buf, input3->buf, input4->buf, output->buf, sn);
}


/*
 * Elementwise (1-x)
 * input: [*]
 * output: [*] (same shape as input)
 */

__global__ void gpu_elemwise_oneminus(float *input, float *output, size_t n){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= n){
    return;
  }
  float x = input[tidx];
  output[tidx] = 1.0 - x;
}

void elemwise_oneminus(Tensor *input, Tensor *output) {
  size_t n = input->num_elem();
  dim3 gridDim((n + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_elemwise_oneminus<<<gridDim, blockDim>>>(input->buf, output->buf, n);
}

/*
 * Elementwise multiplication
 * input1: [*]
 * input2: [*] (same shape as input1)
 * output: [*] (same shape as input1)
 */

__global__ void gpu_elemwise_mul(float *input1, float *input2, float *output, size_t sn){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= sn){
    return;
  }
  output[tidx] = input1[tidx] * input2[tidx];
}

void elemwise_mul(Tensor *input1, Tensor *input2, Tensor *output) {
  size_t sn = input1->num_elem();
  dim3 gridDim((sn + 1024 - 1) / 1024);
  dim3 blockDim(1024);
  gpu_elemwise_mul<<<gridDim, blockDim>>>(input1->buf, input2->buf, output->buf, sn);
}

__global__ void gpu_elemwise_mulNadd(float *input1, float *input2, float *input3, float *output, size_t sn){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= sn){
    return;
  }
  output[tidx] = input1[tidx] * input2[tidx];
  output[tidx] += input3[tidx];
}

void elemwise_mulNadd(Tensor *input1, Tensor *input2, Tensor *input3, Tensor *output) {
  size_t sn = input1->num_elem();
  dim3 gridDim((sn + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_elemwise_mulNadd<<<gridDim, blockDim>>>(input1->buf, input2->buf, input3->buf, output->buf, sn);
}


/*
 * Elementwise tanh(x)
 * input: [*]
 * output: [*] (same shape as input)
 */

__global__ void gpu_elemwise_tanh(float *input, float *output, size_t n){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= n){
    return;
  }
  float x = input[tidx];
  output[tidx] = tanhf(x);
}

void elemwise_tanh(Tensor *input, Tensor *output) {
  size_t n = input->num_elem();
  dim3 gridDim((n + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_elemwise_tanh<<<gridDim, blockDim>>>(input->buf, output->buf, n);
}

/*
 * Elementwise Sigmoid 1 / (1 + exp(-x))
 * input: [*]
 * output: [*] (same shape as input)
 */
__global__ void gpu_elemwise_sigmoid(float *input, float *output, size_t n) {
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= n){
    return;
  }
  float x = input[tidx];
  output[tidx] = 1.0 / (1.0 + expf(-x));
}
void elemwise_sigmoid(Tensor *input, Tensor *output) {
  size_t n = input->num_elem();
  dim3 gridDim((n + 1024 - 1) / 1024);
  dim3 blockDim(1024);
  gpu_elemwise_sigmoid<<<gridDim, blockDim>>>(input->buf, output->buf, n);
}

/*
 * SGEMV
 * input1: [N x K]
 * input2: [K]
 * output: [N]
 */
__global__ void gpu_matvec(float *gpu_input1, float *gpu_input2, float *gpu_output, size_t N_, size_t K_) {
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= N_){
    return;
  }
  float c = 0.0;
  #pragma unroll(64)
  for (size_t j = 0; j < K_; j++) {
    c += gpu_input1[tidx * K_ + j] * gpu_input2[j];
  }
  gpu_output[tidx] = c;
}

void matvec(Tensor *input1, Tensor *input2, Tensor *output) {
  size_t N_ = input1->shape[0];
  size_t K_ = input1->shape[1];
  dim3 gridDim((N_ + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_matvec<<<gridDim, blockDim>>>(input1->buf, input2->buf, output->buf, N_, K_);
}

__global__ void gpu_matvecNadd(float *gpu_input1, float *gpu_input2, float *gpu_input3, float *gpu_output, size_t N_, size_t K_) {
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= N_){
    return;
  }
  float c = 0.0;
  for (size_t j = 0; j < K_; j++) {
    c += gpu_input1[tidx * K_ + j] * gpu_input2[j];
  }
  gpu_output[tidx] = c + gpu_input3[tidx];
}

void matvecNadd(Tensor *input1, Tensor *input2, Tensor *input3, Tensor *output) {
  size_t N_ = input1->shape[0];
  size_t K_ = input1->shape[1];
  dim3 gridDim((N_ + 64 - 1) / 64);
  dim3 blockDim(64);
  gpu_matvecNadd<<<gridDim, blockDim>>>(input1->buf, input2->buf, input3->buf, output->buf, N_, K_);
}

/*
 * SGEMM
 * input1: [M x K]
 * input2: [K x N]
 * output: [M x N]
 */
void matmul(Tensor *input1, Tensor *input2, Tensor *output) {
  size_t M_ = input1->shape[0];
  size_t K_ = input1->shape[1];
  size_t N_ = input2->shape[1];
  for (size_t i = 0; i < M_; i++) {
    for (size_t j = 0; j < N_; j++) {
      float c = 0.0;
      for (size_t k = 0; k < K_; k++) {
        c += input1->buf[i * K_ + k] * input2->buf[k * N_ + j];
      }
      output->buf[i * N_ + j] = c;
    }
  }
}

/*
 * Softmax
 * Normalize the input elements according to its exp value.
 * The result can be interpreted as a probability distribution.
 * input: [*]
 * output: [*], (same shape as input)
 */

__global__ void gpu_expf(float *input, float *exArr, size_t n) {
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;  
  if(tidx >= n){
    return;
  }
  float x = input[tidx];
  exArr[tidx] = expf(x);
}

__global__ void gpu_divide(float *input, float *output, float *exps, float divider, size_t n){
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= n){
    return;
  }
  output[tidx] = exps[tidx] / divider;
}

__global__ void sum_kernel(float *input, float *output, int N){
    extern __shared__ float L[];
    unsigned int tid = threadIdx.x;
    unsigned int offset = blockIdx.x * blockDim.x * 2;
    unsigned int stride = blockDim.x;

    L[tid] = 0;
    if(tid + offset < N){
        L[tid] += input[tid + offset];
    }
    if(tid + stride + offset < N){
        L[tid] += input[tid + stride + offset];
    }
    __syncthreads();

    for(stride = blockDim.x / 2; stride > 0; stride /= 2){
        if(tid < stride){
            L[tid] += L[tid + stride];
        }
        __syncthreads();
    }
    if(tid == 0){
        output[blockIdx.x] = L[0];
    }
}

float sum_gpu(size_t num_elements, float* input_gpu, float* sm_output_gpu){
    size_t output_elements = (num_elements + 2048 - 1) / 2048;

    dim3 gridDim(output_elements);
    dim3 blockDim(64);
    sum_kernel<<<gridDim, blockDim, 64 * sizeof(float), 0>>>(input_gpu, sm_output_gpu, num_elements);

    float sum = 0.0;
    float* output_cpu = (float*)malloc(sizeof(float) * output_elements);
    cudaMemcpy(output_cpu, sm_output_gpu, output_elements * sizeof(float), cudaMemcpyDeviceToHost);
    for(size_t i=0; i<output_elements; i++){
        sum += output_cpu[i];
    }
    return sum;
}


void softmax(Tensor *input, Tensor *output) {
  // no thread for softmax
  size_t n = input->num_elem();

  // total n
  dim3 gridDim((n + 512 - 1) / 512);
  dim3 blockDim(512);

  gpu_expf<<<gridDim, blockDim>>>(input->buf, exps, n);
  // barrier?

  float sum = sum_gpu(n, exps, sm_output_gpu);

  // total n
  gpu_divide<<<gridDim, blockDim>>>(input->buf, output->buf, exps, sum, n);
}

/*
 * Sample a random index according to the given probability distribution
 * This function is called at most N*MAX_LEN times. Each call uses a
 * random float in [0,1] to sample an index from the given distribution.
 * input: [NUM_CHAR], probability distribution of the characters
 * rng_seq: [N*MAX_LEN],
 */

// sum input[i] for 0 <= i <n
// if sum > r 
int random_select(float *input, float *rng_seq, int rng_offset, size_t n) {
  float r = rng_seq[rng_offset];
  float psum = 0.0;
  for (size_t i = 0; i < n; i++) {
    psum += input[i];
    if (psum > r) {
      return i;
    }
  }
  return n - 1;
}

/*
 * Initialize the model.
 * Do input-independent job here.
 */
void namegen_initialize(int N, char *parameter_fname) {

  /* Only the root process reads the parameter */
 
  size_t parameter_binary_size = 0;
  float *parameter =
      (float *)read_binary(parameter_fname, &parameter_binary_size);

  /* Network parameters */
  character_embedding =
      new Tensor({NUM_CHAR, EMBEDDING_DIM}, parameter + OFFSET0);

  W_ir0 = new Tensor({HIDDEN_DIM, EMBEDDING_DIM}, parameter + OFFSET1);
  W_iz0 = new Tensor({HIDDEN_DIM, EMBEDDING_DIM}, parameter + OFFSET2);
  W_in0 = new Tensor({HIDDEN_DIM, EMBEDDING_DIM}, parameter + OFFSET3);
  W_ir1 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET4);
  W_iz1 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET5);
  W_in1 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET6);

  W_hr0 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET7);
  W_hz0 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET8);
  W_hn0 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET9);
  W_hr1 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET10);
  W_hz1 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET11);
  W_hn1 = new Tensor({HIDDEN_DIM, HIDDEN_DIM}, parameter + OFFSET12);

  b_ir0 = new Tensor({HIDDEN_DIM}, parameter + OFFSET13);
  b_iz0 = new Tensor({HIDDEN_DIM}, parameter + OFFSET14);
  b_in0 = new Tensor({HIDDEN_DIM}, parameter + OFFSET15);
  b_ir1 = new Tensor({HIDDEN_DIM}, parameter + OFFSET16);
  b_iz1 = new Tensor({HIDDEN_DIM}, parameter + OFFSET17);
  b_in1 = new Tensor({HIDDEN_DIM}, parameter + OFFSET18);

  b_hr0 = new Tensor({HIDDEN_DIM}, parameter + OFFSET19);
  b_hz0 = new Tensor({HIDDEN_DIM}, parameter + OFFSET20);
  b_hn0 = new Tensor({HIDDEN_DIM}, parameter + OFFSET21);
  b_hr1 = new Tensor({HIDDEN_DIM}, parameter + OFFSET22);
  b_hz1 = new Tensor({HIDDEN_DIM}, parameter + OFFSET23);
  b_hn1 = new Tensor({HIDDEN_DIM}, parameter + OFFSET24);

  W_fc = new Tensor({NUM_CHAR, HIDDEN_DIM}, parameter + OFFSET25);
  b_fc = new Tensor({NUM_CHAR}, parameter + OFFSET26);

  /* input, activations, output, etc. */
  input = new Tensor({1});
  emb_out = new Tensor({EMBEDDING_DIM});

  hidden0 = new Tensor({HIDDEN_DIM});
  hidden1 = new Tensor({HIDDEN_DIM});

  r0 = new Tensor({HIDDEN_DIM});
  r1 = new Tensor({HIDDEN_DIM});
  z0 = new Tensor({HIDDEN_DIM});
  z1 = new Tensor({HIDDEN_DIM});
  n0 = new Tensor({HIDDEN_DIM});
  n1 = new Tensor({HIDDEN_DIM});
  f = new Tensor({NUM_CHAR});

  rtmp00 = new Tensor({HIDDEN_DIM});
  rtmp01 = new Tensor({HIDDEN_DIM});
  rtmp02 = new Tensor({HIDDEN_DIM});
  rtmp03 = new Tensor({HIDDEN_DIM});
  rtmp04 = new Tensor({HIDDEN_DIM});
  rtmp10 = new Tensor({HIDDEN_DIM});
  rtmp11 = new Tensor({HIDDEN_DIM});
  rtmp12 = new Tensor({HIDDEN_DIM});
  rtmp13 = new Tensor({HIDDEN_DIM});
  rtmp14 = new Tensor({HIDDEN_DIM});

  ztmp00 = new Tensor({HIDDEN_DIM});
  ztmp01 = new Tensor({HIDDEN_DIM});
  ztmp02 = new Tensor({HIDDEN_DIM});
  ztmp03 = new Tensor({HIDDEN_DIM});
  ztmp04 = new Tensor({HIDDEN_DIM});
  ztmp10 = new Tensor({HIDDEN_DIM});
  ztmp11 = new Tensor({HIDDEN_DIM});
  ztmp12 = new Tensor({HIDDEN_DIM});
  ztmp13 = new Tensor({HIDDEN_DIM});
  ztmp14 = new Tensor({HIDDEN_DIM});

  ntmp00 = new Tensor({HIDDEN_DIM});
  ntmp01 = new Tensor({HIDDEN_DIM});
  ntmp02 = new Tensor({HIDDEN_DIM});
  ntmp03 = new Tensor({HIDDEN_DIM});
  ntmp04 = new Tensor({HIDDEN_DIM});
  ntmp05 = new Tensor({HIDDEN_DIM});
  ntmp10 = new Tensor({HIDDEN_DIM});
  ntmp11 = new Tensor({HIDDEN_DIM});
  ntmp12 = new Tensor({HIDDEN_DIM});
  ntmp13 = new Tensor({HIDDEN_DIM});
  ntmp14 = new Tensor({HIDDEN_DIM});
  ntmp15 = new Tensor({HIDDEN_DIM});

  htmp00 = new Tensor({HIDDEN_DIM});
  htmp01 = new Tensor({HIDDEN_DIM});
  htmp02 = new Tensor({HIDDEN_DIM});
  htmp10 = new Tensor({HIDDEN_DIM});
  htmp11 = new Tensor({HIDDEN_DIM});
  htmp12 = new Tensor({HIDDEN_DIM});

//  rfloats = new Tensor({N * MAX_LEN});
  rfloats = (float *)malloc(sizeof(float) * N * MAX_LEN);
  ftmp0 = new Tensor({NUM_CHAR});
  char_prob = new Tensor({NUM_CHAR});

  CHECK_CUDA(cudaMalloc(&exps, sizeof(float) * NUM_CHAR));
  CHECK_CUDA(cudaMalloc(&sm_output_gpu, ((NUM_CHAR + 2048 - 1) / 2048) * sizeof(float)));

}

/*
 * Generate names.
 * Any input-dependent computation/communication must be done here.
 * N: # of names to generate
 * random_floats: N*MAX_LEN sequence of random floats in [0,1].
 * output: 2D-array of size N x (MAX_LEN+1), allocaetd at main.cpp
 */

__global__ void gpu_set_val(float *buf, int N, float val) {
  int tidx = blockIdx.x * blockDim.x + threadIdx.x;
  if(tidx >= N){
    return;
  }
  buf[tidx] = val;
}

void namegen(int N, float *random_floats, char *output) {

  memcpy(rfloats, random_floats, N * MAX_LEN * sizeof(float));
  memset(output, 0, N * (MAX_LEN + 1) * sizeof(char));

  /* Generate N names */
  for (int n = 0; n < N; n++) {
    /* Initialize input and hidden vector. */
    /* One hidden vector for each GRU layer */
    gpu_set_val<<<1, 1>>>(input->buf, 1, SOS);

    dim3 gridDim1((hidden0->num_elem() + 64 - 1) / 64);
    dim3 blockDim1(64);
    gpu_set_val<<<gridDim1, blockDim1>>>(hidden0->buf, hidden0->num_elem(), 0);
    dim3 gridDim2((hidden1->num_elem() + 64 - 1) / 64);
    dim3 blockDim2(64);
    gpu_set_val<<<gridDim2, blockDim2>>>(hidden1->buf, hidden1->num_elem(), 0);

    for (int l = 0; l < MAX_LEN; l++) {
      /* Embedding */
      embedding(input, character_embedding, emb_out);

      /* First layer r */
      matvec(W_ir0, emb_out, rtmp00);
      matvec(W_hr0, hidden0, rtmp01);
      elemwise_add3(rtmp00, b_ir0, rtmp01, b_hr0, rtmp04);
      elemwise_sigmoid(rtmp04, r0);

      /* First layer z */
      matvec(W_iz0, emb_out, ztmp00);
      matvec(W_hz0, hidden0, ztmp01);
      elemwise_add3(ztmp00, b_iz0, ztmp01, b_hz0, ztmp04);
      elemwise_sigmoid(ztmp04, z0);

      /* First layer n */
      matvecNadd(W_in0, emb_out, b_in0, ntmp01);
      matvecNadd(W_hn0, hidden0, b_hn0, ntmp03);
      elemwise_mulNadd(r0, ntmp03, ntmp01, ntmp05);
      elemwise_tanh(ntmp05, n0);

      /* First layer h (hidden) */
      elemwise_oneminus(z0, htmp00);
      elemwise_mul(htmp00, n0, htmp01);
      elemwise_mulNadd(z0, hidden0, htmp01, hidden0);

      /* Second layer r */
      matvec(W_ir1, hidden0, rtmp10);
      matvec(W_hr1, hidden1, rtmp11);
      elemwise_add3(rtmp10, b_ir1, rtmp11, b_hr1, rtmp14);
      elemwise_sigmoid(rtmp14, r1);

      /* Second layer z */
      matvec(W_iz1, hidden0, ztmp10);
      matvec(W_hz1, hidden1, ztmp11);
      elemwise_add3(ztmp10, b_iz1, ztmp11, b_hz1, ztmp14);
      elemwise_sigmoid(ztmp14, z1);

      /* Second layer n */
      matvecNadd(W_in1, hidden0, b_in1, ntmp11);
      matvecNadd(W_hn1, hidden1, b_hn1, ntmp13);
      elemwise_mulNadd(r1, ntmp13, ntmp11, ntmp15);
      elemwise_tanh(ntmp15, n1);

      /* Second layer h (hidden) */
      elemwise_oneminus(z1, htmp10);
      elemwise_mul(htmp10, n1, htmp11);
      elemwise_mulNadd(z1, hidden1, htmp11, hidden1);

      /* Fully connected layer */
      matvecNadd(W_fc, hidden1, b_fc, f);

      /* Softmax */
      softmax(f, char_prob);
      
      /* Random select */
      float* char_prob_cpu;
      size_t lenCharProb = char_prob->num_elem();
      CHECK_CUDA(cudaMallocHost(&char_prob_cpu, sizeof(float) * lenCharProb));
      CHECK_CUDA(cudaMemcpy(char_prob_cpu, char_prob->buf, sizeof(float) * lenCharProb, cudaMemcpyDeviceToHost));
      int selected_char = random_select(char_prob_cpu, rfloats, n * MAX_LEN + l, lenCharProb);
      
      gpu_set_val<<<1, 1>>>(input->buf, 1, selected_char);
      output[n * (MAX_LEN + 1) + l] = selected_char;

      if (selected_char == EOS)
        break;
    }
  }
}

/*
 * Finalize the model.
 * Although it is not neccessary, we recommend to deallocate and destruct
 * everything you made in namegen_initalize() and namegen().
 */
void namegen_finalize() {
  delete character_embedding;
  delete W_ir0;
  delete W_iz0;
  delete W_in0;
  delete W_ir1;
  delete W_iz1;
  delete W_in1;
  delete W_hr0;
  delete W_hz0;
  delete W_hn0;
  delete W_hr1;
  delete W_hz1;
  delete W_hn1;
  delete b_ir0;
  delete b_iz0;
  delete b_in0;
  delete b_ir1;
  delete b_iz1;
  delete b_in1;
  delete b_hr0;
  delete b_hz0;
  delete b_hn0;
  delete b_hr1;
  delete b_hz1;
  delete b_hn1;
  delete W_fc;
  delete b_fc;
  delete rfloats;

  delete input;
  delete emb_out;
  delete hidden0;
  delete hidden1;
  delete r0;
  delete r1;
  delete z0;
  delete z1;
  delete n0;
  delete n1;
  delete f;
  delete char_prob;
  delete rtmp00;
  delete rtmp01;
  delete rtmp02;
  delete rtmp03;
  delete rtmp04;
  delete rtmp10;
  delete rtmp11;
  delete rtmp12;
  delete rtmp13;
  delete rtmp14;
  delete ztmp00;
  delete ztmp01;
  delete ztmp02;
  delete ztmp03;
  delete ztmp04;
  delete ztmp10;
  delete ztmp11;
  delete ztmp12;
  delete ztmp13;
  delete ztmp14;
  delete ntmp00;
  delete ntmp01;
  delete ntmp02;
  delete ntmp03;
  delete ntmp04;
  delete ntmp05;
  delete ntmp10;
  delete ntmp11;
  delete ntmp12;
  delete ntmp13;
  delete ntmp14;
  delete ntmp15;
  delete htmp00;
  delete htmp01;
  delete htmp02;
  delete htmp10;
  delete htmp11;
  delete htmp12;
  delete ftmp0;
}
