/**
 * Simplest possible unit test in Vala+Meson
 */
public static int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/autovala/test-test", () => {
        assert ("foo" + "bar" == "foobar");
    });

    Test.run ();
    return 0;
}


