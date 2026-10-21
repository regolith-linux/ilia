using GLib;

// Deterministic tests for the debounced, asynchronous file search (ilia#37, ilia#85).
// A fake clock replaces the main loop timer and a fake backend completes searches
// only when the test says so, in any order.

class FakeClock : Object, Ilia.Scheduler {
    private struct Timer {
        uint id;
        uint64 due;
    }

    public uint64 now = 0;
    private uint next_id = 1;
    private Timer[] timers = {};
    private HashTable<uint, SourceFuncHolder> funcs = new HashTable<uint, SourceFuncHolder>(direct_hash, direct_equal);

    private class SourceFuncHolder {
        public SourceFunc func;
        public SourceFuncHolder (owned SourceFunc func) {
            this.func = (owned) func;
        }
    }

    public uint schedule(uint delay_ms, owned SourceFunc func) {
        uint id = next_id++;
        timers += Timer() { id = id, due = now + delay_ms };
        funcs.insert(id, new SourceFuncHolder((owned) func));
        return id;
    }

    public void cancel(uint id) {
        assert (funcs.contains(id)); // like Source.remove(), cancelling an unknown timer is a bug
        funcs.remove(id);
    }

    public int pending() {
        return (int) funcs.size();
    }

    public void advance(uint ms) {
        now += ms;
        foreach (var t in timers) {
            if (t.due <= now && funcs.contains(t.id)) {
                var holder = funcs.get(t.id);
                funcs.remove(t.id);
                holder.func();
            }
        }
    }
}

class Request : Object {
    public string text;
    public Cancellable cancellable;
    public SourceFunc resume;
    public GenericArray<Ilia.FileHit> ? hits = null;
    public bool fail = false;
    public bool done = false;
}

class FakeBackend : Object, Ilia.FileSearchBackend {
    public GenericArray<Request> requests = new GenericArray<Request>();
    // Like a backend that has the answer before it notices the cancellation
    public bool ignore_cancel = false;

    public async GenericArray<Ilia.FileHit> search(string text, Cancellable cancellable) throws GLib.Error {
        var request = new Request();
        request.text = text;
        request.cancellable = cancellable;
        request.resume = search.callback;
        requests.add(request);

        if (!ignore_cancel) {
            cancellable.cancelled.connect(() => {
                if (!request.done) {
                    request.done = true;
                    Idle.add((owned) request.resume);
                }
            });
        }
        yield;

        if (!ignore_cancel && cancellable.is_cancelled())
            throw new IOError.CANCELLED("cancelled");
        if (request.fail)
            throw new IOError.FAILED("index unavailable");
        return request.hits;
    }

    public void complete(int index, string[] names) {
        var request = requests[index];
        assert (!request.done);
        request.hits = new GenericArray<Ilia.FileHit>();
        foreach (var name in names)
            request.hits.add(new Ilia.FileHit("/files/" + name, name, "text/plain"));
        request.done = true;
        request.resume();
    }

    public void fail(int index) {
        var request = requests[index];
        request.fail = true;
        request.done = true;
        request.resume();
    }
}

class Emitted {
    public string text;
    public string names;
    public bool activate;
}

class Fixture {
    public FakeClock clock = new FakeClock();
    public FakeBackend backend = new FakeBackend();
    public Ilia.SearchController search;
    public GenericArray<Emitted> emitted = new GenericArray<Emitted>();

    public Fixture () {
        search = new Ilia.SearchController(backend, clock);
        search.results.connect((text, hits, activate) => {
            var e = new Emitted();
            e.text = text;
            string[] names = {};
            foreach (var hit in hits) names += hit.title;
            e.names = string.joinv(",", names);
            e.activate = activate;
            emitted.add(e);
        });
    }

    // Let completed async calls deliver their results
    public void drain() {
        while (MainContext.default().iteration(false)) {}
    }

    public void type(string text, uint ms_per_key) {
        for (int i = 1; i <= text.char_count(); ++i) {
            search.text_changed(text.substring(0, text.index_of_nth_char(i)));
            clock.advance(ms_per_key);
            drain();
        }
    }
}

const uint DEBOUNCE = Ilia.SearchController.DEBOUNCE_MS;

// A burst of keystrokes costs one search, for the final text, after the debounce delay
void test_debounce() {
    var f = new Fixture();
    f.type("report", 50); // a key every 50 ms
    assert (f.backend.requests.length == 0);

    f.clock.advance(DEBOUNCE - 50 - 1);
    assert (f.backend.requests.length == 0);
    f.clock.advance(1);
    assert (f.backend.requests.length == 1);
    assert (f.backend.requests[0].text == "report");

    f.backend.complete(0, { "report-1.txt", "report-2.txt" });
    f.drain();
    assert (f.emitted.length == 1);
    assert (f.emitted[0].text == "report");
    assert (f.emitted[0].names == "report-1.txt,report-2.txt");
    assert (!f.emitted[0].activate);
}

// Typing never runs a search synchronously; slow typing gives at most one search per pause
void test_responsiveness_bound() {
    var f = new Fixture();
    string text = "abcdefghijklmnopqrst"; // 20 keys
    for (int i = 1; i <= text.length; ++i) {
        f.search.text_changed(text.substring(0, i));
        assert (f.backend.requests.length <= i); // nothing extra started from inside text_changed
        f.clock.advance(DEBOUNCE + 10);
        f.drain();
    }
    // Keys 3..20 each paused long enough: 18 searches, each but the last cancelled by the next key
    assert (f.backend.requests.length == 18);
    for (int i = 0; i < 17; ++i)
        assert (f.backend.requests[i].cancellable.is_cancelled());
    assert (!f.backend.requests[17].cancellable.is_cancelled());
    assert (f.emitted.length == 0); // cancelled searches emit nothing
}

