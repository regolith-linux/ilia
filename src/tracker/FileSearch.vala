namespace Ilia {
    /**
     * A file found by a file search
     */
    public class FileHit : GLib.Object {
        public string path { get; construct; }
        public string title { get; construct; }
        public string mime_type { get; construct; }

        public FileHit (string path, string title, string mime_type) {
            Object(path: path, title: title, mime_type: mime_type);
        }
    }

    /**
     * Runs one file search. TrackerFileSearch for the page; a fake in tests.
     */
    public interface FileSearchBackend : GLib.Object {
        public abstract async GenericArray<FileHit> search(string text, Cancellable cancellable) throws GLib.Error;
    }

    /**
     * Runs a callback once after a delay. MainLoopScheduler for the page; a fake clock in tests.
     */
    public interface Scheduler : GLib.Object {
        public abstract uint schedule(uint delay_ms, owned SourceFunc func);
        public abstract void cancel(uint id);
    }

    public class MainLoopScheduler : GLib.Object, Scheduler {
        public uint schedule(uint delay_ms, owned SourceFunc func) {
            return Timeout.add(delay_ms, (owned) func);
        }

        public void cancel(uint id) {
            Source.remove(id);
        }
    }

    /**
     * Search as the user types, without blocking the UI (ilia#37, ilia#85)
     *
     * - A search starts once the text has not changed for DEBOUNCE_MS, so a burst of
     *   keystrokes costs one search.
     * - Searches run asynchronously. A new search cancels the one still running, and only
     *   the results for the newest text are emitted: results of a search that was
     *   superseded are dropped even if they arrive.
     * - Enter while a search is waiting or running is remembered: the search runs at once
     *   and its results are emitted with activate set, so the caller opens the first hit
     *   for the text that was typed, not a hit left over from earlier text.
     */
    public class SearchController : GLib.Object {
        public const uint DEBOUNCE_MS = 150;
        // Shorter texts are not searched, and leave the list as it is
        public const int MIN_TEXT_LENGTH = 3;

        /**
         * Results for the current text
         *
         * @param activate True if Enter was pressed while the search was waiting or running
         */
        public signal void results(string text, GenericArray<FileHit> hits, bool activate);

        private FileSearchBackend backend;
        private Scheduler scheduler;

        // Text waiting for the debounce delay, or null
        private string ? pending_text = null;
        private uint timer_id = 0;
        // Counts searches started; a result is used only if no newer search has started since
        private uint generation = 0;
        private Cancellable ? running = null;
        private bool activate_when_ready = false;

        public SearchController (FileSearchBackend backend, Scheduler scheduler) {
            this.backend = backend;
            this.scheduler = scheduler;
        }

        /**
         * True while a search is waiting for the debounce delay or running
         */
        public bool busy {
            get {
                return timer_id != 0 || running != null;
            }
        }

        /**
         * Call on every change of the search text. Never blocks.
         */
        public void text_changed(string text) {
            activate_when_ready = false;
            stop();

            if (text.char_count() < MIN_TEXT_LENGTH)
                return;

            pending_text = text;
            timer_id = scheduler.schedule(DEBOUNCE_MS, () => {
                timer_id = 0;
                start_pending();
                return false;
            });
        }

        /**
         * Call when the user presses Enter
         *
         * @return true if the results shown are not yet those for the current text; they will be
         *         emitted with activate set. false if the caller should act on the results shown.
         */
        public bool activate() {
            if (timer_id != 0) {
                scheduler.cancel(timer_id);
                timer_id = 0;
                start_pending();
            }

            if (running == null)
                return false;

            activate_when_ready = true;
            return true;
        }

        // Cancel the waiting and the running search; their results will not be emitted
        private void stop() {
            if (timer_id != 0) {
                scheduler.cancel(timer_id);
                timer_id = 0;
            }
            pending_text = null;

            if (running != null) {
                running.cancel();
                running = null;
            }
            generation++;
        }

        private void start_pending() {
            string text = pending_text;
            pending_text = null;

            generation++;
            uint search_generation = generation;
            var cancellable = new Cancellable();
            running = cancellable;

            backend.search.begin(text, cancellable, (obj, res) => {
                GenericArray<FileHit> hits;
                try {
                    hits = backend.search.end(res);
                } catch (IOError.CANCELLED e) {
                    return;
                } catch (GLib.Error e) {
                    stderr.printf("File search failed: %s\n", e.message);
                    hits = new GenericArray<FileHit>();
                }

                if (search_generation != generation || cancellable.is_cancelled())
                    return; // superseded

                running = null;
                bool activate = activate_when_ready;
                activate_when_ready = false;
                results(text, hits, activate);
            });
        }
    }

    /**
     * File search with Tracker (localsearch) full-text search, through SparqlLibrary
     */
    public class TrackerFileSearch : GLib.Object, FileSearchBackend {
        private const string BUS_NAME = "org.freedesktop.Tracker3.Miner.Files";
        // The search text is bound as a parameter, so quotes in it cannot break the query
        private const string QUERY = "SELECT DISTINCT nie:url(?f) nie:title(?f) nie:mimeType(?f) WHERE { ?f fts:match ~text } ORDER BY DESC(fts:rank(?f)) LIMIT %d";
        // Most hits shown for one search
        public const int MAX_HITS = 100;

        // One connection (a TrackerSparqlConnection) for all searches
        private GLib.Object ? connection = null;
        private bool connecting = false;
        private GLib.Error ? connect_error = null;
        private signal void connect_done();

        private async GLib.Object get_connection(SparqlLibrary sparql) throws GLib.Error {
            if (connection == null && connecting) { // another search is opening it
                ulong handler = connect_done.connect(() => get_connection.callback());
                yield;
                disconnect(handler);
            }

            if (connection == null) {
                connecting = true;
                connect_error = null;
                try {
                    connection = yield sparql.connection_bus_new_async(BUS_NAME, null);
                } catch (GLib.Error e) {
                    connect_error = e;
                }
                connecting = false;
                connect_done();
            }

            if (connection == null)
                throw connect_error ?? new IOError.FAILED("No connection to %s", BUS_NAME);
            return connection;
        }

        public async GenericArray<FileHit> search(string text, Cancellable cancellable) throws GLib.Error {
            unowned var sparql = SparqlLibrary.get_default();
            var conn = yield get_connection(sparql);

            cancellable.set_error_if_cancelled();

            var statement = sparql.connection_query_statement(conn, QUERY.printf(MAX_HITS), cancellable);
            if (statement == null)
                throw new IOError.FAILED("Could not prepare the file search query");
            sparql.statement_bind_string(statement, "text", text);
            var cursor = yield sparql.statement_execute_async(statement, cancellable);

            var hits = new GenericArray<FileHit>();
            try {
                long length;
                while (hits.length < MAX_HITS) {
                    if (!(yield sparql.cursor_next_async(cursor, cancellable))) break;

                    var uri = sparql.cursor_get_string(cursor, 0, out length);
                    if (uri == null) continue;

                    string path;
                    try {
                        path = GLib.Filename.from_uri(uri);
                    } catch (ConvertError e) {
                        continue; // not a local file
                    }

                    var title = sparql.cursor_get_string(cursor, 1, out length) ?? Path.get_basename(path);
                    var mime_type = sparql.cursor_get_string(cursor, 2, out length) ?? "application/octet-stream";
                    hits.add(new FileHit(path, title, mime_type));
                }
            } finally {
                sparql.cursor_close(cursor);
            }

            return hits;
        }
    }
}
