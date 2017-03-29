"""
    AbstractEvalMetric

The base class for all evaluation metrics. The sub-types should implement the following
interfaces:

* [`update!`](@ref)
* [`reset!`](@ref)
* [`get`](@ref)
"""
abstract AbstractEvalMetric

"""
    update!(metric, labels, preds)

Update and accumulate metrics.

# Arguments:
* `metric::AbstractEvalMetric`: the metric object.
* `labels::Vector{NDArray}`: the labels from the data provider.
* `preds::Vector{NDArray}`: the outputs (predictions) of the network.
"""
function update!{T <: AbstractEvalMetric}(metric :: T, labels :: Vector{NDArray}, preds :: Vector{NDArray})
  if length(labels) != length(preds)
    Base.warn_once(
      "The number of labels ($(length(labels))) does not correspond to the\
      number of outputs ($(length(preds))). The calculated metric might not be accuracte.")
  end
  for (label, pred) in zip(labels, preds)
     @nd_as_jl ro=(label, pred) begin
       # This is a dynamic dispatch since the conversion from NDArray to
       # Array is not type-stable. We could use a trait to decide if we should
       # convert the NDArray here so that the called function will be type-stable
       # or if we should forward the NDArray.
      _update_single_output(metric, label, pred)
    end
  end
end

"""
    reset!(metric)

Reset the accumulation counter.
"""
function reset!(metric :: AbstractEvalMetric)
  throw(MethodError(reset!, (typeof(metric),)))
end


import Base: get
"""
    get(metric)

Get the accumulated metrics.

Returns `Vector{Tuple{Base.Symbol, Real}}`, a list of name-value pairs.
For example, `[(:accuracy, 0.9)]`.
"""
function get(metric :: AbstractEvalMetric)
  throw(MethodError(get, (typeof(metric),)))
end

"""
    NullMetric()

A metric that calculates nothing. Can be used to ignore an output during training.
"""
type NullMetric <: mx.AbstractEvalMetric
end

function update!(metric :: NullMetric, labels :: Vector{NDArray}, preds :: Vector{NDArray})
  return nothing
end

function reset!(metric :: NullMetric)
  return nothing
end

function get(metric :: NullMetric)
  return Tuple{Symbol, Float64}[]
end

"""
    MultiMetric(metrics::Vector{AbstractEvalMetric})

Combine multiple metrics in one and get a result for all of them.

# Usage
To calculate both mean-squared error [`Accuracy`](@ref) and log-loss [`ACE`](@ref):
```julia
  mx.fit(..., eval_metric = mx.MultiMetric([mx.Accuracy(), mx.ACE()]))
```
"""
type MultiMetric <: mx.AbstractEvalMetric
    metrics :: Vector{mx.AbstractEvalMetric}
end

function update!(metric :: MultiMetric, labels :: Vector{NDArray}, preds :: Vector{NDArray})
    for m in metric.metrics
        update!(m, labels, preds)
    end
    return nothing
end

function reset!(metric :: MultiMetric)
    map(reset!, metric.metrics)
    return nothing
end

function get(metric :: MultiMetric)
    mapreduce(get, append!, metric.metrics)
end

"""
    SeqMetric(metrics::Vector{AbstractEvalMetric})

Apply a different metric to each output. This is especially useful for `mx.Group`.

# Usage
Calculate accuracy [`Accuracy`](@ref) for the first output
and log-loss [`ACE`](@ref) for the second output:
```julia
  mx.fit(..., eval_metric = mx.SeqMetric([mx.Accuracy(), mx.ACE()]))
```
"""
type SeqMetric <: mx.AbstractEvalMetric
    metrics :: Vector{mx.AbstractEvalMetric}
end

function update!(metric :: SeqMetric, labels :: Vector{NDArray}, preds :: Vector{NDArray})
    @assert length(metric.metrics) == length(labels)
    @assert length(metric.metrics) == length(preds)
    for (m, l, p) in zip(metric.metrics, labels, preds)
        update!(m, [l], [p])
    end
    return nothing
end

function reset!(metric :: SeqMetric)
    map(reset!, metric.metrics)
    return nothing
end

function get(metric :: SeqMetric)
    mapreduce(get, append!, metric.metrics)
end

"""
    Accuracy

Multiclass classification accuracy.

Calculates the mean accuracy per sample for softmax in one dimension.
For a multi-dimensional softmax the mean accuracy over all dimensions is calculated.
"""
type Accuracy <: AbstractEvalMetric
  acc_sum  :: Float64
  n_sample :: Int

  Accuracy() = new(0.0, 0)
end

