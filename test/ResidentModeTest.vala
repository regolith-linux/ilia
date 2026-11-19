using GLib;

// Tests for how calls find the background copy of their session, and when it answers them

HashTable<string, string ?> args_of(string[] args) {
    return Ilia.CommandLine.parse_args(args);
}

// A session is the user and the display and window manager variables; nothing else
public void test_session_identity() {
    string[] x11 = { "DISPLAY=:1", "I3SOCK=/run/i3.sock", "XDG_RUNTIME_DIR=/run/user/1000", "HOME=/users/a" };
    string name = Ilia.resident_socket_name(x11, 1000);

    // Other variables, the session bus included, do not make another session
    string[] other_bus = { "DISPLAY=:1", "I3SOCK=/run/i3.sock", "XDG_RUNTIME_DIR=/run/user/1000", "HOME=/users/b",
                           "DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/bus" };
    assert (Ilia.resident_socket_name(other_bus, 1000) == name);

    // Another user, display or socket does
    assert (Ilia.resident_socket_name(x11, 1001) != name);
    assert (Ilia.resident_socket_name({ "DISPLAY=:1.0", "I3SOCK=/run/i3.sock", "XDG_RUNTIME_DIR=/run/user/1000" }, 1000) != name);
    assert (Ilia.resident_socket_name({ "DISPLAY=:1", "I3SOCK=/run/i3-alias.sock", "XDG_RUNTIME_DIR=/run/user/1000" }, 1000) != name);

    // An empty variable is not an unset one
    string[] empty = { "DISPLAY=:1", "I3SOCK=/run/i3.sock", "XDG_RUNTIME_DIR=/run/user/1000", "WAYLAND_DISPLAY=" };
    assert (Ilia.resident_socket_name(empty, 1000) != name);

    // The name fits an abstract socket address
    assert (name.length < 100);
}

public void test_same_surroundings() {
    string[] env = { "LANG=C.UTF-8", "HOME=/users/a", "XDG_DATA_DIRS=/usr/share", "PATH=/usr/bin", "CALLER=1" };

    // The caller's own variables, PATH among them, may differ
    assert (Ilia.same_surroundings(env, { "LANG=C.UTF-8", "HOME=/users/a", "XDG_DATA_DIRS=/usr/share", "PATH=/bin" }));

    assert (!Ilia.same_surroundings(env, { "LANG=C", "HOME=/users/a", "XDG_DATA_DIRS=/usr/share" }));
    assert (!Ilia.same_surroundings(env, { "LANG=C.UTF-8", "HOME=/users/a", "XDG_DATA_DIRS=/usr/share:/opt/share" }));
    // A variable set on one side only
    assert (!Ilia.same_surroundings(env, { "LANG=C.UTF-8", "HOME=/users/a", "XDG_DATA_DIRS=/usr/share", "LANGUAGE=fr" }));
    assert (!Ilia.same_surroundings(env, { "LANG=C.UTF-8", "XDG_DATA_DIRS=/usr/share" }));
}

// textlist and tracker always start on their own, as do unknown pages, which fail as before
public void test_resident_pages() {
    assert (Ilia.is_resident_page(args_of({ "ilia" })));
    assert (Ilia.is_resident_page(args_of({ "ilia", "-p", "apps" })));
    assert (Ilia.is_resident_page(args_of({ "ilia", "-p", "Terminal", "-q" })));
    assert (Ilia.is_resident_page(args_of({ "ilia", "-p", "notifications" })));
    assert (Ilia.is_resident_page(args_of({ "ilia", "-p", "keybindings" })));
    assert (Ilia.is_resident_page(args_of({ "ilia", "-p", "windows" })));
    assert (Ilia.is_resident_page(args_of({ "ilia", "-a", "-p", "windows" })));

    assert (!Ilia.is_resident_page(args_of({ "ilia", "-p", "textlist" })));
    assert (!Ilia.is_resident_page(args_of({ "ilia", "-p", "tracker" })));
    assert (!Ilia.is_resident_page(args_of({ "ilia", "-a", "-p", "tracker" })));
    assert (!Ilia.is_resident_page(args_of({ "ilia", "-p", "no-such-page" })));
}

// Programs started for a call take PATH and the environment from the caller
public void test_caller_environment() {
    string dir;
    try {
        dir = DirUtils.make_tmp("ilia-caller-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    var tool = Path.build_filename(dir, "only-in-caller-path");
    try {
        FileUtils.set_contents(tool, "#!/bin/sh\nexit 0\n");
    } catch (FileError e) {
        error("%s", e.message);
    }
    FileUtils.chmod(tool, 0755);

    // Without a caller, the process's own environment
    Ilia.CallerEnvironment.set_environ(null);
    assert (Ilia.CallerEnvironment.get_environ() == null);
    assert (Ilia.CallerEnvironment.create_launch_context() == null);
    assert (Ilia.CallerEnvironment.find_program("only-in-caller-path") == null);

    Ilia.CallerEnvironment.set_environ({ "PATH=/nonexistent:" + dir, "CALLER_MARKER=one" });
    assert (Ilia.CallerEnvironment.find_program("only-in-caller-path") == tool);
    assert (Ilia.CallerEnvironment.find_program("sh") == null);
    assert (Ilia.CallerEnvironment.get_variable("CALLER_MARKER") == "one");
    assert ((Ilia.CallerEnvironment.search_path_flags() & SpawnFlags.SEARCH_PATH_FROM_ENVP) != 0);

    // A launch context holds exactly the caller's variables
    var context = Ilia.CallerEnvironment.create_launch_context();
    assert (context != null);
    string[] environment = context.get_environment();
    assert (Environ.get_variable(environment, "CALLER_MARKER") == "one");
    assert (Environ.get_variable(environment, "HOME") == null);
    assert (environment.length == 2);

    Ilia.CallerEnvironment.set_environ(null);
    FileUtils.unlink(tool);
    DirUtils.remove(dir);
}

// One background copy per session: a second one cannot take the socket
public void test_one_server_per_session() {
    string[] env = { "DISPLAY=:ilia-test-%d".printf((int) Posix.getpid()) };
    var first = Ilia.bind_resident_socket(env);
    assert (first != null);
    assert (Ilia.bind_resident_socket(env) == null);

    // Another session can
    string[] other = { "DISPLAY=:ilia-test-other-%d".printf((int) Posix.getpid()) };
    assert (Ilia.bind_resident_socket(other) != null);
}

public static int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/test_session_identity", test_session_identity);
    Test.add_func("/test_same_surroundings", test_same_surroundings);
    Test.add_func("/test_resident_pages", test_resident_pages);
    Test.add_func("/test_caller_environment", test_caller_environment);
    Test.add_func("/test_one_server_per_session", test_one_server_per_session);

    return Test.run();
}
