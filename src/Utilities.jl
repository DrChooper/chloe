import CodecZlib: GzipDecompressorStream, GzipCompressorStream
import Base

import Printf: @sprintf

const REENTRANT_LOCK = ReentrantLock()

struct FwdRev{T}
    forward::T
    reverse::T
end

Base.:(==)(x::FwdRev{T}, y::FwdRev{T}) where T = x.forward == y.forward && x.reverse == y.reverse

datasize(t::T) where T = sizeof(t)
datasize(f::FwdRev{T}) where T = sizeof(FwdRev{T}) + datasize(f.forward) + datasize(f.reverse)
datasize(v::Vector{T}) where T = length(v) == 0 ? 0 : sum(datasize(a) for a in v)
datasize(t::Dict{K,V}) where {K,V} = length(t) == 0 ? 0 : sum(datasize(e.first) + datasize(e.second) for e in t)

struct CircularVector
    v::Vector{Int32}
end

@inline Base.length(cv::CircularVector) = Int32(length(cv.v))
@inline Base.getindex(cv::CircularVector, i::Int32) = @inbounds getindex(cv.v, mod1(i, length(cv)))
function Base.getindex(cv::CircularVector, r::UnitRange{<:Integer})
    len = length(cv)
	start = mod1(r.start, len)
    stop = mod1(r.stop, len)
	if start < stop
		return cv.v[start:stop]
    else
        return vcat(cv.v[start:end],cv.v[1:stop])
    end
end
@inline Base.setindex!(cv::CircularVector, value::Int32, i::Int32) = @inbounds setindex!(cv.v, value, mod1(i, length(cv)))
@inline Base.push!(cv::CircularVector, value::Int32) = @inbounds push!(cv.v, value)
function Base.sum(cv::CircularVector, r::UnitRange{<:Integer})
    sum = 0
    for i in r
        sum += cv[i]
    end
    return sum
end

struct CircularMask
    m::BitVector
end

@inline Base.length(cm::CircularMask) = Int32(length(cm.m))
@inline Base.getindex(cm::CircularMask, i::Int32) = @inbounds getindex(cm.m, mod1(i, length(cm)))
function Base.getindex(cm::CircularMask, r::UnitRange{<:Integer})
    len = length(cm)
	start = mod1(r.start, len)
    stop = mod1(r.stop, len)
	if start < stop
		return cm.m[start:stop]
    else
        return vcat(cm.m[start:end],cm.m[1:stop])
    end
end
@inline Base.setindex!(cm::CircularMask, value::Bool, i::Int32) = @inbounds setindex!(cm.m, value, mod1(i, length(cm)))
function Base.setindex!(cm::CircularMask, value::Bool, r::UnitRange{<:Integer})
    for i in r
        setindex!(cm.m, value, mod1(i, length(cm)))
    end
end
function Base.sum(cm::CircularMask, r::UnitRange{<:Integer})
    len = length(cm)
	start = mod1(r.start, len)
    stop = mod1(r.stop, len)
	if start < stop
		return sum(cm.m[start:stop])
    else
        return sum(cm.m[start:end]) + sum(cm.m[1:stop])
    end
end
Base.iterate(cm::CircularMask) = iterate(cm.m)
Base.iterate(cm::CircularMask, state) = iterate(cm.m, state)

using BioSequences

struct CircularSequence
    sequence::LongDNASeq
end

@inline Base.length(cs::CircularSequence) = Int32(length(cs.sequence))
@inline Base.getindex(cs::CircularSequence, i::Int32) = @inbounds getindex(cs.sequence, mod1(i, length(cs)))

function Base.getindex(cs::CircularSequence, r::UnitRange{<:Integer})
    len = length(cs.sequence)
	start = mod1(r.start, len)
    stop = mod1(r.stop, len)
	if start < stop
		return cs.sequence[start:stop]
    else
        return append!(cs.sequence[start:end],cs.sequence[1:stop])
    end
end

function reverse_complement(cs::CircularSequence)
    return CircularSequence(BioSequences.reverse_complement(cs.sequence))
end

@inline function getcodon(cs::CircularSequence, index::Int32)
    return (cs[index], cs[index + Int32(1)], cs[index + Int32(2)])
end

function gbff2fasta(infile::String)
    open(infile) do f
        while !eof(f)
            line = readline(f)
            fields = split(line)
            accession = fields[2]
            metadata = fields[2] * "\t" * fields[3] * "\t"
            while !occursin("ORGANISM", line)
                line = readline(f)
            end
            metadata = metadata * line[13:end] * "\t"
            line = readline(f)
            while !occursin("REFERENCE", line)
                metadata = metadata * line[13:end]
                line = readline(f)
            end
            while !startswith(line, "ORIGIN")
                line = readline(f)
            end
            open(accession * ".fna", "w") do o
                write(o, ">", accession, "\n")
                while !startswith(line, "//")
                    line = readline(f)
                    write(o, uppercase(join(split(line[11:end]))))
                end
                write(o, "\n")
            end
        end
    end
