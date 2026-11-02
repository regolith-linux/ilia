using GLib;

// Serve canned i3 IPC replies on a local socket, writing each reply in small
// chunks so the client sees partial reads, as with a real window manager.
class FakeWm {
    public string socket_path;
    private Socket listener;
    private string[] payloads;
    private Thread<void> thread;
    // The payload of each request received, in order
    public string[] requests = {};

    public FakeWm (string[] payloads) throws GLib.Error {
        this.payloads = payloads;
        var dir = DirUtils.make_tmp("ilia-ipc-test-XXXXXX");
        socket_path = Path.build_filename(dir, "ipc.sock");
        listener = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
        listener.bind(new UnixSocketAddress(socket_path), true);
        listener.listen();
        thread = new Thread<void>("fake-wm", serve);
    }

    private void send_all(Socket conn, uint8[] data) throws GLib.Error {
        size_t sent = 0;
        while (sent < data.length) {
            size_t end = size_t.min(sent + 4096, data.length);
            sent += conn.send(data[sent: end]);
            Thread.usleep(100);
        }
    }

    private void serve() {
        try {
            var conn = listener.accept();
            foreach (unowned string payload in payloads) {
                var header = new uint8[14];
                size_t got = 0;
                while (got < header.length)
                    got += conn.receive(header[got: header.length]);
                uint32 request_length = 0, type = 0;
                Memory.copy(&request_length, &header[6], 4);
                Memory.copy(&type, &header[10], 4);
                var request = new uint8[request_length + 1];
                got = 0;
                while (got < request_length)
                    got += conn.receive(request[got: request_length]);
                request[request_length] = 0;
                requests += (string) request;

                var reply = new ByteArray();
                reply.append("i3-ipc".data);
                uint32 length = payload.length;
                reply.append(((uint8[]) &length)[0 : 4]);
                reply.append(((uint8[]) &type)[0 : 4]);
                reply.append(payload.data);
                send_all(conn, reply.data);
            }
            conn.close();
        } catch (GLib.Error e) {
            error("fake WM failed: %s", e.message);
        }
    }

    public void join() {
        thread.join();
        FileUtils.unlink(socket_path);
        DirUtils.remove(Path.get_dirname(socket_path));
    }
}

string config_reply(string config) {
    var builder = new Json.Builder();
    builder.begin_object();
    builder.set_member_name("config");
    builder.add_string_value(config);
    builder.set_member_name("included_configs");
    builder.begin_array();
    builder.begin_object();
    builder.set_member_name("path");
    builder.add_string_value("/etc/i3/config");
    builder.set_member_name("raw_contents");
    builder.add_string_value(config);
    builder.set_member_name("variable_replaced_contents");
    builder.add_string_value(config);
    builder.end_object();
    builder.end_array();
    builder.end_object();
    var generator = new Json.Generator();
    generator.set_root(builder.get_root());
    return generator.to_data(null);
}

string make_config(int lines) {
    var config = new StringBuilder("set $mod Mod4\n");
    for (int i = 0; i < lines; i++)
        config.append_printf("## Custom // Action %d // <> F1 ## \"quoted\" padding xxxxxxxxxxxxxxxxxxxxxxxx\n", i);
    return config.str;
}

// ilia#67: a GET_CONFIG reply larger than the old 128 KiB receive buffer
public void test_large_config_reply() {
    var config = make_config(3000);
    assert(config.length > 128 * 1024);

    try {
        var wm = new FakeWm({ config_reply(config) });
        Environment.set_variable("I3SOCK", wm.socket_path, true);
        var reply = new Ilia.IPCClient("i3").getConfig();
        wm.join();
        assert(reply.config == config);
    } catch (GLib.Error e) {
        error("getConfig failed: %s", e.message);
    }
}

// Each reply is read to its end, so a second request on the same connection
// does not start reading inside the first reply.
public void test_consecutive_replies() {
    var big = make_config(3000);
    var small = make_config(2);

    try {
        var wm = new FakeWm({ config_reply(big), config_reply(small) });
        Environment.set_variable("I3SOCK", wm.socket_path, true);
        var client = new Ilia.IPCClient("i3");
        assert(client.getConfig().config == big);
        assert(client.getConfig().config == small);
        wm.join();
    } catch (GLib.Error e) {
        error("getConfig failed: %s", e.message);
    }
}

// Under sway the socket is read from SWAYSOCK, which may be the only one set
public void test_sway_socket() {
    var config = make_config(2);

    try {
        var wm = new FakeWm({ config_reply(config) });
        Environment.unset_variable("I3SOCK");
        Environment.set_variable("SWAYSOCK", wm.socket_path, true);
        var reply = new Ilia.IPCClient("sway").getConfig();
        wm.join();
        // followed by the included files, none here
        assert(reply.config.has_prefix(config));
    } catch (GLib.Error e) {
        error("getConfig failed: %s", e.message);
    }
}

// No socket for the window manager is an error, not a crash
public void test_missing_socket() {
    Environment.unset_variable("I3SOCK");
    Environment.unset_variable("SWAYSOCK");

    try {
        new Ilia.IPCClient("i3");
        assert_not_reached();
    } catch (GLib.Error e) {
        assert(e is IOError.NOT_FOUND);
    }
}

// A command reaches the window manager as one RUN_COMMAND request, unchanged:
// quotes, criteria and repeated spaces inside quotes are not touched.
public void test_run_command() {
    string command = "[con_id=\"__focused__\"] exec \"swaynag -m 'Really  quit?' -b 'Yes' 'swaymsg exit'\"";

    try {
        var wm = new FakeWm({ "[{\"success\":true}]" });
        Environment.set_variable("I3SOCK", wm.socket_path, true);
        new Ilia.IPCClient("i3").runCommand(command);
        wm.join();
        assert(wm.requests.length == 1);
        assert(wm.requests[0] == command);
    } catch (GLib.Error e) {
        error("runCommand failed: %s", e.message);
    }
}

// A command the window manager rejects is reported as an error
public void test_run_command_failure() {
    try {
        var wm = new FakeWm({ "[{\"success\":false,\"error\":\"Unknown command\"}]" });
        Environment.set_variable("I3SOCK", wm.socket_path, true);
        try {
            new Ilia.IPCClient("i3").runCommand("no-such-command");
            assert_not_reached();
        } catch (Ilia.WM_ERROR e) {
            assert(e.message.contains("Unknown command"));
        }
        wm.join();
    } catch (GLib.Error e) {
        error("runCommand failed: %s", e.message);
    }
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/i3ipc/large_config_reply", test_large_config_reply);
    Test.add_func("/i3ipc/consecutive_replies", test_consecutive_replies);
    Test.add_func("/i3ipc/sway_socket", test_sway_socket);
    Test.add_func("/i3ipc/missing_socket", test_missing_socket);
    Test.add_func("/i3ipc/run_command", test_run_command);
    Test.add_func("/i3ipc/run_command_failure", test_run_command_failure);

    return Test.run();
}
