module DateSelectors

using Base.Iterators
using Dates
using Intervals
using Random
using StatsBase: sample, AbstractWeights

export DateSelector, NoneSelector, PeriodicSelector, RandomSelector, partition

"""
    DateSelector

Determines how to [`partition`](@ref) a date set into disjoint validation and holdout sets.
"""
abstract type DateSelector end

"""
    NoneSelector()

Assign all dates to the validation set, select no holdout dates.
"""
struct NoneSelector <: DateSelector end

"""
    PeriodicSelector(period::Period, stride::Period=Day(1), offset::Period=Day(0))

Assign holdout dates by taking a set of size `stride` once per `period` starting from the
start date + `offset`.

For example, `PeriodicSampler(Week(1), Day(2), Day(1))` will select 2 days per week with an
offset of 1 day resulting in the holdout dates corresponding to the second and third days of
each week from the start date.
"""
struct PeriodicSelector <: DateSelector
    period::Period
    stride::Period
    offset::Period

    function PeriodicSelector(period::Period, stride::Period=Day(1), offset::Period=Day(0))

        period ≥ Day(2) || throw(DomainError(period, "period must be at least 2 Days."))
        stride ≥ Day(1) || throw(DomainError(stride, "stride must be at least 1 Day."))
        offset ≥ Day(0) || throw(DomainError(offset, "offset cannot be negative."))

        if any(isa.([period, stride, offset], Ref(Hour)))
            throw(DomainError("period, stride, and offset cannot be expressed in Hours."))
        end

        if Day(stride) + Day(offset) > Day(period)
            throw(ArgumentError(
                "Cannot take a $stride stride with offset $offset within a $period period."
            ))
        end

        return new(period, stride, offset)
    end
end

"""
    RandomSelector(
        holdout_blocks::Integer,
        block_size::Integer,
        seed::Integer,
        block_weights::Union{AbstractWeights, Nothing}=nothing,
    )

Determine holdout set by randomly subsampling `holdout_blocks` contiguous blocks of size `block_size` of holdout dates without
replacement using the `GLOBAL_RNG` seeded with `seed`.

The holdout dates will be sampled proportionally to the `block_weights` when they are provided.
"""
struct RandomSelector <: DateSelector
    holdout_blocks::Integer
    block_size::Integer
    seed::Integer
    block_weights::Union{AbstractWeights, Nothing}

    function RandomSelector(holdout_blocks, block_size, seed, block_weights::Union{AbstractWeights, Nothing}=nothing)
        return new(holdout_blocks, block_size, seed, block_weights)
    end
end

function RandomSelector(holdout_blocks, seed, block_weights::Union{AbstractWeights, Nothing}=nothing)
    return RandomSelector(holdout_blocks, 1, seed, block_weights)
end

"""
    partition(dates::AbstractInterval{Date}, s::DateSelector)
    partition(dates::StepRange{Date, Day}, selector::DateSelector)

Partition the set of `dates` into disjoint `validation` and `holdout` sets according to the
`selector` and return a `NamedTuple({:validation, :holdout})` of iterators.
"""
function Iterators.partition(dates::AbstractInterval{Date}, s::DateSelector)
    _dates = _interval2daterange(dates)
    return partition(_dates, s)
end

Iterators.partition(dates::StepRange{Date, Day}, ::NoneSelector) = _getdatesets(dates, Date[])

function Iterators.partition(dates::StepRange{Date, Day}, s::PeriodicSelector)
    sd, ed = extrema(dates)

    holdout_dates = Date[]
    curr = sd
    curr += s.offset
    while curr + s.stride <= ed
        #TODO: in future we want to remove the assumption of a 1 day interval
        stop = curr + s.stride - step(dates)
        push!(holdout_dates, curr:step(dates):stop...)
        curr += s.period
    end

    push!(holdout_dates, curr:step(dates):ed...)

    return _getdatesets(dates, holdout_dates)
end

function Iterators.partition(dates::StepRange{Date, Day}, s::RandomSelector)
    # Split the total days into contiguous blocks
    date_blocks = Iterators.partition(dates, s.block_size)

    if s.holdout_blocks > length(date_blocks)
        throw(DomainError(
            s.holdout_blocks,
            "Number of holdout blocks $(s.holdout_blocks) exceeds total number of date-blocks $(length(date_blocks))."
        ))
    end

    holdout_days = _subsample(
        Random.seed!(s.seed),
        collect(date_blocks), # _subsample doesn't work on iterators
        s.block_weights,
        s.holdout_blocks;
        replace=false
    )

    # Recombine dates to ensure return-type matches other DateSelectors
    return _getdatesets(dates, vcat(holdout_days...))
end

_subsample(rng, dates, ::Nothing, n; kwargs...) = sample(rng, dates, n; kwargs...)
_subsample(rng, dates, weights, n; kwargs...) = sample(rng, dates, weights, n; kwargs...)

"""
    _getdatesets(st, ed, dates) -> NamedTuple{(:validation, :holdout)}

Construct the NamedTuple of iterators for the validation and holdout date sets.
"""
function _getdatesets(all_dates, holdout_dates)
    return (
        validation=(vd for vd in sort(setdiff(all_dates, holdout_dates))),
        holdout=(hd for hd in sort(holdout_dates))
    )
end

_getdatesets(all_dates, date::Date) = _getdatesets(all_dates, [date])

"""
    _interval2daterange(dates::AbstractInterval{Day}) -> StepRange{Date, Day}

Helper function to turn an AbstrctInterval into a StepRange taking the inclusivity into
account.
"""
function _interval2daterange(dates::AbstractInterval{Date})
    fd = first(inclusivity(dates)) ? first(dates) : first(dates) + Day(1)
    ld = last(inclusivity(dates)) ? last(dates) : last(dates) - Day(1)
    return fd:Day(1):ld
end

include("deprecated.jl")

end
