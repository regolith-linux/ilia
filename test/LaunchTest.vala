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
    write_desktop_file("zzgpu.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzgpu\nPrefersNonDefaultGPU=true\nExec=zzgui\n");
    write_desktop_file("zzkde.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zzkde\nPrefersNonDefaultGPU=false\n"
                       + "X-KDE-RunOnDiscreteGpu=true\nExec=zzgui\n");
    write_desktop_file("zznogpu.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zznogpu\nPrefersNonDefaultGPU=false\nExec=zzgui\n");
    write_desktop_file("org.example.ZzNoExec.desktop",
                       "[Desktop Entry]\nType=Application\nName=Zz No Exec\nDBusActivatable=true\n");

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

// PrefersNonDefaultGPU and X-KDE-RunOnDiscreteGpu both ask for the other GPU
void test_prefers_non_default_gpu() {
    assert (Ilia.prefers_non_default_gpu(app_info_for("zzgpu.desktop", bin_apps_only)));
    assert (Ilia.prefers_non_default_gpu(app_info_for("zzkde.desktop", bin_apps_only)));
    assert (!Ilia.prefers_non_default_gpu(app_info_for("zznogpu.desktop", bin_apps_only)));
    assert (!Ilia.prefers_non_default_gpu(app_info_for("zzgui.desktop", bin_apps_only)));

    assert (Ilia.has_desktop_exec(app_info_for("org.example.Zz-App.desktop", bin_apps_only)));
    assert (!Ilia.has_desktop_exec(app_info_for("org.example.ZzNoExec.desktop", bin_apps_only)));
}

// A GPU as switcheroo-control describes it; null leaves a key out
Variant gpu(bool ? is_default, bool ? discrete, string[] ? environment) {
    var builder = new VariantBuilder(new VariantType("a{sv}"));
    if (is_default != null)
        builder.add("{sv}", "Default", new Variant.boolean(is_default));
    if (discrete != null)
        builder.add("{sv}", "Discrete", new Variant.boolean(discrete));
    if (environment != null)
        builder.add("{sv}", "Environment", new Variant.strv(environment));
    return builder.end();
}

string gpu_environment_of(Variant[] gpus) {
    var list = new Variant.array(new VariantType("a{sv}"), gpus);
    return string.joinv("|", Ilia.other_gpu_environment(list));
}

// The other GPU: discrete and not the default, else discrete, else not the default;
// GPUs without an Environment are passed over, an empty one gives no variables
void test_other_gpu_environment() {
    assert (Ilia.other_gpu_environment(null).length == 0);
    assert (gpu_environment_of({}) == "");
    assert (gpu_environment_of({ gpu(true, false, { "DRI_PRIME", "0" }), gpu(false, true, { "DRI_PRIME", "1" }) })
            == "DRI_PRIME|1");
    assert (gpu_environment_of({ gpu(true, true, { "A", "x" }), gpu(false, false, { "A", "y" }),
                                 gpu(false, true, { "A", "z" }) }) == "A|z");
    assert (gpu_environment_of({ gpu(true, true, { "A", "x" }), gpu(false, false, { "A", "y" }) }) == "A|x");
    assert (gpu_environment_of({ gpu(true, null, { "A", "d" }), gpu(null, null, { "A", "n" }) }) == "A|n");
    assert (gpu_environment_of({ gpu(false, true, null), gpu(true, true, { "A", "next" }) }) == "A|next");
    assert (gpu_environment_of({ gpu(true, true, null), gpu(false, false, { "A", "third" }) }) == "A|third");
    assert (gpu_environment_of({ gpu(true, false, { "A", "default" }) }) == "");
    assert (gpu_environment_of({ gpu(false, true, {}), gpu(true, true, { "A", "later" }) }) == "");
    assert (gpu_environment_of({ gpu(false, true, { "A", "1", "B" }) }) == "A|1");
    assert (gpu_environment_of({ gpu(false, true, { "A", "a b=c $HOME 'q'" }) }) == "A|a b=c $HOME 'q'");
}

// The variables are added to the environment, replacing those of the same name
void test_environ_with_variables() {
    string[] envp = { "KEEP=1", "DRI_PRIME=0" };
    envp = Ilia.environ_with_variables(envp, { "DRI_PRIME", "1", "NEW", "a=b", "BAD=NAME", "x" });
    assert (Environ.get_variable(envp, "KEEP") == "1");
    assert (Environ.get_variable(envp, "DRI_PRIME") == "1");
    assert (Environ.get_variable(envp, "NEW") == "a=b");
    assert (envp.length == 3);
}

// A PropertiesChanged signal's parameters
Variant properties_changed(string interface_name, Variant changed, string[] invalidated) {
    return new Variant.tuple({ new Variant.string(interface_name), changed, new Variant.strv(invalidated) });
}

