using GLib;

// Serve one canned reply to a "list" request, as the rofication daemon does.
class FakeDaemon {
    public string socket_path;
    private Socket listener;
    private string payload;
    private Thread<void> thread;

    public FakeDaemon (string payload) throws GLib.Error {
        this.payload = payload;
        var dir = DirUtils.make_tmp("ilia-rofication-test-XXXXXX");
        socket_path = Path.build_filename(dir, "daemon.sock");
        listener = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
        listener.bind(new UnixSocketAddress(socket_path), true);
        listener.listen();
        thread = new Thread<void>("fake-rofication", serve);
    }

    private void serve() {
        try {
            var conn = listener.accept();
            var buffer = new uint8[256];
            conn.receive(buffer); // "list\n"
            conn.send(payload.data);
            conn.close();
        } catch (GLib.Error e) {
            error("fake daemon: %s", e.message);
        }
    }

    public void join() {
        thread.join();
    }
}

string ids_in_order(List<Ilia.NotificationDesc> notifications) {
    var ids = new StringBuilder();
    foreach (var n in notifications) {
        if (ids.len > 0) ids.append(" ");
        ids.append(n.id.to_string());
    }
    return ids.str;
}

// The daemon lists notifications in the order they were added. Shown newest first:
// by timestamp, then by id; entries without a timestamp (saved by older daemons) last.
void test_newest_first() {
    var payload = """[
        {"id": 1, "summary": "replaced later", "body": "", "application": "Mid", "icon": "", "urgency": 1, "timestamp": 1760000300.5},
        {"id": 2, "summary": "a", "body": "", "application": "Alpha", "icon": "", "urgency": 1, "timestamp": 1760000100.25},
        {"id": 3, "summary": "b", "body": "", "application": "Zeta", "icon": "", "urgency": 1, "timestamp": 1760000200},
        {"id": 4, "summary": "same time as 3", "body": "", "application": "Beta", "icon": "", "urgency": 1, "timestamp": 1760000200.0},
        {"id": 5, "summary": "old daemon", "body": "", "application": "Old", "icon": "", "urgency": 1, "timestamp": ""},
        {"id": 6, "summary": "older daemon", "body": "", "application": "Older", "icon": "", "urgency": 1}
    ]""";

    try {
        var daemon = new FakeDaemon(payload);
        var client = new Ilia.RoficationClient(daemon.socket_path);
        var notifications = client.get_notifications();
        daemon.join();

        assert (ids_in_order(notifications) == "1 2 3 4 5 6"); // as listed by the daemon

        notifications.sort(Ilia.compare_notifications_newest_first);
        assert (ids_in_order(notifications) == "1 4 3 2 6 5");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/rofication/newest_first", test_newest_first);

    return Test.run();
}
