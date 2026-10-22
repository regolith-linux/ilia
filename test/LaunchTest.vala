using GLib;

// Tests for how desktop entries are turned into the command line that is launched.
// The fixtures live in a private XDG_DATA_HOME and PATH is pointed at fake
// executables, so no app is actually started.

string fixture_dir;
string bin_with_terminal;
string bin_without_terminal;
string bin_apps_only;

void write_executable(string dir, string name) {
    var path = Path.build_filename(dir, name);
    try {
        FileUtils.set_contents(path, "#!/bin/sh\nexit 0\n");
    } catch (FileError e) {
        error("%s", e.message);
    }
    FileUtils.chmod(path, 0755);
}

void write_desktop_file(string name, string contents) {
    try {
        FileUtils.set_contents(Path.build_filename(fixture_dir, "applications", name), contents);
    } catch (FileError e) {
        error("%s", e.message);
    }
}

void setup_fixtures() {
    try {
        fixture_dir = DirUtils.make_tmp("ilia-launch-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    DirUtils.create_with_parents(Path.build_filename(fixture_dir, "applications"), 0755);
    write_desktop_file("zzterm.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzterm\nTerminal=true\nExec=ranger\n");
    write_desktop_file("zzgui.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzgui\nExec=zzgui --new-window %U\n");
    write_desktop_file("zzargs.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzargs\nTerminal=true\nExec=htop --sort-key PERCENT_MEM\n");

    // PATH variants: with systemd-run and x-terminal-emulator, with systemd-run only,
    // and with neither. GIO ignores entries whose Exec program is not in PATH.
    bin_with_terminal = Path.build_filename(fixture_dir, "bin1");
    bin_without_terminal = Path.build_filename(fixture_dir, "bin2");
    bin_apps_only = Path.build_filename(fixture_dir, "bin3");
    foreach (var dir in new string[] { bin_with_terminal, bin_without_terminal, bin_apps_only }) {
        DirUtils.create(dir, 0755);
        foreach (var app in new string[] { "ranger", "htop", "zzgui" })
            write_executable(dir, app);
    }
    write_executable(bin_with_terminal, "systemd-run");
    write_executable(bin_with_terminal, "x-terminal-emulator");
    write_executable(bin_without_terminal, "systemd-run");

    // Must be set before GIO first scans the application directories
    Environment.set_variable("XDG_DATA_HOME", fixture_dir, true);
    Environment.set_variable("XDG_DATA_DIRS", fixture_dir, true);
}

// The command after "systemd-run --user --scope --unit <unit>"
string launched_command(AppInfo runner) {
    string[] argv;
    try {
        Shell.parse_argv(runner.get_commandline(), out argv);
    } catch (ShellError e) {
        error("%s", e.message);
    }
    assert (argv.length > 5);
    assert (argv[0] == "systemd-run");
    assert (argv[1] == "--user");
    assert (argv[2] == "--scope");
    assert (argv[3] == "--unit");
    assert (argv[4].has_prefix("run_ilia_"));
    // AppInfo.create_from_commandline() appends a %f field code, which expands to nothing
    int end = argv[argv.length - 1] == "%f" ? argv.length - 1 : argv.length;
    return string.joinv(" ", argv[5 : end]);
}

AppInfo runner_for(string desktop_id, string path) {
    Environment.set_variable("PATH", path, true);
    var app_info = new DesktopAppInfo(desktop_id);
    assert (app_info != null);
    try {
        return Ilia.get_runner_app_info(app_info);
    } catch (Error e) {
        error("%s", e.message);
    }
}

// ilia#92: a Terminal=true entry runs in a terminal, and the terminal is inside the scope
void test_terminal_app_in_scope() {
    var runner = runner_for("zzterm.desktop", bin_with_terminal);
    assert (launched_command(runner) == "x-terminal-emulator -e ranger");

    runner = runner_for("zzargs.desktop", bin_with_terminal);
    assert (launched_command(runner) == "x-terminal-emulator -e htop --sort-key PERCENT_MEM");
}

// GUI apps launch exactly as before
void test_gui_app_unchanged() {
    var runner = runner_for("zzgui.desktop", bin_with_terminal);
    assert (launched_command(runner) == "zzgui --new-window %U");
}

// Without x-terminal-emulator the command is left alone and GLib is asked to pick a terminal
void test_terminal_app_without_x_terminal_emulator() {
    var runner = runner_for("zzterm.desktop", bin_without_terminal);
    assert (launched_command(runner) == "ranger");
}

// Without systemd-run the entry is launched by GLib, which honours Terminal=true itself
void test_terminal_app_without_systemd_run() {
    Environment.set_variable("PATH", bin_apps_only, true);
    var app_info = new DesktopAppInfo("zzterm.desktop");
    try {
        assert (Ilia.get_runner_app_info(app_info) == app_info);
    } catch (Error e) {
        error("%s", e.message);
    }
    assert (app_info.get_boolean("Terminal"));
}

public int main(string[] args) {
    setup_fixtures(); // before Test.init(), which caches the XDG directories
    Test.init(ref args);

    Test.add_func("/launch/terminal_app_in_scope", test_terminal_app_in_scope);
    Test.add_func("/launch/gui_app_unchanged", test_gui_app_unchanged);
    Test.add_func("/launch/terminal_app_without_x_terminal_emulator", test_terminal_app_without_x_terminal_emulator);
    Test.add_func("/launch/terminal_app_without_systemd_run", test_terminal_app_without_systemd_run);

    return Test.run();
}
