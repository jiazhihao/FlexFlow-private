/* Copyright 2023 Stanford
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "flexflow/ops/reduce.h"
#include "flexflow/utils/cuda_helper.h"

namespace FlexFlow {
// declare Legion names
using Legion::coord_t;
using Legion::Domain;

ReduceMeta::ReduceMeta(FFHandler handler,
                       Reduce const *rd,
                       Domain const &input_domain)
    : op_type(rd->op_type), OpMeta(handler) {
  checkCUDNN(cudnnCreateReduceTensorDescriptor(&reduceDesc));
  checkCUDNN(cudnnCreateTensorDescriptor(&inputTensor));
  checkCUDNN(cudnnCreateTensorDescriptor(&outputTensor));
  cudnnReduceTensorOp_t reduce_op;
  switch (op_type) {
    case OP_REDUCE_SUM:
      reduce_op = CUDNN_REDUCE_TENSOR_ADD;
      break;
    case OP_REDUCE_MEAN:
      reduce_op = CUDNN_REDUCE_TENSOR_AVG;
      break;
    default:
      assert(false);
  }
  checkCUDNN(cudnnSetReduceTensorDescriptor(reduceDesc,
                                            reduce_op,
                                            CUDNN_DATA_FLOAT,
                                            CUDNN_PROPAGATE_NAN,
                                            CUDNN_REDUCE_TENSOR_NO_INDICES,
                                            CUDNN_32BIT_INDICES));
  checkCUDNN(cudnnSetTensorDescriptorFromDomain(inputTensor, input_domain));
  Domain output_domain = input_domain;
  for (size_t i = 0; i < rd->num_axes; i++) {
    assert(input_domain.dim > rd->axes[i]);
    output_domain.rect_data[rd->axes[i] + output_domain.dim] =
        output_domain.rect_data[rd->axes[i]];
  }
  assert(output_domain.get_volume() % input_domain.get_volume() == 0);
  reduction_size = input_domain.get_volume() / output_domain.get_volume();
  assert(reduction_size > 0);
  checkCUDNN(cudnnSetTensorDescriptorFromDomain(outputTensor, output_domain));
}

ReduceMeta::~ReduceMeta(void) {
  checkCUDNN(cudnnDestroyReduceTensorDescriptor(reduceDesc));
  checkCUDNN(cudnnDestroyTensorDescriptor(inputTensor));
  checkCUDNN(cudnnDestroyTensorDescriptor(outputTensor));
}

void Reduce::forward_kernel(ReduceMeta const *m,
                            float const *input_ptr,
                            float *output_ptr,
                            cudaStream_t stream) {
  checkCUDNN(cudnnSetStream(m->handle.dnn, stream));
  float alpha = 1.0f, beta = 0.0f;
  checkCUDNN(cudnnReduceTensor(m->handle.dnn,
                               m->reduceDesc,
                               nullptr /*indices*/,
                               0 /*indicesSizeInBytes*/,
                               m->handle.workSpace,
                               m->handle.workSpaceSize,
                               &alpha,
                               m->inputTensor,
                               input_ptr,
                               &beta,
                               m->outputTensor,
                               output_ptr));
};

/*static*/
void Reduce::forward_kernel_wrapper(ReduceMeta const *m,
                                    GenericTensorAccessorR const &input,
                                    GenericTensorAccessorW const &output) {
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  Reduce::forward_kernel(
      m, input.get_float_ptr(), output.get_float_ptr(), stream);
}

void Reduce::backward_kernel(ReduceMeta const *m,
                             float const *output_grad_ptr,
                             float *input_grad_ptr,
                             cudaStream_t stream) {
  checkCUDNN(cudnnSetStream(m->handle.dnn, stream));
  float alpha = 1.0, beta = 1.0f;
  switch (m->op_type) {
    case OP_REDUCE_SUM:
      alpha = 1.0f;
      break;
    case OP_REDUCE_MEAN:
      // When the output is the average of multiple input elements
      // we need to scale the gradients by 1.0 / reduction_size
      alpha = 1.0f / m->reduction_size;
      break;
    default:
      assert(false);
  }
  checkCUDNN(cudnnAddTensor(m->handle.dnn,
                            &alpha,
                            m->outputTensor,
                            output_grad_ptr,
                            &beta,
                            m->inputTensor,
                            input_grad_ptr));
}

void Reduce::backward_kernel_wrapper(ReduceMeta const *m,
                                     GenericTensorAccessorR const &output_grad,
                                     GenericTensorAccessorW const &input_grad) {
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  Reduce::backward_kernel(
      m, output_grad.get_float_ptr(), input_grad.get_float_ptr(), stream);
}

}; // namespace FlexFlow