function _update_single_output(metric :: Accuracy, label :: Array, pred :: Array)
  # Samples are stored in the last dimension
  @assert size(label, ndims(label)) == size(pred, ndims(pred))

  if ndims(pred) == 4 # Multidimensional case
    # Reshape label to be of the same shape as pred.
    # Except for the third dimension where the predictions are stored.
    labels = reshape(label, size(pred, 1, 2)..., 1, size(pred, 4))

    for sample in 1:size(labels, 4)
      for j in 1:size(labels, 2)
        for i in 1:size(labels, 1)
          label = labels[i, j, 1, sample]
          klasses = view(pred, i, j, :, sample)
          klass = indmax(klasses) - 1 # Classes start at 0...k-1

          metric.acc_sum += klass == label
          metric.n_sample += 1
        end
      end
    end
  elseif ndims(pred) == 2 # 1-dimensional case
    for sample in 1:size(label, 1)
      klass = indmax(view(pred, :, sample)) - 1
      metric.acc_sum += klass == label[sample]
      metric.n_sample += 1
    end
  else
    error("Can't handle prediction with dimensions $(ndims(pred)).")
  end
end

function get(metric :: Accuracy)
  return [(:accuracy, metric.acc_sum / metric.n_sample)]
end

function reset!(metric :: Accuracy)
  metric.acc_sum  = 0.0
  metric.n_sample = 0
end

"""
    MSE

Mean Squared Error.

Calculates the mean squared error regression loss.
Requires that label and prediction have the same shape.
"""

type MSE <: AbstractEvalMetric
  mse_sum  :: Float64
  n_sample :: Int

  MSE() = new(0.0, 0)
end

function _update_single_output{T}(metric :: MSE, label :: Array{T}, pred :: Array{T})
  @assert size(label) == size(pred)
  N = length(label)

  # MSE-kernel important to be allocation free
  work = function (low, high, label, pred)
    result = 0.0
    @simd for i in low:high
      @inbounds result += (label[i] - pred[i])^2
    end
    return result
  end

  metric.n_sample += N
  metric.mse_sum += __threaded_reduction(work, N, label, pred)
  return nothing
end

function get(metric :: MSE)
  return [(:MSE, metric.mse_sum / metric.n_sample)]
end

function reset!(metric :: MSE)
  metric.mse_sum  = 0.0
  metric.n_sample = 0
end

doc"""
    NMSE

Normalized Mean Squared Error

```math
\sum_i (\frac{label_i - pred_i}{label_i})^2
```

Note that there are various ways to do the *normalization*.
It depends on your own context. Please judge the problem setting you have
first. If the current implementation do not suitable for you,
feel free to file it on GitHub.

Let me show you a use case of this kind of normalization:

Bob is training a network for option pricing. The option pricing problem is
a regression problem (pirce predicting). There are lots of option contracts
on same target stock but different strike price.
For example, there is a stock `S`; it's market price is 1000.
And, there are two call option contracts with different strike price.
Assume Bob obtains the outcome as following table:

```
+--------+----------------+----------------+--------------+
|        | Strike Price   | Market Price   | Pred Price   |
+--------+----------------+----------------+--------------+
| Op 1   | 1500           |  100           | 80           |
+--------+----------------+----------------+--------------+
| Op 2   | 500            |  10            | 8            |
+--------+----------------+----------------+--------------+
```

Now, obviously, Bob will calculate the normalized MSE as:

```math
    (\frac{100 - 80}{100})^2
    \text{ vs }
    (\frac{10 - 8}{10}) ^2
```

Both of the pred prices got the same degree of error.

For more discussion about normalized MSE, please see
[#211](https://github.com/dmlc/MXNet.jl/pull/211) also.

"""
type NMSE <: AbstractEvalMetric
  nmse_sum  :: Float64
  n_sample :: Int

  NMSE() = new(0.0, 0)
end

function _update_single_output(metric :: NMSE, label :: Array, pred :: Array)
  n_sample = size(pred)[end]
  metric.n_sample += n_sample

  for i = 1:n_sample
    if label[i] == 0.0f0  # in case of batch padding
        continue
    end

    metric.nmse_sum += ((label[i] - pred[i]) / label[i])^2
  end
end

function get(metric :: NMSE)
  return [(:NMSE, metric.nmse_sum / metric.n_sample)]
end

function reset!(metric :: NMSE)
  metric.nmse_sum = 0.0
  metric.n_sample = 0
end

"""
    ACE

Calculates the averaged cross-entropy (logloss) for classification.

# Arguments:
* `eps::Float64`: Prevents returning `Inf` if `p = 0`.
"""
type ACE <: AbstractEvalMetric
  ace_sum  :: Float64
  n_sample :: Int
  eps :: Float64

  ACE(eps=1.0e-8) = new(0.0, 0, eps)
end

function get(metric :: ACE)
  return [(:ACE, - metric.ace_sum / metric.n_sample)]
