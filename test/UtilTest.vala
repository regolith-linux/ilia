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

public void test_is_sleep_or_lock_signal() {
    assert (Ilia.is_sleep_or_lock_signal("org.freedesktop.login1.Manager", "PrepareForSleep", new Variant("(b)", true)));
    assert (Ilia.is_sleep_or_lock_signal("org.gnome.ScreenSaver", "ActiveChanged", new Variant("(b)", true)));

    // Resume and unlock
    assert (!Ilia.is_sleep_or_lock_signal("org.freedesktop.login1.Manager", "PrepareForSleep", new Variant("(b)", false)));
    assert (!Ilia.is_sleep_or_lock_signal("org.gnome.ScreenSaver", "ActiveChanged", new Variant("(b)", false)));

    // Other signals, and unexpected arguments
    assert (!Ilia.is_sleep_or_lock_signal("org.freedesktop.login1.Manager", "PrepareForShutdown", new Variant("(b)", true)));
    assert (!Ilia.is_sleep_or_lock_signal("org.gnome.ScreenSaver", "WakeUpScreen", new Variant("()")));
    assert (!Ilia.is_sleep_or_lock_signal("org.freedesktop.login1.Manager", "PrepareForSleep", new Variant("(s)", "true")));
    assert (!Ilia.is_sleep_or_lock_signal("org.freedesktop.login1.Manager", "PrepareForSleep", new Variant("()")));
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

DesktopAppInfo desktop_app(string dir, string name, string contents) {
    var filename = Path.build_filename(dir, name + ".desktop");
    try {
        FileUtils.set_contents(filename, "[Desktop Entry]\nType=Application\nExec=true\n" + contents);
    } catch (FileError e) {
        error("cannot write %s: %s", filename, e.message);
    }
    var app_info = new DesktopAppInfo.from_filename(filename);
    assert (app_info != null);
    return app_info;
}

// The apps page searches the generic name, keywords and comment, each on its own
public void test_desktop_app_search_text() {
    string dir;
    try {
        dir = DirUtils.make_tmp("ilia-apps-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }

    // Keywords without a comment, as GNOME Settings has (they were lost before)
    var settings_app = desktop_app(dir, "settings", "Name=Settings\nKeywords=Preferences;Settings;\n");
    assert (Ilia.matches_all_words("preferences", { settings_app.get_name(), Ilia.desktop_app_search_text(settings_app) }));

    // The generic name
    var viewer = desktop_app(dir, "viewer", "Name=Gn Only\nGenericName=Quuxviewer\n");
    assert (Ilia.matches_all_words("quuxviewer", { viewer.get_name(), Ilia.desktop_app_search_text(viewer) }));

    // All of them, with words kept apart: the last keyword and the comment do not run together
    var all = desktop_app(dir, "all", "Name=All\nGenericName=Generic\nKeywords=zebra;yak;\nComment=Does things\n");
    assert (Ilia.desktop_app_search_text(all) == "Generic zebra yak Does things");
    assert (!Ilia.matches_all_words("yakdoes", { all.get_name(), Ilia.desktop_app_search_text(all) }));

    // The value for the current locale (here the untranslated one), as for the name
    var localized = desktop_app(dir, "localized", "Name=Loc\nKeywords=plain;\nKeywords[xx]=localword;\n");
    assert (Ilia.desktop_app_search_text(localized) == "plain");

    // None of them
    var bare = desktop_app(dir, "bare", "Name=Bare\n");
    assert (Ilia.desktop_app_search_text(bare) == "");

    foreach (var name in new string[] { "settings", "viewer", "all", "localized", "bare" })
        FileUtils.unlink(Path.build_filename(dir, name + ".desktop"));
    DirUtils.remove(dir);
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

// Ctrl+w, Ctrl+b, Ctrl+C and Ctrl+X work in characters, as the entry does, also after non-ASCII text
public void test_word_motion() {
    // Before: "café bar" Ctrl+0 Ctrl+w went to byte 5, inside "bar"
    assert (Ilia.next_word_start("café bar", 0) == 5);
    assert (Ilia.next_word_start("ab cd", 0) == 3);
    assert (Ilia.next_word_start("ab cd", 3) == 5);
    assert (Ilia.next_word_start("ab, cd", 1) == 4);
    assert (Ilia.next_word_start("日本語 テスト", 0) == 4);
    assert (Ilia.next_word_start("", 0) == 0);

    // Back to the start of the previous word
    assert (Ilia.previous_word_start("über café bar", 13) == 5);
    assert (Ilia.previous_word_start("ab cd ef", 8) == 3);
    assert (Ilia.previous_word_start("ab cd ef", 6) == 3);
    assert (Ilia.previous_word_start("ab cd", 2) == 0);
    assert (Ilia.previous_word_start("日本語 テスト 終わり", 11) == 4);
    assert (Ilia.previous_word_start("", 0) == 0);

    // Selected text by character positions
    assert (Ilia.substring_chars("café bar", 3, 6) == "é b");
    assert (Ilia.substring_chars("café bar", 5, 8) == "bar");
    assert (Ilia.substring_chars("café", 0, 4) == "café");
}

public void test_move_path_to() {
    var path = new Gtk.TreePath.first();

    // Forward and back among the rows of a list
    Ilia.move_path_to(path, new Gtk.TreePath.from_string("2"));
    assert (path.to_string() == "2");
    Ilia.move_path_to(path, new Gtk.TreePath.from_string("1"));
    assert (path.to_string() == "1");
    Ilia.move_path_to(path, new Gtk.TreePath.first());
    assert (path.to_string() == "0");

    // Already there
    Ilia.move_path_to(path, new Gtk.TreePath.first());
    assert (path.to_string() == "0");
}

// After the last row is removed, the path moves to the new last row
public void test_clamp_path_to_rows() {
    var model = new Gtk.ListStore(1, typeof (string));
    Gtk.TreeIter iter;
    var path = new Gtk.TreePath.first();

    // Empty model: nothing to move to
    Ilia.clamp_path_to_rows(path, model);
    assert (path.to_string() == "0");

    model.insert_with_values(null, -1, 0, "first");
    model.insert_with_values(null, -1, 0, "second");
    model.insert_with_values(out iter, -1, 0, "last");

    // Inside the model: unchanged
    Ilia.move_path_to(path, new Gtk.TreePath.from_string("2"));
    Ilia.clamp_path_to_rows(path, model);
    assert (path.to_string() == "2");

    // The last row was removed
    model.remove(ref iter);
    Ilia.clamp_path_to_rows(path, model);
    assert (path.to_string() == "1");
}

public int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/test_systemd_escape", test_systemd_escape);
    Test.add_func ("/test_is_enter_key", test_is_enter_key);
    Test.add_func ("/test_is_sleep_or_lock_signal", test_is_sleep_or_lock_signal);
    Test.add_func ("/test_matches_all_words", test_matches_all_words);
    Test.add_func ("/test_word_motion", test_word_motion);
    Test.add_func ("/test_compare_desktop_apps", test_compare_desktop_apps);
    Test.add_func ("/test_desktop_app_search_text", test_desktop_app_search_text);
    Test.add_func ("/test_build_command_line", test_build_command_line);
    Test.add_func ("/test_move_path_to", test_move_path_to);
    Test.add_func ("/test_clamp_path_to_rows", test_clamp_path_to_rows);

    return Test.run ();
}