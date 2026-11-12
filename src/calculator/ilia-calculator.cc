// ilia-calculator: works out the value of one expression for the calculator page.
//
// The page starts this helper for every expression and kills it as soon as the text changes
// or the evaluation takes too long: libqalculate cannot interrupt some calculations, such as
// the factorial of a large number, and a separate process keeps libqalculate out of the
// launcher itself.
//
// Usage: ilia-calculator EXPRESSION
//
// EXPRESSION uses a full stop as the decimal mark. The value is written to standard output as
// one line: "integer <digits>" for an exact whole number, else "decimal <text>", where <text>
// has a full stop decimal mark and an optional E exponent. Nothing is written, and the exit
// status is 1, when the expression has no single real value.

#include <csignal>
#include <cstdio>
#include <string>
#include <sys/prctl.h>
#include <unistd.h>

#include <libqalculate/qalculate.h>

// More digits than the page shows, so that rounding to the shown digits is exact
static const int WORKING_PRECISION = 40;
// The page gives up on an evaluation after three seconds; never run much longer than that,
// even when the launcher could not end this process
static const unsigned int TIME_LIMIT_SECONDS = 10;

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s EXPRESSION\n", argv[0]);
        return 2;
    }
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    alarm(TIME_LIMIT_SECONDS);

    // Only the built-in functions and constants are used: no definitions or exchange rates
    // are loaded, so nothing is fetched from the network. The process ends after one
    // evaluation, so the calculator is never deleted.
    Calculator *calculator = new Calculator();
    calculator->useDecimalPoint(false);
    calculator->setPrecision(WORKING_PRECISION);

    EvaluationOptions options;
    // Exact where possible, so that sin(pi) is 0 rather than a tiny approximation
    options.approximation = APPROXIMATION_TRY_EXACT;
    // Angles are in radians. Not ANGLE_UNIT_NONE: older libqalculate (4.5 in Debian 12,
    // 3.22 in Ubuntu 22.04) then leaves sin(pi/2) and the like unevaluated
    options.parse_options.angle_unit = ANGLE_UNIT_RADIANS;

    MathStructure result = calculator->calculate(argv[1], options);
    // A division by zero stays unevaluated; a list, a vector or anything else is not one number
    if (!result.isNumber())
        return 1;

    const Number &number = result.number();
    if (!number.isReal() || number.isInfinite())
        return 1;

    PrintOptions print_options;
    print_options.number_fraction_format = FRACTION_DECIMAL;
    print_options.min_exp = EXP_NONE;
    print_options.interval_display = INTERVAL_DISPLAY_MIDPOINT;
    print_options.digit_grouping = DIGIT_GROUPING_NONE;
    print_options.use_unicode_signs = false;
    print_options.decimalpoint_sign = ".";

    std::string text = number.print(print_options);
    printf("%s %s\n", number.isInteger() ? "integer" : "decimal", text.c_str());
    return fflush(stdout) == 0 ? 0 : 1;
}
