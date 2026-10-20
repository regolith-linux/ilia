using GLib;

// Deterministic tests for textlist input reading and filtering on large lists (ilia#32).

string[] read_lines(string data, size_t chunk_size) {
    string[] lines = {};
    var stream = new MemoryInputStream.from_data(data.data);
    var reader = new Ilia.LineReader(stream, chunk_size);
    reader.lines_read.connect((batch) => {
        foreach (var line in batch) lines += line;
    });
    var loop = new MainLoop();
    bool finished = false;
    reader.finished.connect(() => finished = true);
    reader.read_all.begin((obj, res) => {
        reader.read_all.end(res);
        loop.quit();
    });
    loop.run();
    assert (finished && reader.done);
    return lines;
}

// Lines as FileStream.read_line() gave them, whatever the chunk boundaries
void test_line_reader() {
    foreach (size_t chunk in new size_t[] { 1, 2, 3, 7, 64 * 1024 }) {
        assert (string.joinv("|", read_lines("alpha\nbeta\n\nlast", chunk)) == "alpha|beta||last");
        assert (string.joinv("|", read_lines("a\nb\n", chunk)) == "a|b");
        assert (read_lines("", chunk).length == 0);
        var one_empty = read_lines("\n", chunk);
        assert (one_empty.length == 1 && one_empty[0] == "");
        assert (string.joinv("|", read_lines("dos\r\nline\r\n", chunk)) == "dos\r|line\r");
        // multi-byte characters split across chunks
        assert (string.joinv("|", read_lines("é\nüñ\n日本語", chunk)) == "é|üñ|日本語");
    }
}

// The words used for filtering many rows give the same answer as matches_all_words()
void test_contains_all_words_matches_matches_all_words() {
    string[] fields = { "foo bar baz", "Foo --Baz", "Capture d'écran", "", "ÉCRAN", "tab\there" };
    string[] queries = { "", "  ", "foo", "BAZ foo", "foo qux", "écran", "ÉCRAN capture", "\there ", "o b" };
    foreach (var query in queries) {
        var words = Ilia.query_words(query);
        foreach (var field in fields)
            assert (Ilia.contains_all_words(field.down(), words) == Ilia.matches_all_words(query, { field }));
    }
}

class Recorder {
    public int resets = 0;
    public string[] appended = {};

    public Recorder (Ilia.TextFilter filter) {
        filter.reset.connect(() => resets++);
        filter.appended.connect((first, count) => {
            for (int i = first; i < first + count; ++i) appended += filter.get_visible_line(i);
        });
    }
}

string visible_lines(Ilia.TextFilter filter) {
    string[] lines = {};
    for (int i = 0; i < filter.visible_count; ++i) lines += filter.get_visible_line(i);
    return string.joinv("|", lines);
}

string expected_lines(string[] lines, string query) {
    string[] result = {};
    foreach (var line in lines)
        if (Ilia.matches_all_words(query, { line })) result += line;
    return string.joinv("|", result);
}

string[] generate(int n, uint32 seed) {
    var rand = new Rand.with_seed(seed);
    string[] syllables = { "al", "pha", "bra", "vo", "char", "lie", "del", "ta", "é", "Ü", " ", "-" };
    string[] lines = new string[n];
    for (int i = 0; i < n; ++i) {
        var sb = new StringBuilder();
        int len = rand.int_range(1, 6);
        for (int j = 0; j < len; ++j) sb.append(syllables[rand.int_range(0, syllables.length)]);
        lines[i] = sb.str;
    }
    return lines;
}

// Same rows, in input order, as filtering every line with matches_all_words(), across typing,
// deleting and lines that arrive while filtering
void test_filter_equivalence() {
    var lines = generate(5000, 42);
    var filter = new Ilia.TextFilter();
    filter.add_lines(lines[0 : 2000]);
    filter.finish();
    assert (visible_lines(filter) == string.joinv("|", lines[0 : 2000]));

    string[] queries = { "a", "al", "alp", "alph", "alpha", "alph", "al", "", "ta del", "ta de", "é", "éü", "ü al", "zzz", "" };
    int added = 2000;
    foreach (var query in queries) {
        filter.set_query(query);
        filter.step(300); // part of the work, then more lines arrive mid-filter
        if (added < lines.length) {
            filter.add_lines(lines[added : added + 250]);
            added += 250;
        }
        filter.finish();
        assert (visible_lines(filter) == expected_lines(lines[0 : added], query));
    }
}