Variant properties_dict(bool ? has_dual_gpu, Variant[] ? gpus) {
    var builder = new VariantBuilder(new VariantType("a{sv}"));
    if (has_dual_gpu != null)
        builder.add("{sv}", "HasDualGpu", new Variant.boolean(has_dual_gpu));
    if (gpus != null)
        builder.add("{sv}", "GPUs", new Variant.array(new VariantType("a{sv}"), gpus));
    return builder.end();
}

const string SWITCHEROO = "net.hadess.SwitcherooControl";

// The GPU information starts unknown, is filled in by a read, and follows PropertiesChanged:
// values sent with the signal are taken, invalidated-only properties become unknown and are
// returned to be read again, and a read started before a newer change does not undo it
void test_gpu_state() {
    string[] both = { "HasDualGpu", "GPUs" };
    var state = new Ilia.GpuState();
    assert (state.has_dual_gpu == null);
    assert (state.other_gpu_env.length == 0);

    state.apply_read(properties_dict(true, { gpu(true, false, { "A", "0" }), gpu(false, true, { "A", "1" }) }),
                     both, state.serials_of(both));
    assert (state.has_dual_gpu == true);
    assert (string.joinv("|", state.other_gpu_env) == "A|1");

    // New values in the signal
    string[] to_read = state.properties_changed(
        properties_changed(SWITCHEROO, properties_dict(null, { gpu(false, true, { "B", "2" }) }), {}), SWITCHEROO);
    assert (to_read.length == 0);
    assert (string.joinv("|", state.other_gpu_env) == "B|2");
    assert (state.has_dual_gpu == true);
    to_read = state.properties_changed(properties_changed(SWITCHEROO, properties_dict(false, null), {}), SWITCHEROO);
    assert (to_read.length == 0);
    assert (state.has_dual_gpu == false);

    // Another interface changes nothing
    to_read = state.properties_changed(properties_changed("org.example.Other", properties_dict(true, {}), { "GPUs" }),
                                       SWITCHEROO);
    assert (to_read.length == 0);
    assert (state.has_dual_gpu == false);
    assert (string.joinv("|", state.other_gpu_env) == "B|2");

    // Invalidated only: unknown until read again; other names are ignored
    to_read = state.properties_changed(properties_changed(SWITCHEROO, properties_dict(null, null),
                                                          { "NumGPUs", "GPUs", "HasDualGpu", "GPUs" }), SWITCHEROO);
    assert (string.joinv("|", to_read) == "GPUs|HasDualGpu");
    assert (state.has_dual_gpu == null);
    assert (state.other_gpu_env.length == 0);
    state.apply_read(properties_dict(true, { gpu(false, true, { "C", "3" }) }), to_read, state.serials_of(to_read));
    assert (state.has_dual_gpu == true);
    assert (string.joinv("|", state.other_gpu_env) == "C|3");

    // A property sent with its value as well as invalidated takes the value and is not read again
    to_read = state.properties_changed(properties_changed(SWITCHEROO, properties_dict(false, null), { "HasDualGpu" }),
                                       SWITCHEROO);
    assert (to_read.length == 0);
    assert (state.has_dual_gpu == false);

    // A read started before a newer change leaves the newer value
    string[] gpus_only = { "GPUs" };
    state.properties_changed(properties_changed(SWITCHEROO, properties_dict(null, null), gpus_only), SWITCHEROO);
    var serials = state.serials_of(gpus_only);
    state.properties_changed(properties_changed(SWITCHEROO, properties_dict(null, { gpu(false, true, { "D", "4" }) }), {}),
                             SWITCHEROO);
    state.apply_read(properties_dict(null, { gpu(false, true, { "OLD", "x" }) }), gpus_only, serials);
    assert (string.joinv("|", state.other_gpu_env) == "D|4");

    // A read that does not return a property leaves it unknown
    string[] dual_only = { "HasDualGpu" };
    state.apply_read(properties_dict(null, null), dual_only, state.serials_of(dual_only));
    assert (state.has_dual_gpu == null);
    assert (string.joinv("|", state.other_gpu_env) == "D|4");
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
    Test.add_func("/launch/prefers_non_default_gpu", test_prefers_non_default_gpu);
    Test.add_func("/launch/other_gpu_environment", test_other_gpu_environment);
    Test.add_func("/launch/environ_with_variables", test_environ_with_variables);
    Test.add_func("/launch/gpu_state", test_gpu_state);
    Test.add_func("/launch/command_line_without_systemd_run", test_command_line_without_systemd_run);
    Test.add_func("/launch/command_line_in_scope", test_command_line_in_scope);

    return Test.run();
}
