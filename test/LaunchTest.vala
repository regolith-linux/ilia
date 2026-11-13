using GLib;

// Tests for how desktop entries are turned into the command that is launched.
// The fixtures live in a private XDG_DATA_HOME and PATH is pointed at fake
// executables, so no app is actually started.

string fixture_dir;
string bin_with_terminal;
string bin_without_terminal;
string bin_apps_only;
string snap_bin;

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

    // Actions: valid ones, listed twice, unknown, unnamed, without a command, and a group the Actions key omits
    write_desktop_file("zzactions.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzactions\nName[fr]=Zzactions FR\nIcon=zz-icon\n"
                       + "Exec=zzgui %U\nActions=new-window;missing;;unnamed;no-exec;blank-exec;new-window;private;\n\n"
                       + "[Desktop Action new-window]\nName=New Window\nName[fr]=Nouvelle fenêtre\nExec=zzgui --new-window %U\n\n"
                       + "[Desktop Action unnamed]\nExec=zzgui --unnamed\n\n"
                       + "[Desktop Action no-exec]\nName=No Exec\n\n"
                       + "[Desktop Action blank-exec]\nName=Blank Exec\nExec= \n\n"
                       + "[Desktop Action private]\nName=New Private Window\nIcon=zz-private\n"
                       + "Exec=zzgui --private --class=%c %i %k 100%% \"two words\" \"a\\\\\"b\" %F %u %d %Z\n\n"
                       + "[Desktop Action unlisted]\nName=Unlisted\nExec=zzgui --unlisted\n");
    write_desktop_file("zzquoted.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zz \"quoted\" app's\nExec=zzgui\n");
    write_desktop_file("zztermactions.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zztermactions\nTerminal=true\nExec=ranger\n"
                       + "Actions=home;\n\n[Desktop Action home]\nName=Home\nExec=ranger ~\n");
    // Started over the bus: actions need no command. The second ID is no valid bus name, so
    // that entry is started from its commands, as GLib does
    write_desktop_file("org.example.ZzBus.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzbus\nDBusActivatable=true\nExec=zzgui\n"
                       + "Actions=new-window;\n\n[Desktop Action new-window]\nName=New Window\n");
    write_desktop_file("zznobus.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zznobus\nDBusActivatable=true\nExec=zzgui\n"
                       + "Actions=bus-only;with-exec;\n\n[Desktop Action bus-only]\nName=Bus Only\n\n"
                       + "[Desktop Action with-exec]\nName=With Exec\nExec=zzgui --with-exec\n");

    // The real desktop file of the Firefox snap, as snapd installs it. GIO ignores an entry whose
    // Exec program is missing, so /snap/bin/firefox is pointed at a stand-in; nothing else changes
    snap_bin = Path.build_filename(fixture_dir, "snap-bin");
    DirUtils.create(snap_bin, 0755);
    write_executable(snap_bin, "firefox");
    try {
        string snap_firefox;
        FileUtils.get_contents(Path.build_filename(Environment.get_variable("ILIA_TEST_DATA"), "firefox_firefox.desktop"),
                               out snap_firefox);
        write_desktop_file("firefox_firefox.desktop", snap_firefox.replace("/snap/bin/firefox", snap_bin + "/firefox"));
    } catch (FileError e) {
        error("%s", e.message);
    }

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
        var app_info = app_info_for(desktop_id, path);
        return Ilia.get_desktop_launch_argv(app_info, app_info.get_commandline());
    } catch (Error e) {
        error("%s", e.message);
    }
}

