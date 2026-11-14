using GLib;

// Tests for the desktop entries the add-application form writes. The entries go to a
// private XDG_DATA_HOME, and PATH holds one fake program.

string fixture_dir;
string data_home;
string system_dir;

void write_file(string path, string contents) {
    try {
        FileUtils.set_contents(path, contents);
    } catch (FileError e) {
        error("%s", e.message);
    }
}

void setup_fixtures() {
    try {
        fixture_dir = DirUtils.make_tmp("ilia-new-entry-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    var bin = Path.build_filename(fixture_dir, "bin");
    DirUtils.create(bin, 0755);
    write_file(Path.build_filename(bin, "probe"), "#!/bin/sh\nexit 0\n");
    FileUtils.chmod(Path.build_filename(bin, "probe"), 0755);
    write_file(Path.build_filename(bin, "plain"), "not executable\n");

    data_home = Path.build_filename(fixture_dir, "data", "home");
    system_dir = Path.build_filename(fixture_dir, "system");
    DirUtils.create_with_parents(Path.build_filename(system_dir, "applications", "taken"), 0755);
    write_file(Path.build_filename(system_dir, "applications", "taken.desktop"), "anything\n");
    write_file(Path.build_filename(system_dir, "applications", "taken", "3.desktop"), "anything\n");

    Environment.set_variable("HOME", fixture_dir, true);
    Environment.set_variable("PATH", bin, true);
    Environment.set_variable("XDG_DATA_HOME", data_home, true);
    Environment.set_variable("XDG_DATA_DIRS", system_dir, true);
}

string[] split(string command) {
    try {
        return Ilia.NewDesktopEntry.split_command_line(command);
    } catch (Ilia.NewDesktopEntryError e) {
        error("%s: %s", command, e.message);
    }
}

void assert_words(string command, string[] expected) {
    var words = split(command);
    assert (string.joinv("|", words) == string.joinv("|", expected));
    assert (words.length == expected.length);
}

void assert_invalid_command(string command) {
    try {
        Ilia.NewDesktopEntry.split_command_line(command);
        assert_not_reached();
    } catch (Ilia.NewDesktopEntryError e) {
        assert (e is Ilia.NewDesktopEntryError.COMMAND);
    }
}

public void test_split_command_line() {
    assert_words("probe --flag \"two words\"", { "probe", "--flag", "two words" });
    assert_words("probe 'a b' \"\\$HOME\" 'back\\slash' 'say \"hi\"' 100% '#tag' '~/x' it\\'s",
                 { "probe", "a b", "$HOME", "back\\slash", "say \"hi\"", "100%", "#tag", "~/x", "it's" });
    assert_words("probe \"keep\\q\" \"\\`t\\`\" \"q\\\"\" \"s\\\\\"", { "probe", "keep\\q", "`t`", "q\"", "s\\" });
    assert_words("probe ab\" c\"'d' \"\" '' pre\"\"post''", { "probe", "ab cd", "", "", "prepost" });
    assert_words("probe $HOME ${USER} $(x) `y` *.c #c ; & | > <",
                 { "probe", "$HOME", "${USER}", "$(x)", "`y`", "*.c", "#c", ";", "&", "|", ">", "<" });
    assert_words("probe \"joined\\\nline\" out\\\nside 'new\nline'", { "probe", "joinedline", "outside", "new\nline" });
    // An unquoted, unescaped newline divides words as a space or a tab does
    assert_words("probe\ta  b\nc", { "probe", "a", "b", "c" });
    assert_words("probe a\nb", { "probe", "a", "b" });
    assert_words("probe\n\n a \t\n b\n", { "probe", "a", "b" });
    assert_words("probe \"x\ny\" 'p\nq' a\\\nb", { "probe", "x\ny", "p\nq", "ab" });

    assert_invalid_command("");
    assert_invalid_command("   ");
    assert_invalid_command("probe \"open");
    assert_invalid_command("probe 'open");
    assert_invalid_command("probe \\");
}

// GLib reads the Exec value back into the same words, with every % literal
public void test_exec_value() {
    string[] words = {
        "probe", "a b", "$HOME", "back\\slash", "say \"hi\"", "100%", "`x`", "a;b", "é ü", "",
        "#tag", "~/x", "%f", "it's", "tab\there", "new\nline", "[ab]", "=x"
    };
    var exec = Ilia.NewDesktopEntry.exec_value(words);
    string[] parsed;
    try {
        Shell.parse_argv(exec.replace("%%", "%"), out parsed);
    } catch (ShellError e) {
        error("%s", e.message);
    }
    assert (string.joinv("|", parsed) == string.joinv("|", words));
    assert (Ilia.NewDesktopEntry.exec_value({ "probe", "--flag" }) == "probe --flag");
    assert (Ilia.NewDesktopEntry.exec_value({ "probe", "100%" }) == "probe 100%%");
}

// Tabs and newlines are escaped in every value, so that desktop-file-validate accepts them in Exec too
public void test_escape_value() {
    assert (Ilia.NewDesktopEntry.escape_value(" a\tb\nc\\d e") == "\\sa\\tb\\nc\\\\d e");

    var entry = new Ilia.NewDesktopEntry();
    entry.name = "Tab\tName";
    entry.command = "probe \"tab\there\" 'new\nline' 'k;w'";
    entry.keywords = "a;b, c\td";
    try {
        entry.validate();
    } catch (Ilia.NewDesktopEntryError e) {
        error("%s", e.message);
    }
    var data = entry.to_data();
    assert (!data.contains("\t") && data.contains("Name=Tab\\tName\n"));
    assert (data.contains("Exec=probe \"tab\\there\" \"new\\nline\" \"k;w\"\n"));
    assert (data.contains("Keywords=a\\;b;c\\td;\n"));
}

public void test_resolve_program() {
    try {
        assert (Ilia.NewDesktopEntry.resolve_program("probe") == "probe");
        assert (Ilia.NewDesktopEntry.resolve_program("~/bin/probe") == Path.build_filename(fixture_dir, "bin", "probe"));
        assert (Ilia.NewDesktopEntry.resolve_program(Path.build_filename(fixture_dir, "bin", "probe")) == Path.build_filename(fixture_dir, "bin", "probe"));
    } catch (Ilia.NewDesktopEntryError e) {
        error("%s", e.message);
    }
    foreach (var program in new string[] { "", "missing", "plain", "bin/probe", "~/bin/plain", "~/bin", fixture_dir }) {
        try {
            Ilia.NewDesktopEntry.resolve_program(program);
            assert_not_reached();
        } catch (Ilia.NewDesktopEntryError e) {
            assert (e is Ilia.NewDesktopEntryError.COMMAND);
        }
    }
}

public void test_icon_and_keywords() {
    try {
        assert (Ilia.NewDesktopEntry.icon_key_value("") == null);
        assert (Ilia.NewDesktopEntry.icon_key_value("utilities-terminal.png") == "utilities-terminal");
        assert (Ilia.NewDesktopEntry.icon_key_value("utilities-terminal.svg") == "utilities-terminal");
        assert (Ilia.NewDesktopEntry.icon_key_value("utilities-terminal.xpm") == "utilities-terminal");
        assert (Ilia.NewDesktopEntry.icon_key_value("utilities-terminal") == "utilities-terminal");
        var file = Path.build_filename(fixture_dir, "bin", "plain");
        assert (Ilia.NewDesktopEntry.icon_key_value(file) == file);
    } catch (Ilia.NewDesktopEntryError e) {
        error("%s", e.message);
    }
    foreach (var icon in new string[] { "icons/x.png", "/no/such/icon.png", fixture_dir }) {
        try {
            Ilia.NewDesktopEntry.icon_key_value(icon);
            assert_not_reached();
        } catch (Ilia.NewDesktopEntryError e) {
            assert (e is Ilia.NewDesktopEntryError.ICON);
        }
    }

    var keywords = Ilia.NewDesktopEntry.split_keywords("  ,alpha2, beta;gamma , ,delta,  ");
    assert (string.joinv("|", keywords) == "alpha2|beta;gamma|delta");
    // Only spaces, tabs and newlines are trimmed
    keywords = Ilia.NewDesktopEntry.split_keywords("\t one\n,\n\t,\rtwo\r");
    assert (string.joinv("|", keywords) == "one|\rtwo\r");
}

public void test_desktop_id_stem() {
    assert (Ilia.NewDesktopEntry.desktop_id_stem("Zoë's Tool 2") == "zo-s-tool-2");
    assert (Ilia.NewDesktopEntry.desktop_id_stem("日本語") == "app");
    assert (Ilia.NewDesktopEntry.desktop_id_stem("---A___B!!!") == "a-b");
    assert (Ilia.NewDesktopEntry.desktop_id_stem(string.nfill(100, 'A')) == string.nfill(64, 'a'));
    assert (Ilia.NewDesktopEntry.desktop_id_stem(string.nfill(63, 'A') + " B") == string.nfill(63, 'a'));
}

public void test_save() {
    var entry = new Ilia.NewDesktopEntry();
    entry.name = "  Taken  ";
    entry.command = "probe --x";
    entry.comment = "a;b = c";
    entry.keywords = "one, two;three";
    entry.terminal = true;

    var old_umask = Posix.umask(002);
    string path;
    try {
        path = entry.save();
    } catch (Ilia.NewDesktopEntryError e) {
        error("%s", e.message);
    }
    Posix.umask(old_umask);

    // taken.desktop and taken-3.desktop (taken/3.desktop) are system ids; -2 is the first free one
    var apps_dir = Path.build_filename(data_home, "applications");
    assert (path == Path.build_filename(apps_dir, "taken-2.desktop"));
    Posix.Stat st;
    assert (Posix.stat(path, out st) == 0 && (st.st_mode & 07777) == 0644);
    assert (Posix.stat(apps_dir, out st) == 0 && (st.st_mode & 07777) == 0700);
    assert (Posix.stat(data_home, out st) == 0 && (st.st_mode & 07777) == 0700);

    var info = new DesktopAppInfo.from_filename(path);
    assert (info != null);
    assert (info.get_name() == "Taken");
    assert (info.get_description() == "a;b = c");
    // The keyword with a ";" is searchable too
    assert (Ilia.desktop_app_search_text(info) == "one two;three a;b = c");
    assert (info.get_boolean("Terminal"));

    // A second entry of the same name gets the next free id, here past a dangling link
    FileUtils.symlink("gone", Path.build_filename(apps_dir, "taken-4.desktop"));
    try {
        assert (entry.save() == Path.build_filename(apps_dir, "taken-5.desktop"));
    } catch (Ilia.NewDesktopEntryError e) {
        error("%s", e.message);
    }
}

public static int main(string[] args) {
    setup_fixtures(); // before Test.init(), which caches the XDG directories
    Test.init(ref args);

    Test.add_func("/new_desktop_entry/split_command_line", test_split_command_line);
    Test.add_func("/new_desktop_entry/exec_value", test_exec_value);
    Test.add_func("/new_desktop_entry/escape_value", test_escape_value);
    Test.add_func("/new_desktop_entry/resolve_program", test_resolve_program);
    Test.add_func("/new_desktop_entry/icon_and_keywords", test_icon_and_keywords);
    Test.add_func("/new_desktop_entry/desktop_id_stem", test_desktop_id_stem);
    Test.add_func("/new_desktop_entry/save", test_save);

    return Test.run();
}
