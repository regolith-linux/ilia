using GLib;

// Tests for pages defined in key files: names, parsing, rows, Exec and which file wins.
// The page directories are private: XDG_CONFIG_HOME and XDG_CONFIG_DIRS are set before
// GLib first reads them.

string config_root;

string page_dir(string name) {
    return Path.build_filename(config_root, name, "ilia", "pages");
}

void write_page(string dir, string file_name, string contents) {
    DirUtils.create_with_parents(dir, 0755);
    try {
        FileUtils.set_contents(Path.build_filename(dir, file_name), contents);
    } catch (FileError e) {
        error("%s", e.message);
    }
}

Ilia.PageFile ? read_page(string contents) throws GLib.Error {
    string dir = Path.build_filename(config_root, "single");
    write_page(dir, "test.page", contents);
    return new Ilia.PageFile.from_file(Path.build_filename(dir, "test.page"), "test");
}

// Reading a page that is expected to be usable
Ilia.PageFile read_usable(string contents) {
    try {
        return read_page(contents);
    } catch (GLib.Error e) {
        error("unexpected: %s", e.message);
    }
}

bool is_unusable(string contents) {
    try {
        read_page(contents);
        return false;
    } catch (GLib.Error e) {
        return true;
    }
}

void test_ids() {
    assert (Ilia.PageFile.is_valid_id("hosts"));
    assert (Ilia.PageFile.is_valid_id("My-Hosts_2"));
    assert (!Ilia.PageFile.is_valid_id(""));
    assert (!Ilia.PageFile.is_valid_id("my hosts"));
    assert (!Ilia.PageFile.is_valid_id("hosts.old"));
    assert (!Ilia.PageFile.is_valid_id("café"));

    foreach (unowned string id in new string[] { "apps", "terminal", "notifications", "keybindings", "textlist", "windows", "tracker" }) {
        assert (Ilia.PageFile.is_builtin_page(id));
        assert (Ilia.PageFile.is_builtin_page(id.ascii_up()));
    }
    assert (!Ilia.PageFile.is_builtin_page("hosts"));
}

void test_parse() {
    var page = read_usable("[Ilia Page]\nName=Hosts & <more>\nKey=H\nItems=x; alpha ;beta;;beta;\nOnlyShowIn= I3 ;sway\nUnknown=1\n[Other]\nName=x\n");
    assert (page.name == "Hosts & <more>");
    assert (page.icon == Ilia.PageFile.DEFAULT_ICON);
    assert (page.key == 'h');
    assert (page.source == Ilia.PageSource.ITEMS);
    // Entries as written, empty ones dropped, repeats kept
    assert (string.joinv("|", page.items) == "x| alpha |beta|beta");
    assert (page.exec_argv == null && !page.exec_invalid && !page.sort_by_frequency);
    assert (page.is_shown_under("i3") && page.is_shown_under("sway") && !page.is_shown_under("other"));

    page = read_usable("[Ilia Page]\nName=Run\nIcon=utilities-terminal\nItemsCommand=printf 'a\\n'\nNotShowIn=other\nExec=run --flag %s\nSort= Frequency \n");
    assert (page.source == Ilia.PageSource.COMMAND);
    // Key file escapes are decoded: \n is a newline
    assert (page.command == "printf 'a\n'");
    assert (page.icon == "utilities-terminal");
    assert (string.joinv("|", page.exec_argv) == "run|--flag|%s");
    assert (page.sort_by_frequency);
    assert (page.is_shown_under("i3") && !page.is_shown_under("other"));

    page = read_usable("[Ilia Page]\nName=Fav\nApps=b.desktop;a.desktop\nExec=ignored %s\nSort=frequency\n");
    assert (page.source == Ilia.PageSource.APPS);
    assert (string.joinv("|", page.apps) == "b.desktop|a.desktop");
    // Rows of desktop entries always launch the app, in the order listed
    assert (page.exec_argv == null && !page.sort_by_frequency);

    // Problems that leave the page usable: an unknown Sort, a Key that is not one letter, an Exec that cannot be split
    page = read_usable("[Ilia Page]\nName=X\nItems=a\nSort=random\nKey=ab\nExec=run 'unterminated\n");
    assert (!page.sort_by_frequency);
    assert (page.key == 0);
    assert (page.exec_argv == null && page.exec_invalid);
    assert (read_usable("[Ilia Page]\nName=X\nItems=a\nKey=1\n").key == 0);
}

void test_unusable() {
    assert (is_unusable("not a key file"));
    assert (is_unusable("[Other]\nName=X\nItems=a\n"));
    assert (is_unusable("[Ilia Page]\nItems=a\n"));
    assert (is_unusable("[Ilia Page]\nName=  \nItems=a\n"));
    assert (is_unusable("[Ilia Page]\nName=X\n"));
    assert (is_unusable("[Ilia Page]\nName=X\nItems=;;\nApps=;\nItemsCommand=  \n"));
    assert (is_unusable("[Ilia Page]\nName=X\nItems=a\nApps=a.desktop\n"));
    assert (is_unusable("[Ilia Page]\nName=X\nItems=a\nItemsCommand=echo b\n"));
    // An empty source counts as not given
    assert (!is_unusable("[Ilia Page]\nName=X\nItems=a\nApps=;\nItemsCommand= \n"));
}