end

# const ns(td) = Time(Nanosecond(td))
ns(td) = @sprintf("%.3fs", td / 1e9)
elapsed(st) = @sprintf("%.3fs", (time_ns() - st) / 1e9)

function human(num::Integer)::String
    if num == 0
        return "0B"
    end
    magnitude = floor(Int, log10(abs(num)) / 3)
    val = num / (1000^magnitude)
    sval = @sprintf("%.1f", val)
    if magnitude > 7
        return "$(sval)YB"
    end
    p = ["", "k", "M", "G", "T", "P", "E", "Z"][magnitude + 1]
    return "$(sval)$(p)B"
end

function maybe_gzread(f::Function, filename::String)
    if endswith(filename, ".gz")
        open(z -> z |> GzipDecompressorStream |> f, filename)
    else
        open(f, filename)
    end
end

function maybe_gzwrite(f::Function, filename::String)
    
    function gzcompress(f::Function, fp::IO)
        o = GzipCompressorStream(fp)
        try
            f(o)
        finally
            close(o)
        end
    end

    if endswith(filename, ".gz")
        open(fp -> gzcompress(f, fp), filename, "w")
    else
        open(f, filename, "w")
    end
end


function readFasta(f::IO, name::String="<stream>")::Tuple{String,String}
    for res in iterFasta(f, name)
        return res
    end

    error("$(name): no FASTA data!")
end

function readFasta(fasta::String)::Tuple{String,String}
    for res in iterFasta(fasta)
        return res
    end

    error("$(fasta): no FASTA data!")

end


@inline function frameCounter(base::Int8, addition::Int32)
    result = (base - addition) % 3
    if result <= 0
        result = 3 + result
    end
    result
end

@inline function phaseCounter(base::Int8, addition::Integer)::Int8
    result::Int8 = (base - addition) % 3
    if result < 0
        result = Int8(3) + result
    end
    result
end

@inline function genome_wrap(genome_length::Integer, position::Integer)
    if 0 < position ≤ genome_length
    return position
    end
    while position > genome_length
        position -= genome_length
    end 
    while position ≤ 0
        position += genome_length
    end
    position
end

@inline function circulardistance(start, stop, seqlength)
    return stop ≥ start ? stop - start : stop + seqlength - start
end

#handles circular ranges
function overlaps(range1::UnitRange{Int32}, range2::UnitRange{Int32}, glength::Int32)::Vector{UnitRange{Int32}}
    ranges1 = UnitRange{Int32}[]
    ranges2 = UnitRange{Int32}[]

    if range1.stop ≤ glength
        push!(ranges1, range1)
    else
        push!(ranges1, range(range1.start, stop = glength))
        push!(ranges1, range(1, stop = mod1(range1.stop, glength)))
    end

    if range2.stop ≤ glength
        push!(ranges2, range2)
    else
        push!(ranges2, range(range2.start, stop = glength))
        push!(ranges2, range(1, stop = mod1(range2.stop, glength)))
    end

    overlaps = UnitRange{Int32}[]
    for r1 in ranges1, r2 in ranges2
        overlap = intersect(r1, r2)
        if length(overlap) > 0; push!(overlaps, overlap); end
    end

    #merge overlaps that can be merged
    overlaps_to_add = UnitRange{Int32}[]
    overlaps_to_remove = UnitRange{Int32}[]
    for o1 in overlaps, o2 in overlaps
        o1 === o2 && continue
        if o2.start == o1.stop + 1 || (o2.start == 1 && o1.stop == glength)
            push!(overlaps_to_add, range(o1.start, length = o1.stop - o1.start + 1 + o2.stop - o2.start + 1))
            push!(overlaps_to_remove, o1)
            push!(overlaps_to_remove, o2)
        end
    end
    setdiff!(overlaps, overlaps_to_remove)
    append!(overlaps, overlaps_to_add)
    sort(overlaps, by = o -> o.stop - o.start, rev = true) #may return two discontiguous overlaps
end

function findfastafile(dir::String, base::AbstractString)::Union{String,Nothing}
    suffixes = [".fa", ".fna", ".fasta"]
    for suffix in suffixes
        path = normpath(joinpath(dir, base * suffix))
        if isfile(path)
            return path
        end
    end
    return nothing
end

using GenomicAnnotations
function genbank2fasta(files::String)
    for file in filter(x->endswith(x, ".gb"), readdir(files, join = true))
        chr = readgbk(file)[1]
        outfilename = replace(split(basename(file),".")[1]," "=>"_")
        open(FASTA.Writer, outfilename*".fasta") do w
            write(w, FASTA.Record(chr.name, chr.sequence))
        end
    end
end


