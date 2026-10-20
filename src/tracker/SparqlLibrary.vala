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

        // TrackerSparqlConnection *tracker_sparql_connection_bus_new (const gchar *service_name, const gchar *object_path, GDBusConnection *dbus_connection, GError **error)
        [CCode(has_target = false)]
        public delegate GLib.Object ? ConnectionBusNewFunc(string service_name, string ? object_path, GLib.DBusConnection ? dbus_connection) throws GLib.Error;

        // TrackerSparqlCursor *tracker_sparql_connection_query (TrackerSparqlConnection *connection, const gchar *sparql, GCancellable *cancellable, GError **error)
        [CCode(has_target = false)]
        public delegate GLib.Object ? ConnectionQueryFunc(GLib.Object connection, string sparql, GLib.Cancellable ? cancellable) throws GLib.Error;

        // gboolean tracker_sparql_cursor_next (TrackerSparqlCursor *cursor, GCancellable *cancellable, GError **error)
        [CCode(has_target = false)]
        public delegate bool CursorNextFunc(GLib.Object cursor, GLib.Cancellable ? cancellable) throws GLib.Error;

        // const gchar *tracker_sparql_cursor_get_string (TrackerSparqlCursor *cursor, gint column, glong *length)
        [CCode(has_target = false)]
        public delegate unowned string ? CursorGetStringFunc(GLib.Object cursor, int column, out long length);

        public ConnectionBusNewFunc connection_bus_new;
        public ConnectionQueryFunc connection_query;
        public CursorNextFunc cursor_next;
        public CursorGetStringFunc cursor_get_string;

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

                    void * bus_new = lookup(module, "tracker_sparql_connection_bus_new", errors);
                    void * query = lookup(module, "tracker_sparql_connection_query", errors);
                    void * next = lookup(module, "tracker_sparql_cursor_next", errors);
                    void * get_string = lookup(module, "tracker_sparql_cursor_get_string", errors);
                    if (bus_new == null || query == null || next == null || get_string == null)
                        continue;

                    var library = new SparqlLibrary();
                    library.connection_bus_new = (ConnectionBusNewFunc) bus_new;
                    library.connection_query = (ConnectionQueryFunc) query;
                    library.cursor_next = (CursorNextFunc) next;
                    library.cursor_get_string = (CursorGetStringFunc) get_string;

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