void test_split_row() {
    string label, value;
    assert (Ilia.PageFile.split_row("plain text", out label, out value));
    assert (label == "plain text" && value == "plain text");

    assert (Ilia.PageFile.split_row("Gamma\tgamma.example", out label, out value));
    assert (label == "Gamma" && value == "gamma.example");

    assert (Ilia.PageFile.split_row("a\tb\tc", out label, out value));
    assert (label == "a" && value == "b\tc");

    assert (Ilia.PageFile.split_row("\tonly value", out label, out value));
    assert (label == "only value" && value == "only value");

    assert (Ilia.PageFile.split_row("only label\t", out label, out value));
    assert (label == "only label" && value == "only label");

    assert (!Ilia.PageFile.split_row("\t", out label, out value));
    assert (!Ilia.PageFile.split_row("", out label, out value));
}

void test_expand_exec() {
    string[] argv;
    Shell.parse_argv("ssh -t %s 'echo %s done' 100%% %d --x=%s%%", out argv);
    string value = "a b; $(rm -rf ~) `x` \"q\" 'r'";
    var expanded = Ilia.PageFile.expand_exec(argv, value);
    assert (expanded.length == 7);
    assert (expanded[0] == "ssh" && expanded[1] == "-t");
    assert (expanded[2] == value);
    assert (expanded[3] == "echo " + value + " done");
    assert (expanded[4] == "100%");
    assert (expanded[5] == "%d");
    assert (expanded[6] == "--x=" + value + "%");

    // Without %s the value is the last argument; %%s is a literal %s, a trailing % stays
    Shell.parse_argv("notify-send %%s 50%", out argv);
    expanded = Ilia.PageFile.expand_exec(argv, "v");
    assert (string.joinv("|", expanded) == "notify-send|%s|50%|v");
}

void test_load_all() {
    string user = page_dir("home");
    string first = page_dir("first");
    string second = page_dir("second");

    // The user's file wins over shared ones, whatever the letter case
    write_page(user, "Hosts.page", "[Ilia Page]\nName=User hosts\nItems=u\n");
    write_page(first, "hosts.page", "[Ilia Page]\nName=First hosts\nItems=f\n");
    // Among shared files the first directory wins, also when its file is unusable
    write_page(first, "broken.page", "[Ilia Page]\nItems=no name\n");
    write_page(second, "broken.page", "[Ilia Page]\nName=Second broken\nItems=s\n");
    write_page(second, "zeta.page", "[Ilia Page]\nName=Zeta\nItems=z\n");
    // In one directory, the name first in byte order wins
    write_page(second, "Dup.page", "[Ilia Page]\nName=Dup upper\nItems=d\n");
    write_page(second, "dup.page", "[Ilia Page]\nName=Dup lower\nItems=d\n");
    // Not page files, or names that cannot be used
    write_page(second, "upper.PAGE", "[Ilia Page]\nName=Upper\nItems=x\n");
    write_page(Path.build_filename(second, "sub"), "nested.page", "[Ilia Page]\nName=Nested\nItems=x\n");
    write_page(second, "my hosts.page", "[Ilia Page]\nName=Space\nItems=x\n");
    write_page(second, "Apps.page", "[Ilia Page]\nName=Apps\nItems=x\n");
    write_page(second, "Alpha.page", "[Ilia Page]\nName=Alpha\nItems=x\n");

    string[] names = {};
    foreach (var page in Ilia.PageFile.load_all())
        names += page.id + "=" + page.name;
    // By file name, in byte order
    assert (string.joinv("|", names) == "Alpha=Alpha|Dup=Dup upper|Hosts=User hosts|zeta=Zeta");
}

public int main(string[] args) {
    try {
        config_root = DirUtils.make_tmp("ilia-page-file-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    Environment.set_variable("XDG_CONFIG_HOME", Path.build_filename(config_root, "home"), true);
    Environment.set_variable("XDG_CONFIG_DIRS", Path.build_filename(config_root, "first") + ":"
                             + Path.build_filename(config_root, "missing") + ":"
                             + Path.build_filename(config_root, "second"), true);

    Test.init(ref args);

    Test.add_func("/pagefile/ids", test_ids);
    Test.add_func("/pagefile/parse", test_parse);
    Test.add_func("/pagefile/unusable", test_unusable);
    Test.add_func("/pagefile/split_row", test_split_row);
    Test.add_func("/pagefile/expand_exec", test_expand_exec);
    Test.add_func("/pagefile/load_all", test_load_all);

    return Test.run();
}
