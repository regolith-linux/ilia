namespace Ilia {
    /**
     * The SPARQL client library, loaded when the Files page first searches.
     *
     * tracker 3 ships the library as libtracker-sparql-3.0.so.0. Since 3.8 it is called
     * tinysparql and ships as libtinysparql-3.0.so.0 with the same C functions. Distributions
     * with tinysparql (for example Ubuntu 25.10 and later) no longer have the old library.
     * Loading whichever one is present lets one ilia build run on both, so an ilia package
     * built for an older release stays installable when the system is upgraded.
     */
    class SparqlLibrary {
        // Tried in this order, first in the build's library directory (if known), then by soname.
        private const string[] LIBRARY_NAMES = {
            "libtinysparql-3.0.so.0",
            "libtracker-sparql-3.0.so.0"
        };

        // void tracker_sparql_connection_bus_new_async (const gchar *service_name, const gchar *object_path, GDBusConnection *dbus_connection, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
        [CCode(has_target = false)]
        private delegate void ConnectionBusNewAsyncFunc(string service_name, string ? object_path, GLib.DBusConnection ? dbus_connection, GLib.Cancellable ? cancellable, GLib.AsyncReadyCallback callback);

        // TrackerSparqlConnection *tracker_sparql_connection_bus_new_finish (GAsyncResult *result, GError **error)
        [CCode(has_target = false)]
        private delegate GLib.Object ? ConnectionBusNewFinishFunc(GLib.AsyncResult result) throws GLib.Error;

        // TrackerSparqlStatement *tracker_sparql_connection_query_statement (TrackerSparqlConnection *connection, const gchar *sparql, GCancellable *cancellable, GError **error)
        [CCode(has_target = false)]
        public delegate GLib.Object ? ConnectionQueryStatementFunc(GLib.Object connection, string sparql, GLib.Cancellable ? cancellable) throws GLib.Error;

        // void tracker_sparql_statement_bind_string (TrackerSparqlStatement *stmt, const gchar *name, const gchar *value)
        [CCode(has_target = false)]
        public delegate void StatementBindStringFunc(GLib.Object statement, string name, string value);

        // void tracker_sparql_statement_execute_async (TrackerSparqlStatement *stmt, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
        [CCode(has_target = false)]
        private delegate void StatementExecuteAsyncFunc(GLib.Object statement, GLib.Cancellable ? cancellable, GLib.AsyncReadyCallback callback);

        // TrackerSparqlCursor *tracker_sparql_statement_execute_finish (TrackerSparqlStatement *stmt, GAsyncResult *res, GError **error)
        [CCode(has_target = false)]
        private delegate GLib.Object ? StatementExecuteFinishFunc(GLib.Object statement, GLib.AsyncResult result) throws GLib.Error;

        // void tracker_sparql_cursor_next_async (TrackerSparqlCursor *cursor, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
        [CCode(has_target = false)]
        private delegate void CursorNextAsyncFunc(GLib.Object cursor, GLib.Cancellable ? cancellable, GLib.AsyncReadyCallback callback);

        // gboolean tracker_sparql_cursor_next_finish (TrackerSparqlCursor *cursor, GAsyncResult *res, GError **error)
        [CCode(has_target = false)]
        private delegate bool CursorNextFinishFunc(GLib.Object cursor, GLib.AsyncResult result) throws GLib.Error;

        // const gchar *tracker_sparql_cursor_get_string (TrackerSparqlCursor *cursor, gint column, glong *length)
        [CCode(has_target = false)]
        public delegate unowned string ? CursorGetStringFunc(GLib.Object cursor, int column, out long length);

        // void tracker_sparql_cursor_close (TrackerSparqlCursor *cursor)
        [CCode(has_target = false)]
        public delegate void CursorCloseFunc(GLib.Object cursor);

        private ConnectionBusNewAsyncFunc connection_bus_new_async_func;
        private ConnectionBusNewFinishFunc connection_bus_new_finish_func;
        public ConnectionQueryStatementFunc connection_query_statement;
        public StatementBindStringFunc statement_bind_string;
        private StatementExecuteAsyncFunc statement_execute_async_func;
        private StatementExecuteFinishFunc statement_execute_finish_func;
        private CursorNextAsyncFunc cursor_next_async_func;
        private CursorNextFinishFunc cursor_next_finish_func;
        public CursorGetStringFunc cursor_get_string;
        public CursorCloseFunc cursor_close;

        /**
         * tracker_sparql_connection_bus_new_async() and _finish()
         */
        public async GLib.Object connection_bus_new_async(string service_name, GLib.Cancellable ? cancellable) throws GLib.Error {
            GLib.AsyncResult ? result = null;
            connection_bus_new_async_func(service_name, null, null, cancellable, (source, res) => {
                result = res;
                connection_bus_new_async.callback();
            });
            yield;
            var connection = connection_bus_new_finish_func(result);
            if (connection == null)
                throw new IOError.FAILED("No connection to %s", service_name);
            return connection;
        }

        /**
         * tracker_sparql_statement_execute_async() and _finish()
         */
        public async GLib.Object statement_execute_async(GLib.Object statement, GLib.Cancellable ? cancellable) throws GLib.Error {
            GLib.AsyncResult ? result = null;
            statement_execute_async_func(statement, cancellable, (source, res) => {
                result = res;
                statement_execute_async.callback();
            });
            yield;
            var cursor = statement_execute_finish_func(statement, result);
            if (cursor == null)
                throw new IOError.FAILED("The query returned no cursor");
            return cursor;
        }

        /**
         * tracker_sparql_cursor_next_async() and _finish()
         */
        public async bool cursor_next_async(GLib.Object cursor, GLib.Cancellable ? cancellable) throws GLib.Error {
            GLib.AsyncResult ? result = null;
            cursor_next_async_func(cursor, cancellable, (source, res) => {
                result = res;
                cursor_next_async.callback();
            });
            yield;
            return cursor_next_finish_func(cursor, result);
        }

        private static SparqlLibrary ? instance = null;
        private static string ? load_error = null;

        /**
         * Returns the loaded library, loading it on the first call.
         * Throws IOError.NOT_FOUND if neither library can be loaded.
         */
        public static unowned SparqlLibrary get_default() throws GLib.Error {
            if (instance == null && load_error == null)
                instance = load(out load_error);

            if (instance == null)
                throw new IOError.NOT_FOUND("File search is unavailable: %s", load_error);

            return instance;
        }

        private static SparqlLibrary ? load(out string error) {
            var errors = new StringBuilder();
            error = "";

            if (!GLib.Module.supported()) {
                error = "loading libraries at run time is not supported on this system";
                return null;
            }

            foreach (unowned string library_name in LIBRARY_NAMES) {
                string[] candidates = {};
                if (Constants.SPARQL_LIBDIR != "")
                    candidates += GLib.Path.build_filename(Constants.SPARQL_LIBDIR, library_name);
                candidates += library_name;

                foreach (unowned string candidate in candidates) {
                    var module = GLib.Module.open(candidate, GLib.ModuleFlags.LAZY | GLib.ModuleFlags.LOCAL);
                    if (module == null) {
                        add_error(errors, GLib.Module.error());
                        continue;
                    }

                    void * bus_new_async = lookup(module, "tracker_sparql_connection_bus_new_async", errors);
                    void * bus_new_finish = lookup(module, "tracker_sparql_connection_bus_new_finish", errors);
                    void * query_statement = lookup(module, "tracker_sparql_connection_query_statement", errors);
                    void * bind_string = lookup(module, "tracker_sparql_statement_bind_string", errors);
                    void * execute_async = lookup(module, "tracker_sparql_statement_execute_async", errors);
                    void * execute_finish = lookup(module, "tracker_sparql_statement_execute_finish", errors);
                    void * next_async = lookup(module, "tracker_sparql_cursor_next_async", errors);
                    void * next_finish = lookup(module, "tracker_sparql_cursor_next_finish", errors);
                    void * get_string = lookup(module, "tracker_sparql_cursor_get_string", errors);
                    void * close = lookup(module, "tracker_sparql_cursor_close", errors);
                    if (bus_new_async == null || bus_new_finish == null || query_statement == null || bind_string == null ||
                        execute_async == null || execute_finish == null || next_async == null || next_finish == null ||
                        get_string == null || close == null)
                        continue;

                    var library = new SparqlLibrary();
                    library.connection_bus_new_async_func = (ConnectionBusNewAsyncFunc) bus_new_async;
                    library.connection_bus_new_finish_func = (ConnectionBusNewFinishFunc) bus_new_finish;
                    library.connection_query_statement = (ConnectionQueryStatementFunc) query_statement;
                    library.statement_bind_string = (StatementBindStringFunc) bind_string;
                    library.statement_execute_async_func = (StatementExecuteAsyncFunc) execute_async;
                    library.statement_execute_finish_func = (StatementExecuteFinishFunc) execute_finish;
                    library.cursor_next_async_func = (CursorNextAsyncFunc) next_async;
                    library.cursor_next_finish_func = (CursorNextFinishFunc) next_finish;
                    library.cursor_get_string = (CursorGetStringFunc) get_string;
                    library.cursor_close = (CursorCloseFunc) close;

                    // The function pointers must stay valid for the life of the process.
                    module.make_resident();

                    return library;
                }
            }

            error = "neither libtinysparql-3.0.so.0 nor libtracker-sparql-3.0.so.0 could be loaded (%s)".printf(errors.str);

            return null;
        }

        // Returns the address of a function in the module, or null (and records why)
        private static void * lookup(GLib.Module module, string name, StringBuilder errors) {
            void * symbol = null;

            if (!module.symbol(name, out symbol) || symbol == null) {
                add_error(errors, GLib.Module.error());
                return null;
            }

            return symbol;
        }

        private static void add_error(StringBuilder errors, string message) {
            errors.append_printf("%s%s", errors.len > 0 ? "; " : "", message);
        }
    }
}
