using GLib;


public void test_systemd_escape () {
    assert (Ilia.systemd_escape("asdf") == "asdf");

     // Taken from https://github.com/mk-pmb/systemd-escape-pmb-js/blob/master/test/01_basics.json
     assert (Ilia.systemd_escape("/dev/sda1") == "-dev-sda1");

     assert (Ilia.systemd_escape(
        "/dev/disk/by-uuid/c26af46b-d6dd-4614-b2d5-c7f4bf6291b9") == 
        "-dev-disk-by\\x2duuid-c26af46b\\x2dd6dd\\x2d4614\\x2db2d5\\x2dc7f4bf6291b9"
    );
     assert (Ilia.systemd_escape("/dev/disk/by-label/ab.cd-ef_gh=ij") == "-dev-disk-by\\x2dlabel-ab.cd\\x2def_gh\\x3dij");
     assert (Ilia.systemd_escape(".@/foo$bAR§qux/ab.çd-êf_gh=ij") == "\\x2e\\x40-foo\\x24bAR\\xc2\\xa7qux-ab.\\xc3\\xa7d\\x2d\\xc3\\xaaf_gh\\x3dij");
}

public void test_is_enter_key() {
    assert (Ilia.is_enter_key(Ilia.KEY_CODE_ENTER));
    assert (Ilia.is_enter_key(Ilia.KEY_CODE_KP_ENTER));
    assert (!Ilia.is_enter_key(Ilia.KEY_CODE_ESCAPE));
    assert (!Ilia.is_enter_key('\n'));
}

public void test_matches_all_words() {
    // Single word: substring, case-insensitive, as before
    assert (Ilia.matches_all_words("foo", { "foo bar baz" }));
    assert (Ilia.matches_all_words("BAR", { "foo bar baz" }));
    assert (!Ilia.matches_all_words("qux", { "foo bar baz" }));

    // Every word must match, in any order (ilia#77)
    assert (Ilia.matches_all_words("foo baz", { "foo bar baz" }));
    assert (Ilia.matches_all_words("baz foo", { "foo bar baz" }));
    assert (Ilia.matches_all_words("foo baz", { "foo --baz" }));
    assert (Ilia.matches_all_words("foo baz", { "foo-baz" }));
    assert (!Ilia.matches_all_words("foo baz", { "foo bar" }));
    assert (!Ilia.matches_all_words("foo baz", { "foo" }));

    // A contiguous query still matches as before
    assert (Ilia.matches_all_words("foo bar", { "foo bar baz" }));

    // Extra whitespace is ignored; a blank query matches everything
    assert (Ilia.matches_all_words("  foo \t  baz  ", { "foo bar baz" }));
    assert (Ilia.matches_all_words("", { "foo" }));
    assert (Ilia.matches_all_words("   ", { null }));

    // Non-ASCII text is matched case-insensitively
    assert (Ilia.matches_all_words("ÉCRAN capture", { "Capture d'écran" }));

    // Words may match different fields (e.g. app name and keywords); null fields are skipped
    assert (Ilia.matches_all_words("web firefox", { "Firefox", "Internet;WWW;Web;" }));
    assert (Ilia.matches_all_words("firefox", { null, "Firefox" }));
    assert (!Ilia.matches_all_words("firefox mail", { "Firefox", "Internet;WWW;Web;" }));
    assert (!Ilia.matches_all_words("foo", { null }));

    // A word does not match across the boundary of two fields
    assert (!Ilia.matches_all_words("foxinternet", { "Firefox", "Internet" }));
}

public void test_compare_desktop_apps() {
    // Create a mock launch counts table
    var launch_counts = new GLib.HashTable<string, int>(GLib.str_hash, GLib.str_equal);
    launch_counts.insert("app1.desktop", 5);
    launch_counts.insert("app2.desktop", 10);
    launch_counts.insert("app3.desktop", 5);

    // Test: Prefix matching (query string "fi")
    // app1 = "firefox", app2 = "files"
    // Both have prefix "fi", so should fall back to launch counts
    assert(Ilia.compare_desktop_apps(
        "firefox", "files",
        "app1.desktop", "app2.desktop",
        "fi", launch_counts) == 1); // app2 has higher launch count

    // Test: No query string, different launch counts
    assert(Ilia.compare_desktop_apps(
        "app1", "app2",
        "app1.desktop", "app2.desktop",
        "", launch_counts) == 1); // app2 has higher launch count

    // Test: No query string, no launch counts
    assert(Ilia.compare_desktop_apps(
        "app4", "app5",
        "app4.desktop", "app5.desktop",
        "", new GLib.HashTable<string, int>(GLib.str_hash, GLib.str_equal)) == -1); // alphabetical order

    // Test: One app has prefix, other doesn't
    assert(Ilia.compare_desktop_apps(
        "firefox", "chrome",
        "app1.desktop", "app3.desktop",
        "fi", launch_counts) == -1); // firefox has prefix "fi"

    // Test: Equal launch counts, fall back to alphabetical
    assert(Ilia.compare_desktop_apps(
        "chrome", "firefox",
        "app1.desktop", "app3.desktop",
        "", launch_counts) == -1); // "chrome" comes before "firefox" alphabetically
}

public void test_build_command_line() {
    // A path selected from the list, quoted as one argument: same command line as before
    assert (Ilia.build_command_line(Shell.quote("/usr/bin/flameshot"), false) == "x-terminal-emulator -e '/usr/bin/flameshot'");
    assert (Ilia.build_command_line(Shell.quote("/usr/bin/flameshot"), true) == "'/usr/bin/flameshot'");

    // Typed text keeps its arguments, which follow the program after -e (ilia#3)
    assert (Ilia.build_command_line("flameshot gui", false) == "x-terminal-emulator -e flameshot gui");
    assert (Ilia.build_command_line("xdg-open .", true) == "xdg-open .");

    // Literal % signs survive AppInfo's field code expansion
    assert (Ilia.build_command_line("date +%F", true) == "date +%%F");

    // The result parses into the expected arguments
    string[] argv;
    try {
        Shell.parse_argv(Ilia.build_command_line("npm docs 'some library'", false), out argv);
    } catch (ShellError e) {
        assert_not_reached ();
    }
    assert (string.joinv("|", argv) == "x-terminal-emulator|-e|npm|docs|some library");
}

public int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/test_systemd_escape", test_systemd_escape);
    Test.add_func ("/test_is_enter_key", test_is_enter_key);
    Test.add_func ("/test_matches_all_words", test_matches_all_words);
    Test.add_func ("/test_compare_desktop_apps", test_compare_desktop_apps);
    Test.add_func ("/test_build_command_line", test_build_command_line);

    return Test.run ();
}