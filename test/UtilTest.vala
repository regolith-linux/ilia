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

// The commands page lists each PATH directory once, and only commands in it
public void test_command_dirs() {
    string dir;
    try {
        dir = DirUtils.make_tmp("ilia-commands-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    var usr_bin = Path.build_filename(dir, "usr-bin");
    var bin = Path.build_filename(dir, "bin");  // a link to usr-bin, as with merged /usr
    var local = Path.build_filename(dir, "local");
    DirUtils.create(usr_bin, 0755);
    DirUtils.create(local, 0755);
    FileUtils.symlink("usr-bin", bin);

    // The same directory once, at its first entry; missing directories and empty entries skipped
    var path = string.joinv(":", { local, bin, Path.build_filename(dir, "missing"), "", usr_bin, local });
    assert (string.joinv(":", Ilia.command_dirs(path)) == local + ":" + bin);
    assert (Ilia.command_dirs(null).length == 0);

    // Executable files are commands, also through links; other entries are not
    var tool = Path.build_filename(usr_bin, "tool");
    try {
        FileUtils.set_contents(tool, "#!/bin/sh\n");
        FileUtils.set_contents(Path.build_filename(usr_bin, "README"), "not a command\n");
    } catch (FileError e) {
        error("%s", e.message);
    }
    FileUtils.chmod(tool, 0755);
    FileUtils.symlink("tool", Path.build_filename(usr_bin, "tool-alias"));
    FileUtils.symlink("gone", Path.build_filename(usr_bin, "dangling"));
    DirUtils.create(Path.build_filename(usr_bin, "subdir"), 0755);

    var attributes = FileAttribute.STANDARD_TYPE + "," + FileAttribute.ACCESS_CAN_EXECUTE;
    string[] commands = {};
    try {
        foreach (var name in new string[] { "README", "dangling", "subdir", "tool", "tool-alias" }) {
            var info = File.new_for_path(Path.build_filename(usr_bin, name)).query_info(attributes, FileQueryInfoFlags.NONE);
            if (Ilia.is_command(info))
                commands += name;
        }
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
    assert (string.joinv(" ", commands) == "tool tool-alias");

    foreach (var name in new string[] { "README", "dangling", "tool", "tool-alias" })
        FileUtils.unlink(Path.build_filename(usr_bin, name));
    DirUtils.remove(Path.build_filename(usr_bin, "subdir"));
    FileUtils.unlink(bin);
    DirUtils.remove(usr_bin);
    DirUtils.remove(local);
    DirUtils.remove(dir);
}

public void test_is_enter_key() {
    assert (Ilia.is_enter_key(Ilia.KEY_CODE_ENTER));
    assert (Ilia.is_enter_key(Ilia.KEY_CODE_KP_ENTER));
    assert (!Ilia.is_enter_key(Ilia.KEY_CODE_ESCAPE));
    assert (!Ilia.is_enter_key('\n'));
}

public void test_is_super_key() {
    assert (Ilia.is_super_key(Gdk.Key.Super_L));
    assert (Ilia.is_super_key(Gdk.Key.Super_R));
    assert (!Ilia.is_super_key(Gdk.Key.Alt_L));
    assert (!Ilia.is_super_key(Gdk.Key.Hyper_L));
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

// Compatibility decomposition, combining marks dropped, then full case folding
public void test_fold_text() {
    assert (Ilia.fold_text("Plain ASCII") == "plain ascii");
    assert (Ilia.fold_text("Café") == "cafe");
    assert (Ilia.fold_text("CAFÉ") == "cafe");
    assert (Ilia.fold_text("Straße") == "strasse");
    assert (Ilia.fold_text("ﬁle") == "file");
    assert (Ilia.fold_text("Ｆｕｌｌ") == "full");
    // U+0345 is a mark, dropped before case folding would turn it into a letter
    assert (Ilia.fold_text("Alpha\u0345") == "alpha");
    assert (Ilia.fold_text("ΟΣ") == "οσ");

    assert (Ilia.matches_all_words("cafe", { "Café Racer" }));
    assert (Ilia.matches_all_words("CAFÉ", { "cafe" }));
    assert (Ilia.matches_all_words("strasse", { "Straße" }));
    assert (Ilia.matches_all_words("file", { "ﬁle Manager" }));
}

public void test_subsequence() {
    assert (Ilia.is_subsequence("ffx", "firefox"));
    assert (Ilia.is_subsequence("", "firefox"));
    assert (!Ilia.is_subsequence("xff", "firefox"));
    assert (!Ilia.is_subsequence("ccc", "cafe cafe"));
    assert (Ilia.is_subsequence("éx", "aébx"));

    assert (Ilia.subsequence_span("ffx", "firefox") == 7);
    assert (Ilia.subsequence_span("ffx", "ffax tool") == 4);
    assert (Ilia.subsequence_span("qx", "z qaaaaqzx") == 3);
    assert (Ilia.subsequence_span("q", "aqa") == 1);
    assert (Ilia.subsequence_span("qx", "xq") == -1);

    // Each word takes its shortest span in any field
    assert (Ilia.words_subsequence_span({ "brsr", "stss" }, { "probe - browser", "mod4+strasse" }) == 7 + 6);
    assert (Ilia.words_subsequence_span({ "ffx" }, { "firefox focus", "mod4+ffax" }) == 4);
    assert (Ilia.words_subsequence_span({ "ffx", "zz" }, { "firefox" }) == -1);

    int span;
    string[] words = { "ffx" };
    assert (Ilia.match_words(words, { "ffx window" }, { "ffx window" }, true, out span) == Ilia.MatchKind.WORDS && span == 0);
    assert (Ilia.match_words(words, { "firefox" }, { "firefox" }, true, out span) == Ilia.MatchKind.SUBSEQUENCE && span == 7);
    assert (Ilia.match_words(words, { "firefox" }, { "firefox" }, false, out span) == Ilia.MatchKind.NONE);

    // Word-rule rows first in title order, then subsequence-only rows by span, then title
    assert (Ilia.compare_matched_rows(Ilia.MatchKind.WORDS, 0, "Z", Ilia.MatchKind.SUBSEQUENCE, 3, "A") < 0);
    assert (Ilia.compare_matched_rows(Ilia.MatchKind.WORDS, 0, "Z", Ilia.MatchKind.WORDS, 0, "A") > 0);
    assert (Ilia.compare_matched_rows(Ilia.MatchKind.SUBSEQUENCE, 5, "A Qaaax", Ilia.MatchKind.SUBSEQUENCE, 3, "Z Qzx") > 0);
    assert (Ilia.compare_matched_rows(Ilia.MatchKind.SUBSEQUENCE, 3, "A", Ilia.MatchKind.SUBSEQUENCE, 3, "B") < 0);
}

Ilia.AppMatch ranked_app(string id, string name, string ? generic, string keywords, string query, bool fuzzy = false,
                         string ? comment = null, Ilia.AppField fields = Ilia.AppField.ALL) {
    var app = new Ilia.AppMatch(id, name, generic, keywords, comment, fields);
    app.rank(Ilia.query_words(query), fuzzy);
    return app;
}

public void test_app_fields() {
    assert (Ilia.AppField.from_names({ "name", "generic-name", "keywords", "comment" }) == Ilia.AppField.ALL);
    assert (Ilia.AppField.from_names({ "bogus", "comment" }) == Ilia.AppField.COMMENT);
    assert (Ilia.AppField.from_names({}) == 0);

    var keywords_only = Ilia.AppField.from_names({ "name", "keywords" });
    assert (ranked_app("a", "Firefox", null, "browser", "browser", false, null, keywords_only).tier == Ilia.AppTier.IN_OTHER_FIELDS);
    assert (ranked_app("a", "Firefox", null, "browser", "web", false, "web browser", keywords_only).tier == Ilia.AppTier.NONE);
    assert (ranked_app("a", "Editor", "Code", "", "code", false, null, keywords_only).tier == Ilia.AppTier.NONE);
    var name_only = Ilia.AppField.from_names({ "name" });
    assert (ranked_app("a", "Code", "Editor", "", "code", false, null, name_only).tier == Ilia.AppTier.EXACT);
    assert (ranked_app("a", "Code", "Editor", "", "editor", false, null, name_only).tier == Ilia.AppTier.NONE);
    // Subsequence matching uses the name whatever the fields
    assert (ranked_app("a", "Firefox", null, "", "ffx", true, null, 0).tier == Ilia.AppTier.SUBSEQUENCE);
}

public void test_app_tiers() {
    assert (ranked_app("a", "Code", null, "", "code").tier == Ilia.AppTier.EXACT);
    assert (ranked_app("a", "Codec Tool", null, "", "code").tier == Ilia.AppTier.PREFIX);
    assert (ranked_app("a", "Visual Studio Code", null, "", "code").tier == Ilia.AppTier.WORD_STARTS);
    assert (ranked_app("a", "Barcode Reader", null, "", "code").tier == Ilia.AppTier.IN_NAME);
    assert (ranked_app("a", "Text Editor", "Source code editor", "", "code").tier == Ilia.AppTier.IN_GENERIC_NAME);
    assert (ranked_app("a", "Firefox", null, "code browser", "code").tier == Ilia.AppTier.IN_OTHER_FIELDS);
    assert (ranked_app("a", "Firefox", null, "code browser", "ffx").tier == Ilia.AppTier.NONE);
    assert (ranked_app("a", "Café", null, "", "CAFE").tier == Ilia.AppTier.EXACT);
    assert (ranked_app("a", "Zeta Dock", null, "", "  zeta\t dock ").tier == Ilia.AppTier.EXACT);
    assert (ranked_app("a", "Dock-Zeta", null, "", "zeta dock").tier == Ilia.AppTier.WORD_STARTS);
    assert (ranked_app("a", "Tool_λ7", null, "", "λ7").tier == Ilia.AppTier.WORD_STARTS);
    assert (ranked_app("a", "Tool9λ7", null, "", "λ7").tier == Ilia.AppTier.IN_NAME);

    var fuzzy = ranked_app("a", "Z Qzx Vyz", null, "", "qx vz", true);
    assert (fuzzy.tier == Ilia.AppTier.SUBSEQUENCE && fuzzy.span == 6);
    // Subsequence matching looks at the name only
    assert (ranked_app("a", "Plain App", null, "fancy fox", "ffx", true).tier == Ilia.AppTier.NONE);

    var counts = new GLib.HashTable<string, int>(GLib.str_hash, GLib.str_equal);
    counts.insert("firefox.desktop", 10);
    var firefox = ranked_app("firefox.desktop", "Firefox", null, "code", "code");
    var barcode = ranked_app("barcode.desktop", "Barcode Reader", null, "", "code");
    assert (Ilia.compare_app_matches(barcode, firefox, counts) < 0);
    // Inside a tier: launches, then the folded name, then the id
    var codec = ranked_app("codec.desktop", "Codec Tool", null, "", "co");
    var code = ranked_app("code.desktop", "Code", null, "", "co");
    assert (Ilia.compare_app_matches(code, codec, counts) < 0);
    counts.insert("codec.desktop", 1);
    assert (Ilia.compare_app_matches(code, codec, counts) > 0);
    var tie_a = ranked_app("a.desktop", "Qz Café", null, "", "qz");
    var tie_z = ranked_app("z.desktop", "Qz Cafe", null, "", "qz");
    assert (Ilia.compare_app_matches(tie_a, tie_z, counts) < 0);
    // Subsequence matches go by span before launches
    var short_span = ranked_app("short.desktop", "Ffax Tool", null, "", "ffx", true);
    var long_span = ranked_app("firefox.desktop", "Firefox", null, "", "ffx", true);
    assert (Ilia.compare_app_matches(short_span, long_span, counts) < 0);
}

public void test_is_hidden_app() {
    string[] hidden = { "org.example.Hidden.desktop", "snap-*.desktop", "a?.desktop" };
    assert (Ilia.is_hidden_app("org.example.Hidden.desktop", hidden));
    assert (Ilia.is_hidden_app("snap-one.desktop", hidden));
    assert (Ilia.is_hidden_app("a1.desktop", hidden));
    assert (Ilia.is_hidden_app("aé.desktop", hidden));
    assert (!Ilia.is_hidden_app("abc.desktop", hidden));
    assert (!Ilia.is_hidden_app("org.example.hidden.desktop", hidden));
    assert (!Ilia.is_hidden_app("xsnap-one.desktop", hidden));
    assert (!Ilia.is_hidden_app("signal.desktop", {}));
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

// The history keeps the newest launches: once it is full, the oldest one goes
public void test_append_launch_history() {
    assert (string.joinv(",", Ilia.append_launch_history(null, "a.desktop", 3)) == "a.desktop");
    assert (string.joinv(",", Ilia.append_launch_history({ "a", "b" }, "c", 3)) == "a,b,c");
    assert (string.joinv(",", Ilia.append_launch_history({ "a", "b", "c" }, "d", 3)) == "b,c,d");

    // A stored history longer than the limit is cut to the newest launches (before, it kept its length)
    assert (string.joinv(",", Ilia.append_launch_history({ "a", "b", "c", "d" }, "e", 2)) == "d,e");
}

Ilia.AppMatch ranked_action(string app_id, string app_name, string action_id, string action_name, string ? generic,
                            string keywords, string query, bool fuzzy = false) {
    var action = new Ilia.AppMatch(Ilia.launch_history_key(app_id, action_id), app_name + ": " + action_name,
                                   generic, keywords, null, Ilia.AppField.ALL, action_name);
    action.rank(Ilia.query_words(query), fuzzy);
    return action;
}

public void test_action_tiers() {
    // One word must occur in the action name, ignoring case and accents
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "zzact").tier == Ilia.AppTier.NONE);
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "zzact window").tier == Ilia.AppTier.WORD_STARTS);
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "WIN").tier == Ilia.AppTier.WORD_STARTS);
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "indow").tier == Ilia.AppTier.IN_NAME);
    assert (ranked_action("zz.desktop", "Zzact FR", "new", "Nouvelle fenêtre", null, "", "fenetre").tier == Ilia.AppTier.WORD_STARTS);
    // The row text is the name: the app part and the action part both count
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "zzact app: new").tier == Ilia.AppTier.PREFIX);
    // The app's fields count for the other words
    assert (ranked_action("q.desktop", "Quux", "priv", "New Private Window", "Web Browser", "", "browser private").tier == Ilia.AppTier.IN_GENERIC_NAME);
    assert (ranked_action("s.desktop", "Surf", "priv", "New Private Window", null, "web", "web private").tier == Ilia.AppTier.IN_OTHER_FIELDS);
    // Not through the app's fields alone, and not by subsequence of the action name alone
    assert (ranked_action("q.desktop", "Quux", "priv", "New Private Window", "Web Browser", "", "browser").tier == Ilia.AppTier.NONE);
    assert (ranked_action("z.desktop", "Zzact App", "new", "New Window", null, "", "nwn", true).tier == Ilia.AppTier.NONE);
    // With subsequence matching on, a word that names the action lets the others match by subsequence
    var fuzzy = ranked_action("f.desktop", "Firefox", "priv", "New Private Window", null, "", "ffx private", true);
    assert (fuzzy.tier == Ilia.AppTier.SUBSEQUENCE);
    // Nothing typed: not ranked
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "  ").tier == Ilia.AppTier.NONE);
    assert (ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "x").is_action);
    assert (!ranked_app("zz.desktop", "Zzact App", null, "", "x").is_action);

    // Each action has its own launch count, under <desktop id>#<action id>
    var counts = new GLib.HashTable<string, int>(GLib.str_hash, GLib.str_equal);
    counts.insert("zz.desktop", 9);
    counts.insert("zz.desktop#private", 2);
    var new_window = ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "zzact window");
    var private_window = ranked_action("zz.desktop", "Zzact App", "private", "New Private Window", null, "", "zzact window");
    assert (new_window.id == "zz.desktop#new");
    assert (Ilia.compare_app_matches(private_window, new_window, counts) < 0);
    // Ranked in the same tiers as the apps
    var app = ranked_app("zz.desktop", "Zzact App", null, "", "zzact window");
    assert (app.tier == Ilia.AppTier.NONE);
    var windows_app = ranked_app("w.desktop", "Windows Tool", null, "", "window");
    var action = ranked_action("zz.desktop", "Zzact App", "new", "New Window", null, "", "window");
    assert (Ilia.compare_app_matches(windows_app, action, counts) < 0);
}

