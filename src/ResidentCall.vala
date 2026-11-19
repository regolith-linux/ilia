namespace Ilia {
    /*
     * The background copy (resident mode)
     *
     * With the resident-mode setting on, a launcher process stays in the background after
     * its window closes, and later calls in the same session hand their request to it
     * instead of starting GTK, reading the desktop files and building the window from
     * scratch. Each call still runs as its own process: it passes its arguments,
     * environment, working directory, standard output and standard error to the
     * background copy over a socket, waits until the window it asked for is finished,
     * and ends with the status a call shown by its own process would have.
     *
     * The background copy serves one user and one session: the socket is an abstract
     * Unix socket whose name is made from the user id and the variables that name the
     * display and the window manager, and each side checks the other's user id. A call
     * whose launcher-related surroundings (locale, home, data and settings locations)
     * differ is not answered, and the background copy ends, as it would show stale
     * data. A background copy that does not take a request within a second is passed
     * over: the call shows its window itself.
     *
     * This file is the calling side, and what both sides share; it needs no toolkit, as
     * the program only loads GTK (the ui module) for a window it shows itself and for the
     * background copy. ResidentServer.vala is the serving side.
     */

    // Variables that name a session; a background copy answers calls with the same values only
    public const string[] SESSION_VARIABLES = {
        "WAYLAND_DISPLAY", "DISPLAY", "XDG_RUNTIME_DIR", "SWAYSOCK", "I3SOCK"
    };

    // Variables read at startup that decide what the window shows; a call with other values is not answered
    public const string[] SURROUNDING_VARIABLES = {
        "LANG", "LANGUAGE", "LC_ALL", "LC_MESSAGES", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        "XDG_DATA_DIRS", "GSETTINGS_BACKEND", "GSETTINGS_SCHEMA_DIR"
    };

    // The argument that starts a process as the background copy; not meant to be given by hand
    public const string RESIDENT_ARGUMENT = "--resident";

    // Time the background copy has to take a request before the call shows its window itself
    public const int64 RESIDENT_ACCEPT_TIMEOUT_US = 1000000;
    // A request the background copy finds too close to that limit is left to the call
    internal const int64 RESIDENT_ACCEPT_MARGIN_US = 100000;
    // Largest request accepted, in bytes
    internal const uint32 RESIDENT_MAX_REQUEST = 4 * 1024 * 1024;

    // Replies to a request: taken, or left to the call to show by itself
    internal const uint8 RESIDENT_ACCEPTED = 'A';
    internal const uint8 RESIDENT_DECLINED = 'D';

    // A request: the caller's deadline (monotonic clock), arguments, environment and working directory
    internal const string RESIDENT_REQUEST_TYPE = "(xasass)";
    // The end of a request: exit status, and the message of a fatal error the caller raises itself
    internal const string RESIDENT_RESULT_TYPE = "(is)";

    /**
     * True if the resident-mode setting is on. False also when the installed settings
     * schema does not have the key.
     */
    public static bool resident_mode_enabled() {
        var source = SettingsSchemaSource.get_default();
        var schema = source != null ? source.lookup("org.regolith-linux.ilia", true) : null;

        if (schema == null || !schema.has_key("resident-mode"))
            return false;
        return new GLib.Settings.full(schema, null, null).get_boolean("resident-mode");
    }

    /**
     * True for the calls the background copy answers: every page except textlist (which
     * reads its items from standard input) and tracker, and only known pages, so that an
     * unknown page fails as it always has.
     */
    public static bool is_resident_page(HashTable<string, string ?> arg_map) {
        string page = (arg_map.get("-p") ?? "apps").down();

        switch (page) {
            case "apps":
            case "terminal":
            case "notifications":
            case "keybindings":
            case "windows":
                return true;
            case "textlist":
            case "tracker":
                return false;
            default:
                // With -a an unknown page only changes the page shown first
                return arg_map.contains("-a");
        }
    }

    /**
     * The name of the abstract socket of the background copy for a user and session.
     * An unset variable and an empty one are different sessions.
     */
    public static string resident_socket_name(string[] environ, uint uid) {
        var identity = new StringBuilder();
        foreach (unowned string name in SESSION_VARIABLES) {
            string ? value = Environ.get_variable(environ, name);
            identity.append(name);
            identity.append(value == null ? "\n-\n" : "\n=" + value + "\n");
        }
        return "ilia-resident-1-%u-%s".printf(uid, Checksum.compute_for_string(ChecksumType.SHA256, identity.str));
    }

    /* True if two environments have the same launcher-related surroundings */
    public static bool same_surroundings(string[] environ, string[] other) {
        foreach (unowned string name in SURROUNDING_VARIABLES) {
            if (Environ.get_variable(environ, name) != Environ.get_variable(other, name))
                return false;
        }
        return true;
    }

    internal static UnixSocketAddress resident_address(string[] environ) {
        return new UnixSocketAddress.with_type(resident_socket_name(environ, (uint) Posix.getuid()), -1, UnixSocketAddressType.ABSTRACT);
    }

    // Read exactly buffer.length bytes; false on end of stream
    internal static bool read_exactly(InputStream stream, uint8[] buffer) throws GLib.Error {
        size_t read;
        stream.read_all(buffer, out read);
        return read == buffer.length;
    }

    // A variant, sized
    internal static void write_variant(OutputStream stream, Variant value) throws GLib.Error {
        var data = value.get_data_as_bytes();
        uint32 size = (uint32) data.get_size();
        uint8[] size_data = new uint8[sizeof (uint32)];
        Memory.copy(size_data, &size, sizeof (uint32));
        stream.write_all(size_data, null);
        stream.write_all(data.get_data(), null);
        stream.flush();
    }

    internal static Variant ? read_variant(InputStream stream, string type) throws GLib.Error {
        uint32 size = 0;
        uint8[] size_data = new uint8[sizeof (uint32)];
        if (!read_exactly(stream, size_data))
            return null;
        Memory.copy(&size, size_data, sizeof (uint32));
        if (size > RESIDENT_MAX_REQUEST)
            return null;

        var data = new uint8[size];
        if (!read_exactly(stream, data))
            return null;
        // Not trusted: GVariant checks the data as it is read
        return new Variant.from_bytes(new VariantType(type), new Bytes.take((owned) data), false);
    }

    /**
     * The calling side: hands a call to the background copy of the session
     */
    public class ResidentClient {
        /**
         * Have the background copy answer a call, and wait until it is finished.
         *
         * Returns false, with nothing shown, if there is no background copy for the session,
         * it is another user's, it does not take the request within a second, or it does not
         * answer this call (its page or its surroundings): the call then shows its window
         * itself. Otherwise status is the exit status of the call, and fatal_error the message
         * of an error the call ends with, or null.
         */
        public static bool answer(string[] args, string[] environ, out int status, out string ? fatal_error) {
            status = 1;
            fatal_error = null;
            int64 deadline = get_monotonic_time() + RESIDENT_ACCEPT_TIMEOUT_US;

            Socket socket;
            UnixConnection connection;
            try {
                socket = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
                socket.connect(resident_address(environ));
                // Only the user's own background copy
                if (socket.get_credentials().get_unix_user() != Posix.getuid())
                    return false;

                connection = (UnixConnection) SocketConnection.factory_create_connection(socket);
                connection.send_fd(Posix.STDOUT_FILENO);
                connection.send_fd(Posix.STDERR_FILENO);
                write_variant(connection.output_stream, new Variant.tuple({
                    new Variant.int64(deadline), new Variant.strv(args), new Variant.strv(environ),
                    new Variant.string(Environment.get_current_dir())
                }));
            } catch (GLib.Error e) {
                // No background copy, or one that is going away
                return false;
            }

            var reply = new uint8[1];
            try {
                int64 remaining = deadline - get_monotonic_time();
                if (remaining <= 0 || !socket.condition_timed_wait(IOCondition.IN, remaining))
                    throw new IOError.TIMED_OUT("No reply");
                if (!read_exactly(connection.input_stream, reply) || reply[0] != RESIDENT_ACCEPTED) {
                    // Declined, or the background copy is going away
                    socket.close();
                    return false;
                }
            } catch (GLib.Error e) {
                // Not taken in time, as when the background copy is stopped. Closing the connection
                // tells it, if it gets to the request after all, that the call no longer waits.
                try {
                    socket.close();
                } catch (GLib.Error close_error) {
                }
                return false;
            }

            // Taken: the call ends when its window is finished
            try {
                var result = read_variant(connection.input_stream, RESIDENT_RESULT_TYPE);
                if (result != null) {
                    status = result.get_child_value(0).get_int32();
                    string message = result.get_child_value(1).get_string();
                    if (message != "")
                        fatal_error = message;
                    return true;
                }
            } catch (GLib.Error e) {
            }
            // The background copy went away while the window was showing
            stderr.printf("The launcher window closed unexpectedly\n");
            status = 1;
            return true;
        }
    }

    /**
     * Take the session's socket, for a process that is to become the background copy. Null if
     * another background copy has it (or it cannot be made): there is never more than one per
     * session.
     */
    public static Socket ? bind_resident_socket(string[] environ) {
        try {
            var socket = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
            socket.bind(resident_address(environ), false);
            socket.listen();
            return socket;
        } catch (GLib.Error e) {
            return null;
        }
    }

    /**
     * Start the background copy for the session of an environment, as its own process,
     * detached from the call that starts it. It ends at once if the session has one.
     */
    public static void start_resident_in_background(string argv0, string[] environ) {
        string program;
        try {
            program = FileUtils.read_link("/proc/self/exe");
        } catch (FileError e) {
            program = argv0;
        }

        string[] argv = { program, argv0, RESIDENT_ARGUMENT };
        try {
            Pid pid;
            // Standard input, output and error are /dev/null: the background copy writes to a
            // caller's output only while it serves that call
            Process.spawn_async("/", argv, environ,
                                SpawnFlags.FILE_AND_ARGV_ZERO | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
                                () => { Posix.setsid(); }, out pid);
        } catch (SpawnError e) {
            stderr.printf("Cannot start the launcher in the background: %s\n", e.message);
        }
    }
}
