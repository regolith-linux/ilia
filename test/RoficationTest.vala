using GLib;

// Serve one connection as the rofication daemon does: read the request line, then
// send the reply in chunks, delay_ms apart. With hold_open, the connection then stays
// open until the client closes it.
class FakeDaemon {
    public string socket_path;
    public string request = "";
    private Socket listener;
    private string[] chunks;
    private uint delay_ms;
    private bool hold_open;
    private Thread<void> thread;

    public FakeDaemon (string payload) throws GLib.Error {
        this.with_chunks({ payload }, 0, false);
    }

    public FakeDaemon.with_chunks(string[] chunks, uint delay_ms, bool hold_open) throws GLib.Error {
        this.chunks = chunks;
        this.delay_ms = delay_ms;
        this.hold_open = hold_open;
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
            ssize_t len = conn.receive(buffer);
            request = ((string) buffer).substring(0, (long) len);
            foreach (var chunk in chunks) {
                if (delay_ms > 0)
                    Thread.usleep(delay_ms * 1000);
                conn.send(chunk.data);
            }
            // Wait for the client to close its end
            while (hold_open && len > 0)
                len = conn.receive(buffer);
            conn.close();
        } catch (GLib.Error e) {
            debug("fake daemon: %s", e.message); // the client went away while chunks were left
        }
    }

    public void join() {
        thread.join();
    }
}