public void test_launch_history_key() {
    assert (Ilia.launch_history_key("org.example.App.desktop", null) == "org.example.App.desktop");
    assert (Ilia.launch_history_key("org.example.App.desktop", "new-window") == "org.example.App.desktop#new-window");
}

public int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/test_systemd_escape", test_systemd_escape);
    Test.add_func ("/test_is_enter_key", test_is_enter_key);
    Test.add_func ("/test_is_super_key", test_is_super_key);
    Test.add_func ("/test_is_sleep_or_lock_signal", test_is_sleep_or_lock_signal);
    Test.add_func ("/test_matches_all_words", test_matches_all_words);
    Test.add_func ("/test_fold_text", test_fold_text);
    Test.add_func ("/test_subsequence", test_subsequence);
    Test.add_func ("/test_app_tiers", test_app_tiers);
    Test.add_func ("/test_app_fields", test_app_fields);
    Test.add_func ("/test_is_hidden_app", test_is_hidden_app);
    Test.add_func ("/test_word_motion", test_word_motion);
    Test.add_func ("/test_compare_desktop_apps", test_compare_desktop_apps);
    Test.add_func ("/test_desktop_app_search_text", test_desktop_app_search_text);
    Test.add_func ("/test_build_command_line", test_build_command_line);
    Test.add_func ("/test_command_dirs", test_command_dirs);
    Test.add_func ("/test_move_path_to", test_move_path_to);
    Test.add_func ("/test_clamp_path_to_rows", test_clamp_path_to_rows);
    Test.add_func ("/test_append_launch_history", test_append_launch_history);
    Test.add_func ("/test_action_tiers", test_action_tiers);
    Test.add_func ("/test_launch_history_key", test_launch_history_key);

    return Test.run ();
}