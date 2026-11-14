using GLib;

// Tests for how desktop entries are turned into the command that is launched.
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
    write_desktop_file("zzcodes.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zz Codes\nName[de]=Zz Kodes\nIcon=zz icon\n"
                       + "Exec=zzgui %c --class=%c %i %k %% 100%%c %f %d %D %n %N %v %m end\n");
    write_desktop_file("zzliteral.desktop",
                       "[Desktop Entry]\nType=Application\nName=It's \"$HOME\" `x` \\\\ %k\n"
                       + "Exec=zzgui %c %i\n");
    write_desktop_file("zzquotes.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzquotes\n"
                       + "Exec=zzgui \"two words\" \"a\\\\\"b\" \\\\$HOME a\\sb\n");
    write_desktop_file("zzpath.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzpath\nPath=/some dir\nExec=zzgui\n");
    write_desktop_file("org.example.Zz-App.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zz App\nDBusActivatable=true\nExec=zzgui\n");
    write_desktop_file("zzdbus.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzdbus\nDBusActivatable=true\nExec=zzgui\n");

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

DesktopAppInfo app_info_for(string desktop_id, string path) {
    Environment.set_variable("PATH", path, true);
    var app_info = new DesktopAppInfo(desktop_id);
    assert (app_info != null);
    return app_info;
}

string[] launch_argv_for(string desktop_id, string path) {
    try {
        return Ilia.get_desktop_launch_argv(app_info_for(desktop_id, path));
    } catch (Error e) {
        error("%s", e.message);
    }
}

string[] exec_argv_for(string desktop_id) {
    try {
        return Ilia.expand_desktop_exec(app_info_for(desktop_id, bin_apps_only));
    } catch (Error e) {
        error("%s", e.message);
    }
}

// The command after "systemd-run --user --scope --unit <unit>"
string[] scoped_command(string[] argv, string desktop_id) {
    assert (argv.length > 5);
    assert (argv[0] == "systemd-run");
    assert (argv[1] == "--user");
    assert (argv[2] == "--scope");
    assert (argv[3] == "--unit");
    assert (argv[4].has_prefix("run_ilia_" + Ilia.systemd_escape(desktop_id) + "_"));
    assert (argv[4].has_suffix(".scope"));
    return argv[5 : argv.length];
}

void assert_argv(string[] argv, string[] expected) {
    if (string.joinv("\n", argv) != string.joinv("\n", expected) || argv.length != expected.length)
        error("argv [%s], expected [%s]", string.joinv("|", argv), string.joinv("|", expected));
}

// ilia#92: a Terminal=true entry runs in a terminal, and the terminal is inside the scope
void test_terminal_app_in_scope() {
    assert_argv(scoped_command(launch_argv_for("zzterm.desktop", bin_with_terminal), "zzterm.desktop"),
                { "x-terminal-emulator", "-e", "ranger" });
    assert_argv(scoped_command(launch_argv_for("zzargs.desktop", bin_with_terminal), "zzargs.desktop"),
                { "x-terminal-emulator", "-e", "htop", "--sort-key", "PERCENT_MEM" });
}

// GUI apps run in the scope directly, with no files for %U
void test_gui_app_in_scope() {
    assert_argv(scoped_command(launch_argv_for("zzgui.desktop", bin_with_terminal), "zzgui.desktop"),
                { "zzgui", "--new-window" });
}

// Without systemd-run the command is started directly, in the terminal for Terminal=true
void test_app_without_systemd_run() {
    assert_argv(launch_argv_for("zzterm.desktop", bin_apps_only), { "x-terminal-emulator", "-e", "ranger" });
    assert_argv(launch_argv_for("zzgui.desktop", bin_apps_only), { "zzgui", "--new-window" });
}