end

function reset!(metric :: ACE)
  metric.ace_sum = 0.0
  metric.n_sample = 0
end

function _update_single_output{T}(metric :: ACE, label :: Array{T}, pred :: Array{T})
  eps = convert(T, metric.eps)
  # Samples are stored in the last dimension
  @assert size(label, ndims(label)) == size(pred, ndims(pred))

  # ACE kernel for 4d
  work4d = function (low, high, sample, label, pred)
    result = 0.0
    for idx in low:high
      i, j = ind2sub(size(label, 1, 2), idx)
      @inbounds target = Int(labels[i, j, 1, sample]) + 1 # klasses are 0...k-1 => julia indexing
      # Cross-entropy reduces to -(ln(p_1)*0 + ln(p_2)*1) for classification
      # Since we can only target labels right now this is the only thing we can do.
      @inbounds p_k = pred[i, j, target, sample]
      result += log(p_k + eps)
    end
    return result
  end

  if size(label) == size(pred) # simply calculate the cross entropy of the probabilities
    for (q, p) in zip(pred, label)
      # p == true probability
      # q == "unnatural" probability
      metric.ace_sum += p * log(q + eps)
    end
    metric.n_sample += length(pred)
  elseif ndims(pred) == 4
    labels = reshape(label, size(pred, 1, 2)..., 1, size(pred, 4))
    for sample in 1:size(labels, 4)
      N = prod(size(labels, 1, 2))
      metric.ace_sum += __threaded_reduction(work4d, N, sample, labels, pred)
      metric.n_sample += N
    end
  elseif ndims(pred) == 2 # 1-dimensional case
    for sample in 1:size(label, 1)
      target = Int(label[sample]) + 1    # 0-based indexing => 1-based indexing
      p_k = pred[target, sample]
      metric.ace_sum += log(p_k +eps)
      metric.n_sample += 1
    end
  else
    error("Can't handle prediction with dimensions $(ndims(pred)).")
  end
end

"""
    MultiACE

Calculates the averaged cross-entropy per class and overall (see [`ACE`](@ref)).
This can be used to quantify the influence of different classes on the overall loss.
"""
type MultiACE <: AbstractEvalMetric
  aces  :: Vector{Float64}
  counts :: Vector{Int}
  eps :: Float64

  MultiACE(nclasses, eps=1.0e-8) = new(Base.zeros(nclasses), Base.zeros(Int, nclasses), eps)
end

function get(metric :: MultiACE)
  aces = [(Symbol("ACE_$(i-0)"), - metric.aces[i] / metric.counts[i]) for i in 1:length(metric.aces)]
  push!(aces, (:ACE, - Base.sum(metric.aces) / Base.sum(metric.counts)))
  return aces
end

function reset!(metric :: MultiACE)
  metric.aces = Base.zero(metric.aces)
  metric.counts = Base.zero(metric.counts)
end

function _update_single_output{T}(metric :: MultiACE, label :: Array{T}, pred :: Array{T})
  eps = convert(T, metric.eps)
  # Samples are stored in the last dimension
  @assert size(label, ndims(label)) == size(pred, ndims(pred))
  @assert size(metric.aces) == size(metric.counts)
  if size(label) == size(pred) # simply calculate the cross entropy of the probabilities
    for k in 1:length(metric.aces)
      kpred  = view(pred,  ntuple(d->:, ndims(pred)  - 2)..., k, :)
      klabel = view(label, ntuple(d->:, ndims(label) - 2)..., k, :)
      for (q, p) in zip(kpred, klabel)
        # p == true probability
        # q == "unnatural" probability
        metric.aces[k] += p * log(q + eps)
        metric.counts[k] += 1
      end
    end
  elseif ndims(pred) == 4
    labels = reshape(label, size(pred, 1, 2)..., 1, size(pred, 4))
    for sample in 1:size(labels, 4)
      for j in 1:size(labels, 2)
        for i in 1:size(labels, 1)
          # Cross-entropy reduces to -(ln(p_1)*0 + ln(p_2)*1) for classification
          # Since we can only target labels right now this is the only thing we can do.
          target = Int(labels[i, j, 1, sample]) + 1 # klasses are 0...k-1 => julia indexing
          p_k = pred[i, j, target, sample]

          metric.aces[target] += log(p_k + eps)
          metric.counts[target] += 1
        end
      end
    end
  elseif ndims(pred) == 2
    for sample in 1:size(label, 1)
      target = Int(label[sample]) + 1
      p_k = pred[target, sample]
      metric.aces[target] += log(p_k + eps)
      metric.counts[target] += 1
    end
  else
    error("Can't handle prediction with dimensions $(ndims(pred)).")
  end
end

