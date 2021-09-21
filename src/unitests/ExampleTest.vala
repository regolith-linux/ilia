public static int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/ilia/test-test", () => {
        assert ("foo" + "bar" == "foobar");
    });

    Test.run ();
    return 0;
}