string[] exec_argv_for(string desktop_id) {
    try {
        var app_info = app_info_for(desktop_id, bin_apps_only);
        return Ilia.expand_exec_field_codes(app_info, app_info.get_commandline());
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

string action_ids(Ilia.DesktopAction[] actions) {
    string[] ids = {};
    foreach (var action in actions)
        ids += action.id;
    return string.joinv(",", ids);
}

// ilia#5: the actions of an entry, in the order of its Actions key, each once, and only usable ones
void test_desktop_actions_listed() {
    Environment.set_variable("PATH", bin_with_terminal, true);
    var actions = Ilia.get_desktop_actions(new DesktopAppInfo("zzactions.desktop"));
    assert (action_ids(actions) == "new-window,private");
    assert (actions[0].name == "New Window");
    assert (actions[0].exec == "zzgui --new-window %U");
    assert (actions[0].icon == null);
    assert (actions[1].name == "New Private Window");
    assert (actions[1].icon == "zz-private");

    // Entries without actions
    assert (Ilia.get_desktop_actions(new DesktopAppInfo("zzgui.desktop")).length == 0);
}

// The action name in the user's language, the untranslated one otherwise
void test_desktop_action_localized_name() {
    Environment.set_variable("PATH", bin_with_terminal, true);
    var app_info = new DesktopAppInfo("zzactions.desktop");

    Environment.set_variable("LANGUAGE", "fr_CA:de", true);
    assert (Ilia.get_desktop_actions(app_info)[0].name == "Nouvelle fenêtre");
    Environment.set_variable("LANGUAGE", "de", true);
    assert (Ilia.get_desktop_actions(app_info)[0].name == "New Window");
    Environment.unset_variable("LANGUAGE");
}

// Over the bus, an action needs no command; an entry whose ID is no bus name is started from its commands
void test_desktop_actions_bus_activated() {
    Environment.set_variable("PATH", bin_with_terminal, true);
    var bus_app = new DesktopAppInfo("org.example.ZzBus.desktop");
    assert (Ilia.get_dbus_activation_name(bus_app) == "org.example.ZzBus");
    assert (action_ids(Ilia.get_desktop_actions(bus_app)) == "new-window");
    assert (Ilia.get_desktop_actions(bus_app)[0].exec == null);

    var not_bus_app = new DesktopAppInfo("zznobus.desktop");
    assert (Ilia.get_dbus_activation_name(not_bus_app) == null);
    assert (action_ids(Ilia.get_desktop_actions(not_bus_app)) == "with-exec");

    assert (Ilia.get_dbus_activation_name(new DesktopAppInfo("zzgui.desktop")) == null);
    assert (Ilia.get_dbus_activation_path("org.example.Bus-App") == "/org/example/Bus_App");
}

// Field codes, quoting and escapes of an action's command
void test_action_exec_expanded() {
    Environment.set_variable("PATH", bin_with_terminal, true);
    var app_info = new DesktopAppInfo("zzactions.desktop");
    var private_window = Ilia.get_desktop_actions(app_info)[1];
    string[] argv;
    try {
        argv = Ilia.expand_exec_field_codes(app_info, private_window.exec);
    } catch (ShellError e) {
        error("%s", e.message);
    }
    assert (string.joinv("|", argv) == "zzgui|--private|--class=Zzactions|--icon|zz-icon|" + app_info.get_filename()
            + "|100%|two words|a\"b");

    // A value with spaces and quotes stays one literal argument
    try {
        argv = Ilia.expand_exec_field_codes(new DesktopAppInfo("zzquoted.desktop"), "show --name=%c %c %i 50%");
    } catch (ShellError e) {
        error("%s", e.message);
    }
    assert (string.joinv("|", argv) == "show|--name=Zz \"quoted\" app's|Zz \"quoted\" app's|50%");
}

// The action runs in its own scope like the app, in a terminal for Terminal=true, without a scope when there is no systemd-run
void test_action_launch_argv() {
    try {
        Environment.set_variable("PATH", bin_with_terminal, true);
        var argv = Ilia.get_desktop_launch_argv(new DesktopAppInfo("zzactions.desktop"), "zzgui --new-window %U");
        assert (argv.length == 7);
        assert (string.joinv("|", argv[0 : 4]) == "systemd-run|--user|--scope|--unit");
        assert (argv[4].has_prefix("run_ilia_zzactions.desktop_") && argv[4].has_suffix(".scope"));
        assert (argv[4].length == "run_ilia_zzactions.desktop_".length + 8 + ".scope".length);
        assert (string.joinv("|", argv[5 : 7]) == "zzgui|--new-window");

        // A new scope name for every launch
        var again = Ilia.get_desktop_launch_argv(new DesktopAppInfo("zzactions.desktop"), "zzgui");
        assert (again[4] != argv[4]);

        argv = Ilia.get_desktop_launch_argv(new DesktopAppInfo("zztermactions.desktop"), "ranger ~");
        assert (string.joinv("|", argv[5 : argv.length]) == "x-terminal-emulator|-e|ranger|~");

        Environment.set_variable("PATH", bin_apps_only, true);
        argv = Ilia.get_desktop_launch_argv(new DesktopAppInfo("zztermactions.desktop"), "ranger ~");
        assert (string.joinv("|", argv) == "x-terminal-emulator|-e|ranger|~");
        argv = Ilia.get_desktop_launch_argv(new DesktopAppInfo("zzactions.desktop"), "zzgui --new-window %U");
        assert (string.joinv("|", argv) == "zzgui|--new-window");
    } catch (ShellError e) {
        error("%s", e.message);
    }
}

// The rows of the apps page that a filter shows, best first: the app and action rows of
// app_info, matched and ranked as the page does (see DesktopAppPage.filter_func())
string shown_rows(DesktopAppInfo app_info, string filter) {
    var app = Ilia.desktop_app_match(app_info, Ilia.AppField.ALL);
    Ilia.AppMatch[] rows = { app };
    string[] names = { app_info.get_name() };
    foreach (var action in Ilia.get_desktop_actions(app_info)) {
        rows += Ilia.desktop_action_match(app, action);
        names += Ilia.desktop_action_row_name(app_info, action);
    }

    // With a colon: the actions whose names hold the words after it, in the order of the
    // entry, when the words before it list the app
    string[] program_words, action_words;
    if (Ilia.split_action_query(filter, out program_words, out action_words)) {
        app.rank(program_words, false);
        string[] actions = {};
        for (int i = 1; i < rows.length; ++i) {
            if ((program_words.length == 0 || app.tier != Ilia.AppTier.NONE) && rows[i].names_action_with(action_words))
                actions += names[i];
        }
        return string.joinv(" | ", actions);
    }

    var words = Ilia.query_words(filter);

    var counts = new HashTable<string, int>(str_hash, str_equal);
    int[] shown = {};
    for (int i = 0; i < rows.length; ++i) {
        rows[i].rank(words, false);
        if (words.length > 0 && rows[i].tier != Ilia.AppTier.NONE)
            shown += i;
    }
    // Insertion sort by the page's comparator
    for (int i = 1; i < shown.length; ++i) {
        for (int j = i; j > 0 && Ilia.compare_app_matches(rows[shown[j]], rows[shown[j - 1]], counts) < 0; --j) {
            int t = shown[j];
            shown[j] = shown[j - 1];
            shown[j - 1] = t;
        }
    }

    string[] result = {};
    foreach (int i in shown)
        result += names[i];
    return string.joinv(" | ", result);
}

// ilia#173: the Firefox snap's own desktop file. Its three actions are read in the user's
// language, a filter that names one shows it, and the row that best fits the filter comes first
void test_snap_firefox_actions() {
    Environment.set_variable("PATH", bin_with_terminal, true);
    var firefox = new DesktopAppInfo("firefox_firefox.desktop");
    assert (firefox != null);

    var actions = Ilia.get_desktop_actions(firefox);
    assert (action_ids(actions) == "new-window,new-private-window,open-profile-manager");
    assert (actions[1].name == "New Private Window");
    assert (actions[1].exec == "/snap/bin/firefox --private-window %u".replace("/snap/bin", snap_bin));
    Environment.set_variable("LANGUAGE", "de", true);
    assert (Ilia.get_desktop_actions(firefox)[1].name == "Neues privates Fenster");
    Environment.set_variable("LANGUAGE", "es_ES", true);
    assert (Ilia.get_desktop_actions(firefox)[1].name == "Nueva ventana privada");
    Environment.unset_variable("LANGUAGE");

    // "private" is also in the app's comment, "Fast and private browser"
    assert (shown_rows(firefox, "firefox private") == "Firefox: New Private Window | Firefox");
    assert (shown_rows(firefox, "private") == "Firefox: New Private Window | Firefox");
    assert (shown_rows(firefox, "firefox") == "Firefox");
    assert (shown_rows(firefox, "") == "");
    // Typed without the colon, or as the action name alone, New Window comes before New Private Window
    assert (shown_rows(firefox, "firefox new window") == "Firefox: New Window | Firefox: New Private Window");
    assert (shown_rows(firefox, "new window") == "Firefox: New Window | Firefox: New Private Window");
    // With the colon, the actions whose names hold the words after it, in the order of the entry
    assert (shown_rows(firefox, "Firefox: New Window") == "Firefox: New Window | Firefox: New Private Window");
    assert (shown_rows(firefox, "fire:") == "Firefox: New Window | Firefox: New Private Window | Firefox: Open Profile Manager");
    assert (shown_rows(firefox, ":priv") == "Firefox: New Private Window");
    assert (shown_rows(firefox, "fire:firefox") == "");
    assert (shown_rows(firefox, "chromium:") == "");
    assert (shown_rows(firefox, "firefox new win") == "Firefox: New Window | Firefox: New Private Window");
    assert (shown_rows(firefox, "firefox new") == "Firefox: New Private Window | Firefox: New Window");
    assert (shown_rows(firefox, "profile") == "Firefox: Open Profile Manager");

    // The private window starts in a scope, without the %u
    try {
        var argv = Ilia.get_desktop_launch_argv(firefox, actions[1].exec);
        assert (string.joinv("|", argv[5 : argv.length]) == snap_bin + "/firefox|--private-window");
    } catch (ShellError e) {
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

    Test.add_func("/launch/desktop_actions_listed", test_desktop_actions_listed);
    Test.add_func("/launch/desktop_action_localized_name", test_desktop_action_localized_name);
    Test.add_func("/launch/desktop_actions_bus_activated", test_desktop_actions_bus_activated);
    Test.add_func("/launch/action_exec_expanded", test_action_exec_expanded);
    Test.add_func("/launch/action_launch_argv", test_action_launch_argv);
    Test.add_func("/launch/snap_firefox_actions", test_snap_firefox_actions);

    return Test.run();
}
