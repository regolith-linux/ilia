using GLib;

// Which texts are evaluated, and what is evaluated for them
public void test_to_expression() {
    assert (Ilia.Calculator.to_expression("1+2*3") == "1+2*3");
    assert (Ilia.Calculator.to_expression(" ( 1 + 2 ) * 3 ") == " ( 1 + 2 ) * 3 ");
    assert (Ilia.Calculator.to_expression("1,5*2") == "1.5*2");
    assert (Ilia.Calculator.to_expression("-2^-3^2") != null);
    assert (Ilia.Calculator.to_expression("2.5e-3*4") != null);
    assert (Ilia.Calculator.to_expression("1/7e7") != null);
    assert (Ilia.Calculator.to_expression("12!") != null);
    assert (Ilia.Calculator.to_expression("sqrt(abs(-9))+ln(e)+exp(0)-pi") != null);
    assert (Ilia.Calculator.to_expression("sin (pi/2) * cos(0) / tan(1)") != null);
    assert (Ilia.Calculator.to_expression(".5+5.") != null);

    string[] incomplete = {
        "", " ", "*3", "+3", "2+", "2*", "2^", "(1+2", "1+2)", "()", "sin()", "sin 2", "2 3",
        "x+1", "abc", "foo(2)", "factor(10)", "5 m", "2pi", "2(3)", "1e", "1e+", "PI", "1,5,5",
        "1.2.3", "2×3", "!3"
    };
    foreach (string text in incomplete)
        assert (Ilia.Calculator.to_expression(text) == null);
}

string nested(string open, int depth, string close) {
    var text = new StringBuilder();
    for (int i = 0; i < depth; i++)
        text.append(open);
    text.append("2");
    for (int i = 0; i < depth; i++)
        text.append(close);
    return text.str;
}

// Brackets and powers nest only so deep, however long the pasted text
public void test_to_expression_nesting() {
    int deepest = Ilia.Calculator.MAX_NESTING - 1;
    assert (Ilia.Calculator.to_expression(nested("(", deepest, ")")) != null);
    assert (Ilia.Calculator.to_expression(nested("(", deepest + 1, ")")) == null);
    assert (Ilia.Calculator.to_expression(nested("sqrt(", deepest, ")")) != null);
    assert (Ilia.Calculator.to_expression(nested("2^", deepest, "")) != null);
    assert (Ilia.Calculator.to_expression(nested("2^", deepest + 1, "")) == null);
    assert (Ilia.Calculator.to_expression(nested("(", 200000, ")")) == null);
    assert (Ilia.Calculator.to_expression(nested("2^-", 200000, "")) == null);
}

// Rounding to fifteen digits, and when scientific notation is used
public void test_format_value() {
    assert (Ilia.Calculator.format_value("7", true, ".") == "7");
    assert (Ilia.Calculator.format_value("0", true, ".") == "0");
    assert (Ilia.Calculator.format_value("-1298074214633706907132624082305024", true, ".") == "-1298074214633706907132624082305024");
    assert (Ilia.Calculator.format_value("1000000000000000000000000000000000000007", true, ".") == "1000000000000000000000000000000000000007");
    assert (Ilia.Calculator.format_value("10000000000000000000000000000000000000007", true, ".") == "1e40");
    assert (Ilia.Calculator.format_value("1606938044258990275541962092341162602522202993782792835301376", true, ".") == "1.60693804425899e60");

    assert (Ilia.Calculator.format_value("0.3333333333333333333333333333333333333333", false, ".") == "0.333333333333333");
    assert (Ilia.Calculator.format_value("0.6666666666666666666666666666666666666667", false, ",") == "0,666666666666667");
    assert (Ilia.Calculator.format_value("1.414213562373095048801688724209698078570", false, ".") == "1.4142135623731");
    assert (Ilia.Calculator.format_value("1.234567890123445", false, ".") == "1.23456789012345");
    assert (Ilia.Calculator.format_value("-1.234567890123445", false, ".") == "-1.23456789012345");
    assert (Ilia.Calculator.format_value("9.999999999999995", false, ".") == "10");
    assert (Ilia.Calculator.format_value("1000000000000000.5", false, ".") == "1000000000000000");
    assert (Ilia.Calculator.format_value("33333333333333333333.33333333333333333333", false, ".") == "33333333333333300000");
    assert (Ilia.Calculator.format_value("13333333333333333333333333333333333333333", false, ".") == "1.33333333333333e40");
    assert (Ilia.Calculator.format_value("0.000001", false, ".") == "0.000001");
    assert (Ilia.Calculator.format_value("-0.0000001", false, ".") == "-1e-7");
    assert (Ilia.Calculator.format_value("0.00000001428571428571428571428571428571428571429", false, ",") == "1,42857142857143e-8");
    assert (Ilia.Calculator.format_value("1.000000000000000000000000000000000000000E999999", false, ".") == "1e999999");
    assert (Ilia.Calculator.format_value("2.5E-3", false, ".") == "0.0025");
}

