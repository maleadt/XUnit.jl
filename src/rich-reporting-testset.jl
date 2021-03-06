# RichReportingTestSet extends ReportingTestSet with providing richer
# test output for XUnit
mutable struct RichReportingTestSet <: Test.AbstractTestSet
    reporting_test_set::Ref{Option{ReportingTestSet}}
    flattened_reporting_test_set::Ref{Option{ReportingTestSet}}
    description::AbstractString
    xml_output::String
    html_output::String
    out_buff::IOBuffer
    err_buff::IOBuffer
end

# constructor takes a description string and options keyword arguments
function RichReportingTestSet(
    desc;
    xml_output::String="test-results.xml",
    other_args...
)
    html_output = "$xml_output.html"
    RichReportingTestSet(
        ReportingTestSet(desc),
        nothing,
        desc,
        xml_output,
        html_output,
        IOBuffer(),
        IOBuffer(),
    )
end

function Test.record(rich_ts::RichReportingTestSet, child::AbstractTestSet)
    return Test.record(rich_ts.reporting_test_set[], child)
end
function Test.record(rich_ts::RichReportingTestSet, res::Result)
    return Test.record(rich_ts.reporting_test_set[], res)
end
function Test.finish(rich_ts::RichReportingTestSet)
    # If we are a nested test set, do not print a full summary
    # now - let the parent test set do the printing
    if Test.get_testset_depth() != 0
        # Attach this test set to the parent test set
        parent_ts = get_testset()
        record(parent_ts, rich_ts)
    end

    return rich_ts
end

function TestReports.add_to_ts_default!(
    ts_default::Test.DefaultTestSet, rich_ts::RichReportingTestSet
)
    ts = rich_ts.reporting_test_set[]
    sub_ts = Test.DefaultTestSet(get_description(rich_ts))
    TestReports.add_to_ts_default!.(Ref(sub_ts), ts.results)
    push!(ts_default.results, sub_ts)
end

function TestReports.display_reporting_testset(
    ts::AbstractTestSet;
    throw_on_error::Bool = true,
)
    # show(ts)
    return nothing
end

function TestReports.display_reporting_testset(
    rich_ts::RichReportingTestSet;
    throw_on_error::Bool = true,
)
    ts_default = convert_to_default_testset(rich_ts)
    try
        # Finish the top level testset, to mimick the output from Pkg.test()
        finish(ts_default)
    catch err
        (throw_on_error || has_wrapped_exception(err, InterruptException)) && rethrow()
        # Otherwise, don't want to error here if a test fails or errors, as we just want to
        # display the result and don't care about alerting the caller program about the
        # test failures. This way, we can make sure that printing the test results always
        # happens completely, regardless of the tests having and error/failure or not.
    end
    return nothing
end

function Test.get_test_counts(ts::Union{RichReportingTestSet, AsyncTestSuiteOrTestCase})
    return Test.get_test_counts(convert_to_default_testset(ts))
end

function convert_to_default_testset(ts::AsyncTestSuiteOrTestCase)
    return convert_to_default_testset(ts.testset_report)
end
function convert_to_default_testset(rich_ts::RichReportingTestSet)::DefaultTestSet
    ts = rich_ts.reporting_test_set[]
    return _convert_to_default_testset(get_description(rich_ts), ts.results)
end

function _convert_to_default_testset(description, results)::DefaultTestSet
    # Create top level default testset to hold all results
    ts_default = DefaultTestSet(description)
    Test.push_testset(ts_default)
    TestReports.add_to_ts_default!.(Ref(ts_default), results)
    Test.pop_testset()
    return ts_default
end

function XUnit.convert_to_default_testset(ts::AbstractTestSet)
    return _convert_to_default_testset(get_description(ts), ts.results)
end

function test_out_io()
    ts = get_testset()
    @assert ts isa RichReportingTestSet
    ts.out_buff
end

function test_err_io()
    ts = get_testset()
    @assert ts isa RichReportingTestSet
    ts.err_buff
end

# Gathers per-test output. Should be used instead of `println` if you want to gather any
# output without worrying about multi-threaded execution of tests.
function test_print(input...)
    print(test_out_io(), input...)
end

# Gathers per-test output. Should be used instead of `print` if you want to gather any
# output without worrying about multi-threaded execution of tests.
function test_println(input...)
    println(test_out_io(), input...)