// Field codes, with the name in the user's language
void test_field_codes() {
    var filename = Path.build_filename(fixture_dir, "applications", "zzcodes.desktop");
    string[] expected = { "zzgui", "Zz Codes", "--class=Zz Codes", "--icon", "zz icon", filename, "%", "100%c", "end" };
    assert_argv(exec_argv_for("zzcodes.desktop"), expected);

    Environment.set_variable("LANGUAGE", "de", true);
    expected[1] = "Zz Kodes";
    expected[2] = "--class=Zz Kodes";
    assert_argv(exec_argv_for("zzcodes.desktop"), expected);
    Environment.unset_variable("LANGUAGE");

    // %i expands to nothing without an icon
    assert_argv(exec_argv_for("zzgui.desktop"), { "zzgui", "--new-window" });
}

// Expanded values are taken literally, whatever characters they hold
void test_literal_values() {
    assert_argv(exec_argv_for("zzliteral.desktop"), { "zzgui", "It's \"$HOME\" `x` \\ %k" });
}

// Quoting and escapes in the Exec key; the key file turns \s into a space before the command is split
void test_quoting() {
    assert_argv(exec_argv_for("zzquotes.desktop"), { "zzgui", "two words", "a\"b", "$HOME", "a", "b" });
}

// The Path key gives the working directory
void test_working_directory() {
    assert (Ilia.get_desktop_working_directory(app_info_for("zzpath.desktop", bin_apps_only)) == "/some dir");
    assert (Ilia.get_desktop_working_directory(app_info_for("zzgui.desktop", bin_apps_only)) == null);
}

// DBusActivatable entries are activated at the name and path their ID gives
void test_dbus_activation() {
    var bus_name = Ilia.get_dbus_activation_name(app_info_for("org.example.Zz-App.desktop", bin_apps_only));
    assert (bus_name == "org.example.Zz-App");
    assert (Ilia.get_dbus_activation_path(bus_name) == "/org/example/Zz_App");

    // Not activatable, or no valid bus name
    assert (Ilia.get_dbus_activation_name(app_info_for("zzgui.desktop", bin_apps_only)) == null);
    assert (Ilia.get_dbus_activation_name(app_info_for("zzdbus.desktop", bin_apps_only)) == null);
}

// Without systemd-run the commands page launches its command line as it is
void test_command_line_without_systemd_run() {
    Environment.set_variable("PATH", bin_apps_only, true);
    try {
        var app_info = AppInfo.create_from_commandline("zzgui --new-window", null, AppInfoCreateFlags.NONE);
        assert (Ilia.get_runner_app_info(app_info) == app_info);
    } catch (Error e) {
        error("%s", e.message);
    }
}

// The terminal and commands pages launch command lines, which have no desktop
// id: the scope is named after the program, with no critical logged
void test_command_line_in_scope() {
    Environment.set_variable("PATH", bin_with_terminal, true);
    try {
        var app_info = AppInfo.create_from_commandline("zzgui --new-window", null, AppInfoCreateFlags.NONE);
        string[] argv;
        Shell.parse_argv(Ilia.get_runner_app_info(app_info).get_commandline(), out argv);
        // GLib adds a %f to each command line it wraps; it expands to nothing at launch
        string[] command = {};
        foreach (var arg in scoped_command(argv, "zzgui"))
            if (arg != "%f")
                command += arg;
        assert_argv(command, { "zzgui", "--new-window" });
    } catch (Error e) {
        error("%s", e.message);
    }
}

public int main(string[] args) {
    setup_fixtures(); // before Test.init(), which caches the XDG directories
    Environment.unset_variable("LANGUAGE");
    Environment.set_variable("LC_ALL", "C.UTF-8", true);
    Test.init(ref args);

    Test.add_func("/launch/terminal_app_in_scope", test_terminal_app_in_scope);
    Test.add_func("/launch/gui_app_in_scope", test_gui_app_in_scope);
    Test.add_func("/launch/app_without_systemd_run", test_app_without_systemd_run);
    Test.add_func("/launch/field_codes", test_field_codes);
    Test.add_func("/launch/literal_values", test_literal_values);
    Test.add_func("/launch/quoting", test_quoting);
    Test.add_func("/launch/working_directory", test_working_directory);
    Test.add_func("/launch/dbus_activation", test_dbus_activation);
    Test.add_func("/launch/command_line_without_systemd_run", test_command_line_without_systemd_run);
    Test.add_func("/launch/command_line_in_scope", test_command_line_in_scope);

    return Test.run();
}