// libqalculate 3.22 writes some values with two digits before the point
public void test_format_value_unnormalized() {
    assert (Ilia.Calculator.format_value("10.000000000000000000000000000000000000000E999998", false, ".") == "1e999999");
    assert (Ilia.Calculator.format_value("12.5E-8", false, ".") == "1.25e-7");
}

public void test_read_helper_output() {
    assert (Ilia.Calculator.read_helper_output("integer 42\n", ".") == "42");
    assert (Ilia.Calculator.read_helper_output("decimal 0.25\n", ",") == "0,25");
    assert (Ilia.Calculator.read_helper_output("", ".") == null);
    assert (Ilia.Calculator.read_helper_output(null, ".") == null);
    assert (Ilia.Calculator.read_helper_output("integer 4", ".") == null);
    assert (Ilia.Calculator.read_helper_output("integer\n", ".") == null);
    assert (Ilia.Calculator.read_helper_output("fraction 1/2\n", ".") == null);
}

string helper;

// The text shown for an expression, worked out by the helper program as the page does it
string ? evaluate(string text, string decimal_mark) {
    string ? expression = Ilia.Calculator.to_expression(text);
    if (expression == null)
        return null;
    string output;
    try {
        Process.spawn_sync(null, { helper, expression }, null, SpawnFlags.STDERR_TO_DEV_NULL, null, out output);
    } catch (SpawnError e) {
        error("Cannot run %s: %s", helper, e.message);
    }
    return Ilia.Calculator.read_helper_output(output, decimal_mark);
}

public void test_helper() {
    string[,] values = {
        { "1+2*3", "7" },
        { "2^3^2", "512" },
        { "-2^2", "-4" },
        { "2^64", "18446744073709551616" },
        { "2^200", "1.60693804425899e60" },
        { "100!", "9.33262154439442e157" },
        { "2^2^2^2^2", "2.00352993040685e19728" },
        { "1/3", "0.333333333333333" },
        { "1e15+0.5", "1000000000000000" },
        { "1/7e7", "1.42857142857143e-8" },
        { "-0/7", "0" },
        { "1,5*2", "3" },
        { "sqrt(2)", "1.4142135623731" },
        { "sin(pi/2)", "1" },
        { "cos(pi)", "-1" },
        { "tan(pi/4)", "1" },
        { "sin(pi)", "0" },
        { "ln(e^2)", "2" },
        { "exp(1)", "2.71828182845905" },
        { "abs(-5)", "5" },
        { "1e999999", "1e999999" },
    };
    for (int i = 0; i < values.length[0]; i++) {
        string ? shown = evaluate(values[i, 0], ".");
        if (shown != values[i, 1])
            error("%s shows %s, expected %s", values[i, 0], shown ?? "nothing", values[i, 1]);
    }
    assert (evaluate("1/4", ",") == "0,25");

    string[] no_value = { "1/0", "0/0", "1/(1-1)", "0^-1", "sqrt(-1)", "ln(0)", "ln(-1)", "tan(pi/2)" };
    foreach (string text in no_value)
        if (evaluate(text, ".") != null)
            error("%s shows a value", text);
}

// The helper program to test is given as the only argument
public int main(string[] args) {
    Test.init(ref args);
    if (args.length != 2)
        error("Usage: %s HELPER", args[0]);
    helper = args[1];

    Test.add_func("/test_to_expression", test_to_expression);
    Test.add_func("/test_to_expression_nesting", test_to_expression_nesting);
    Test.add_func("/test_format_value", test_format_value);
    Test.add_func("/test_format_value_unnormalized", test_format_value_unnormalized);
    Test.add_func("/test_read_helper_output", test_read_helper_output);
    Test.add_func("/test_helper", test_helper);

    return Test.run();
}