// Run get_notifications() to its end
Ilia.NotificationList fetch(string socket_path, Cancellable ? cancellable = null) throws GLib.Error {
    var loop = new MainLoop();
    var client = new Ilia.RoficationClient(socket_path);
    Ilia.NotificationList ? result = null;
    GLib.Error ? failure = null;
    client.get_notifications.begin(cancellable, (obj, res) => {
        try {
            result = client.get_notifications.end(res);
        } catch (GLib.Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    if (failure != null)
        throw failure;
    return result;
}

Ilia.NotificationList parse(string reply) throws GLib.Error {
    return Ilia.RoficationClient.parse_notifications(reply, reply.length);
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
        var list = fetch(daemon.socket_path);
        daemon.join();
        unowned List<Ilia.NotificationDesc> notifications = list.notifications;

        assert(daemon.request == "list\n");
        assert(ids_in_order(notifications) == "1 2 3 4 5 6");  // as listed by the daemon

        list.notifications.sort(Ilia.compare_notifications_newest_first);
        assert(ids_in_order(list.notifications) == "1 4 3 2 6 5");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// Missing, null and mistyped members read as empty instead of ending ilia
void test_incomplete_entries() {
    try {
        var list = parse("""[
            {"id": 7},
            {"id": 8, "summary": null, "body": 5, "application": ["x"], "icon": {}, "urgency": "high", "timestamp": "soon"},
            {"id": 9, "summary": "Tea", "body": "Ready", "application": "tea-timer", "icon": "dialog-error", "urgency": 2, "timestamp": 1700000100.25}
        ]""");
        assert(list.unreadable == 0);
        assert(list.notifications.length() == 3);

        for (uint i = 0; i < 2; i++) {
            var n = list.notifications.nth_data(i);
            assert(n.summary == "" && n.body == "" && n.application == "" && n.icon == "");
            assert(n.urgency == 0 && n.timestamp == 0);
        }
        var full = list.notifications.nth_data(2);
        assert(full.summary == "Tea" && full.body == "Ready" && full.application == "tea-timer");
        assert(full.icon == "dialog-error" && full.urgency == 2 && full.timestamp == 1700000100.25);
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// Only a positive integer that fits int64 names a notification; anything else reads as 0
void test_ids() {
    try {
        var list = parse("""[
            {"id": 1}, {"id": 9223372036854775806},
            {}, {"id": 0}, {"id": -3}, {"id": "7"}, {"id": 7.5}, {"id": 7.0}, {"id": 7e0}, {"id": true}, {"id": null},
            {"id": 9223372036854775807}, {"id": 9223372036854775808}, {"id": 18446744073709551623}
        ]""");
        assert(ids_in_order(list.notifications) == "1 9223372036854775806 0 0 0 0 0 0 0 0 0 0 0 0");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// Elements that are not objects are left out and counted; the rest still load
void test_unreadable_elements() {
    try {
        var list = parse("""[3, {"id": 4, "summary": "kept"}, "text", null, [], true, {"id": 5}]""");
        assert(list.unreadable == 5);
        assert(ids_in_order(list.notifications) == "4 5");

        list = parse("[]");
        assert(list.unreadable == 0 && list.notifications.length() == 0);
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// A reply that is not a JSON array fails to load instead of looking like an empty list
void test_rejected_replies() {
    string[] not_arrays = { "", " ", "{}", "null", "\"list\"", "42" };
    foreach (var reply in not_arrays) {
        try {
            parse(reply);
            error("loaded: '%s'", reply);
        } catch (IOError.INVALID_DATA e) {
        } catch (GLib.Error e) {
            error("'%s': %s", reply, e.message);
        }
    }

    string[] broken = { "[", "[{\"id\": 1}", "[1,]", "[1] x" };
    foreach (var reply in broken) {
        try {
            parse(reply);
            error("loaded: '%s'", reply);
        } catch (Json.ParserError e) {
        } catch (GLib.Error e) {
            error("'%s': %s", reply, e.message);
        }
    }

    try {
        Ilia.RoficationClient.parse_notifications("[\"\xff\"]", 5);
        error("loaded a reply that is not UTF-8");
    } catch (IOError.INVALID_DATA e) {
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// A reply that comes in pieces, with pauses below the idle limit, loads
void test_reply_in_pieces() {
    try {
        var daemon = new FakeDaemon.with_chunks({ "[{\"id\": 3, ", "\"summary\": \"slow\"}", "]" }, 300, false);
        var list = fetch(daemon.socket_path);
        daemon.join();
        assert(ids_in_order(list.notifications) == "3");
        assert(list.notifications.nth_data(0).summary == "slow");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

void assert_times_out(FakeDaemon daemon, int64 min_ms, int64 max_ms, string reason) {
    int64 start = get_monotonic_time();
    try {
        fetch(daemon.socket_path);
        error("loaded a reply that never ended");
    } catch (IOError.TIMED_OUT e) {
        int64 elapsed_ms = (get_monotonic_time() - start) / 1000;
        assert(elapsed_ms >= min_ms && elapsed_ms <= max_ms);
        assert("timed out" in e.message && reason in e.message);
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
    daemon.join();
}

// A daemon that takes the request and stays silent fails after two seconds
void test_silent_daemon_times_out() {
    try {
        assert_times_out(new FakeDaemon.with_chunks({}, 0, true), 1900, 3500, "nothing came");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// A daemon that sends a byte now and then fails five seconds after the request
void test_dribbling_daemon_times_out() {
    string[] bytes = {};
    for (int i = 0; i < 40; i++)
        bytes += " ";
    try {
        assert_times_out(new FakeDaemon.with_chunks(bytes, 400, true), 4900, 6500, "not complete");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// A newer request cancels the one in progress
void test_cancelled() {
    try {
        var daemon = new FakeDaemon.with_chunks({}, 0, true);
        var cancellable = new Cancellable();
        Timeout.add(200, () => {
            cancellable.cancel();
            return Source.REMOVE;
        });
        try {
            fetch(daemon.socket_path, cancellable);
            error("loaded after cancel");
        } catch (IOError.CANCELLED e) {
        }
        daemon.join();
    } catch (GLib.Error e) {
        error("%s", e.message);
    }
}

// No daemon: the load fails with the reason
void test_no_daemon() {
    try {
        fetch("/nonexistent/rofi_notification_daemon");
        error("loaded without a daemon");
    } catch (GLib.Error e) {
        assert(e.message.length > 0);
    }
}

// Removal requests are one line each, written in full
void test_delete_requests() {
    try {
        var daemon = new FakeDaemon.with_chunks({}, 0, false);
        new Ilia.RoficationClient(daemon.socket_path).delete_notification_by_id(9223372036854775806);
        daemon.join();
        assert(daemon.request == "del:9223372036854775806\n");

        daemon = new FakeDaemon.with_chunks({}, 0, false);
        new Ilia.RoficationClient(daemon.socket_path).delete_notifications_by_ids({ "4", "12", "3" });
        daemon.join();
        assert(daemon.request == "delm:4,12,3\n");
    } catch (GLib.Error e) {
        error("%s", e.message);
    }

    try {
        new Ilia.RoficationClient("/nonexistent/rofi_notification_daemon").delete_notification_by_id(4);
        error("sent without a daemon");
    } catch (GLib.Error e) {
    }
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/rofication/newest_first", test_newest_first);
    Test.add_func("/rofication/incomplete_entries", test_incomplete_entries);
    Test.add_func("/rofication/ids", test_ids);
    Test.add_func("/rofication/unreadable_elements", test_unreadable_elements);
    Test.add_func("/rofication/rejected_replies", test_rejected_replies);
    Test.add_func("/rofication/reply_in_pieces", test_reply_in_pieces);
    Test.add_func("/rofication/silent_daemon_times_out", test_silent_daemon_times_out);
    Test.add_func("/rofication/dribbling_daemon_times_out", test_dribbling_daemon_times_out);
    Test.add_func("/rofication/cancelled", test_cancelled);
    Test.add_func("/rofication/no_daemon", test_no_daemon);
    Test.add_func("/rofication/delete_requests", test_delete_requests);

    return Test.run();
}