end

include("to-xml.jl")

"""
    html_report(rich_ts::RichReportingTestSet)

Generates an HTML file output for the given testset.

If `show_stdout` is `true`, then it also prints the test output in the standard output.
"""
function html_report(rich_ts::RichReportingTestSet)
    try
        xml_report(rich_ts)

        run(`junit2html $(rich_ts.xml_output)`)

        println("Test results in HTML format: $(rich_ts.html_output)")
    catch e
        @error "Error while producing the HTML report" exception=e
    end

    return rich_ts
end

"""
    function xml_report(rich_ts::RichReportingTestSet)

Generates an xUnit/JUnit-style XML file output for the given testset.
"""
function xml_report(rich_ts::RichReportingTestSet)
    # We are the top level, lets do this
    flatten_results!(rich_ts)

    open(rich_ts.xml_output, "w") do fh
        print(fh, report(rich_ts))
    end
    return rich_ts
end

create_deep_copy(x::Test.Broken) = x
create_deep_copy(x::Test.Pass) = x
create_deep_copy(x::Test.Fail) = x
create_deep_copy(x::Test.Error) = x
create_deep_copy(x::Nothing) = x

function create_deep_copy(ts::RichReportingTestSet)::RichReportingTestSet
    RichReportingTestSet(
        create_deep_copy(ts.reporting_test_set[]),
        create_deep_copy(ts.flattened_reporting_test_set[]),
        get_description(ts),
        ts.xml_output,
        ts.html_output,
        copy(ts.out_buff),
        copy(ts.out_buff),
    )
end

function create_deep_copy(ts::ReportingTestSet)::ReportingTestSet
    return ReportingTestSet(
        get_description(ts),
        map(create_deep_copy, ts.results),
        copy(ts.properties)
    )
end

function flatten_results!(rich_ts::RichReportingTestSet)
    if rich_ts.flattened_reporting_test_set[] === nothing
        rich_ts.flattened_reporting_test_set[] = create_deep_copy(rich_ts.reporting_test_set[])
        ts = rich_ts.flattened_reporting_test_set[]
        # Add any top level Results to their own TestSet
        TestReports.handle_top_level_results!(ts)

        # Flatten all results of top level testset, which should all be testsets now
        rich_ts.flattened_reporting_test_set[].results = vcat(_flatten_results!.(ts.results)...)
    end
    return rich_ts
end

"""
    _flatten_results!(ts::AbstractTestSet)::Vector{<:AbstractTestSet}

Recursively flatten `ts` to a vector of `TestSet`s.
"""
function _flatten_results!(rich_ts::RichReportingTestSet)::Vector{<:AbstractTestSet}
    rich_ts.flattened_reporting_test_set[] = create_deep_copy(rich_ts.reporting_test_set[])
    ts = rich_ts.flattened_reporting_test_set[]
    original_results = ts.results
    flattened_results = AbstractTestSet[]
    # Track results that are a Result so that if there are any, they can be added
    # in their own testset to flattened_results
    results = Result[]

    # Define nested functions
    function inner!(rs::Result)
        # Add to results vector
        push!(results, rs)
    end
    function inner!(childts::AbstractTestSet)
        # Make it a sibling
        TestReports.update_testset_properties!(childts, ts)
        childts.description = get_description(rich_ts) * "/" * get_description(childts)
        push!(flattened_results, childts)
    end

    # Iterate through original_results
    for res in original_results
        children = _flatten_results!(res)
        for child in children
            inner!(child)
        end
    end

    # results will be empty if ts.results only contains testsets
    if !isempty(results)
        # Use same ts to preserve description
        ts.results = results
        push!(flattened_results, rich_ts)
    end
    return flattened_results
end

function _flatten_results!(ts::ReportingTestSet)::Vector{<:AbstractTestSet}
    return TestReports._flatten_results!(ts)
end

"""
    _flatten_results!(rs::Result)

Return vector containing `rs` so that when iterated through,
`rs` is added to the results vector.
"""
_flatten_results!(rs::Result) = [rs]

html_output(rich_ts::RichReportingTestSet) = rich_ts.html_output
xml_output(rich_ts::RichReportingTestSet) = rich_ts.xml_output