// One step never checks more rows than its budget, and typing never filters synchronously
void test_responsiveness_bound() {
    var lines = generate(100000, 7);
    var filter = new Ilia.TextFilter();
    var rec = new Recorder(filter);
    filter.add_lines(lines);
    filter.finish();
    int resets = rec.resets;

    var before = filter.rows_checked;
    filter.set_query("al");
    assert (filter.rows_checked == before); // set_query does no filtering itself
    assert (filter.busy);

    int steps = 0;
    while (true) {
        var start = filter.rows_checked;
        bool more = filter.step(2048);
        assert (filter.rows_checked - start <= 2048);
        steps++;
        if (!more) break;
        assert (rec.resets == resets); // nothing shown until the query's result is complete
    }
    assert (steps == (100000 + 2047) / 2048);
    assert (rec.resets == resets + 1);
}

// A new query drops the unfinished work for the previous one: its partial result is never shown
void test_new_query_drops_unfinished_work() {
    var lines = generate(20000, 3);
    var filter = new Ilia.TextFilter();
    var rec = new Recorder(filter);
    filter.add_lines(lines);
    filter.finish();
    int resets = rec.resets;

    filter.set_query("alpha");
    filter.step(5000);
    filter.set_query("bravo");
    filter.finish();
    assert (rec.resets == resets + 1);
    assert (visible_lines(filter) == expected_lines(lines, "bravo"));
}

// Typing more of a word only re-checks the rows that matched before
void test_narrowing_checks_fewer_rows() {
    var lines = generate(20000, 11);
    var filter = new Ilia.TextFilter();
    filter.add_lines(lines);
    filter.set_query("al");
    filter.finish();
    int matched = filter.visible_count;
    assert (matched > 0 && matched < 20000);

    var before = filter.rows_checked;
    filter.set_query("alp");
    filter.finish();
    assert (filter.rows_checked - before == matched);
    assert (visible_lines(filter) == expected_lines(lines, "alp"));

    // Deleting a character widens the query: every row again
    before = filter.rows_checked;
    filter.set_query("al");
    filter.finish();
    assert (filter.rows_checked - before == 20000);
}

// Lines read later are added at the end when they match, in input order
void test_appended_lines() {
    var filter = new Ilia.TextFilter();
    var rec = new Recorder(filter);
    filter.set_query("needle");
    filter.add_lines({ "hay", "needle 1", "hay" });
    filter.finish();
    assert (visible_lines(filter) == "needle 1");

    filter.add_lines({ "needle 2", "hay", "Needle 3" });
    filter.finish();
    assert (visible_lines(filter) == "needle 1|needle 2|Needle 3");
    assert (string.joinv("|", rec.appended) == "needle 2|Needle 3");

    // Lines not yet checked when the query narrows are checked too
    filter.add_lines({ "needle 4x", "needle 5" });
    filter.set_query("needle 4");
    filter.finish();
    assert (visible_lines(filter) == "needle 4x");
}

public int main(string[] args) {
    Test.init(ref args);

    Test.add_func("/textlist/line_reader", test_line_reader);
    Test.add_func("/textlist/contains_all_words", test_contains_all_words_matches_matches_all_words);
    Test.add_func("/textlist/filter_equivalence", test_filter_equivalence);
    Test.add_func("/textlist/responsiveness_bound", test_responsiveness_bound);
    Test.add_func("/textlist/new_query_drops_unfinished_work", test_new_query_drops_unfinished_work);
    Test.add_func("/textlist/narrowing_checks_fewer_rows", test_narrowing_checks_fewer_rows);
    Test.add_func("/textlist/appended_lines", test_appended_lines);

    return Test.run();
}