// Too short a text is not searched and cancels a waiting or running search
void test_short_text() {
    var f = new Fixture();
    f.type("re", 50);
    f.clock.advance(1000);
    assert (f.backend.requests.length == 0);

    f.type("rep", 0);
    f.clock.advance(DEBOUNCE);
    assert (f.backend.requests.length == 1);

    f.search.text_changed("re"); // backspace while searching
    assert (f.backend.requests[0].cancellable.is_cancelled());
    f.drain();
    f.clock.advance(1000);
    assert (f.backend.requests.length == 1);
    assert (f.emitted.length == 0);
    assert (!f.search.busy);
}

// A newer search's results are never replaced by an older search's, whatever the order of
// completion, even when the older search returns hits after it was cancelled
void test_stale_results_dropped() {
    var f = new Fixture();
    f.backend.ignore_cancel = true; // the old search answers anyway
    f.type("zebra", 0);
    f.clock.advance(DEBOUNCE);
    f.search.text_changed("report");
    f.clock.advance(DEBOUNCE);
    assert (f.backend.requests.length == 2);
    assert (f.backend.requests[0].cancellable.is_cancelled());

    f.backend.complete(1, { "report-1.txt" }); // newer first
    f.drain();
    f.backend.complete(0, { "zebra.txt" });    // older last
    f.drain();
    assert (f.emitted.length == 1);
    assert (f.emitted[0].text == "report");
    assert (f.emitted[0].names == "report-1.txt");

    // and in the other order
    f = new Fixture();
    f.backend.ignore_cancel = true;
    f.type("zebra", 0);
    f.clock.advance(DEBOUNCE);
    f.search.text_changed("report");
    f.clock.advance(DEBOUNCE);
    f.backend.complete(0, { "zebra.txt" });
    f.drain();
    assert (f.emitted.length == 0);
    f.backend.complete(1, { "report-1.txt" });
    f.drain();
    assert (f.emitted.length == 1);
    assert (f.emitted[0].names == "report-1.txt");
}

// Cancelled searches end with IOError.CANCELLED and emit nothing
void test_cancellation() {
    var f = new Fixture();
    f.type("zebra", 0);
    f.clock.advance(DEBOUNCE);
    f.search.text_changed("zebras");
    assert (f.backend.requests[0].cancellable.is_cancelled());
    f.drain(); // the backend reacts to the cancellation
    assert (f.backend.requests[0].done);
    assert (f.emitted.length == 0);
    assert (f.clock.pending() == 1); // the new text waits for its debounce
}

// Enter while the debounce is waiting: search at once and activate with its results
void test_enter_while_waiting() {
    var f = new Fixture();
    f.type("zebrafish", 20);
    assert (f.backend.requests.length == 0);
    assert (f.search.activate());
    assert (f.clock.pending() == 0);
    assert (f.backend.requests.length == 1);
    assert (f.backend.requests[0].text == "zebrafish");
    f.backend.complete(0, { "unique-zebrafish.txt" });
    f.drain();
    assert (f.emitted.length == 1);
    assert (f.emitted[0].names == "unique-zebrafish.txt");
    assert (f.emitted[0].activate);
}

// Enter while the search runs: activate with its results, not with what is on screen
void test_enter_while_running() {
    var f = new Fixture();
    f.type("report", 0);
    f.clock.advance(DEBOUNCE);
    f.backend.complete(0, { "report-1.txt" });
    f.drain();
    f.search.text_changed("zebrafish");
    f.clock.advance(DEBOUNCE);
    assert (f.search.activate());
    f.backend.complete(1, { "unique-zebrafish.txt" });
    f.drain();
    assert (f.emitted.length == 2);
    assert (!f.emitted[0].activate);
    assert (f.emitted[1].names == "unique-zebrafish.txt");
    assert (f.emitted[1].activate);
}

// Enter when the results on screen are current: the caller opens the selection itself
void test_enter_when_idle() {
    var f = new Fixture();
    assert (!f.search.activate());
    f.type("report", 0);
    f.clock.advance(DEBOUNCE);
    f.backend.complete(0, { "report-1.txt" });
    f.drain();
    assert (!f.search.activate());
    assert (f.backend.requests.length == 1);
}

// Typing after Enter means the user changed their mind: no activation
void test_typing_after_enter_cancels_activation() {
    var f = new Fixture();
    f.type("zebra", 0);
    assert (f.search.activate());
    f.search.text_changed("zebrafish");
    f.clock.advance(DEBOUNCE);
    f.backend.complete(1, { "unique-zebrafish.txt" });
    f.drain();
    assert (f.emitted.length == 1);
    assert (!f.emitted[0].activate);
}

// A failing search clears the list rather than leaving results for other text
void test_backend_error() {
    var f = new Fixture();
    f.type("report", 0);
    f.clock.advance(DEBOUNCE);
    f.backend.fail(0);
    f.drain();
    assert (f.emitted.length == 1);
    assert (f.emitted[0].names == "");
    assert (!f.search.busy);
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/file_search/debounce", test_debounce);
    Test.add_func("/file_search/responsiveness_bound", test_responsiveness_bound);
    Test.add_func("/file_search/short_text", test_short_text);
    Test.add_func("/file_search/stale_results_dropped", test_stale_results_dropped);
    Test.add_func("/file_search/cancellation", test_cancellation);
    Test.add_func("/file_search/enter_while_waiting", test_enter_while_waiting);
    Test.add_func("/file_search/enter_while_running", test_enter_while_running);
    Test.add_func("/file_search/enter_when_idle", test_enter_when_idle);
    Test.add_func("/file_search/typing_after_enter_cancels_activation", test_typing_after_enter_cancels_activation);
    Test.add_func("/file_search/backend_error", test_backend_error);

    return Test.run();
}
