using Api;
using Xunit;

namespace Api.Tests;

// Fast tests of the input rules. They need no database and no web server,
// so the pipeline can run them on every push before it builds an image.
public class CaseRulesTests
{
    [Theory]
    [InlineData("Open")]
    [InlineData("In progress")]
    [InlineData("Closed")]
    public void A_known_status_is_accepted(string status) =>
        Assert.Equal(status, CaseRules.Status(status));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("open")]
    [InlineData("Open' OR 1=1--")]
    public void Anything_else_is_refused_as_a_status(string? status)
    {
        var error = Assert.Throws<ApiError>(() => CaseRules.Status(status));
        Assert.Equal(422, error.Status);
        Assert.Equal("invalid_status", error.Code);
    }

    [Fact]
    public void A_client_name_is_trimmed() =>
        Assert.Equal("A. Smith", CaseRules.Client("  A. Smith  "));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void A_missing_or_blank_client_is_refused(string? client) =>
        Assert.Equal("invalid_client", Assert.Throws<ApiError>(() => CaseRules.Client(client)).Code);

    [Fact]
    public void A_client_name_over_100_characters_is_refused() =>
        Assert.Throws<ApiError>(() => CaseRules.Client(new string('x', 101)));

    [Fact]
    public void A_missing_number_uses_the_default() =>
        Assert.Equal(50, CaseRules.WholeNumber("limit", null, 50, 1, 100));

    [Theory]
    [InlineData("abc")]
    [InlineData("0")]
    [InlineData("101")]
    [InlineData("1.5")]
    public void A_bad_or_out_of_range_number_is_refused(string raw) =>
        Assert.Equal("invalid_limit", Assert.Throws<ApiError>(() => CaseRules.WholeNumber("limit", raw, 50, 1, 100)).Code);

    [Fact]
    public void A_number_in_range_is_accepted() =>
        Assert.Equal(25, CaseRules.WholeNumber("limit", "25", 50, 1, 100));
}
