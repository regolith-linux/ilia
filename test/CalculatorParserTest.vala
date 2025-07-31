using GLib;

double _abs(double x) {
    return x < 0 ? -x : x;
}

public void test_parse () {
    double result;
    
    result = Ilia.ExpressionParser.parse("3+5");
    assert (result == 8.0);
    
    result = Ilia.ExpressionParser.parse("2*4 - 6");
    assert (result == 2.0);
    
    result = Ilia.ExpressionParser.parse("sin(π/6)");
    assert (_abs(result - 0.5) < 0.0001);
    
    result = Ilia.ExpressionParser.parse("cos(π)");
    assert (_abs(result + 1.0) < 0.0001);
    
    result = Ilia.ExpressionParser.parse("log(100)");
    assert (_abs(result - 2.0) < 0.0001);
}


public int main (string[] args) {
    Test.init (ref args);
    
    Test.add_func ("/parse", test_parse);
    
    return Test.run();
}
