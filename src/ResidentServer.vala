namespace Ilia {
    /**
     * One call taken by the background copy, until its window is finished
     */
    public class ResidentRequest : GLib.Object {
        public string[] args;
        public string[] environ;
        public string working_directory;
        public HashTable<string, string ?> arg_map;

        // The caller hung up, or the connection broke, before the request was finished
        public signal void cancelled();

        private SocketConnection connection;
        private int stdout_fd;
        private int stderr_fd;
        private int64 deadline;
        private SocketSource ? hangup_source = null;
        private bool finished = false;

        private ResidentRequest (SocketConnection connection, int stdout_fd, int stderr_fd, Variant request) {
            this.connection = connection;
            this.stdout_fd = stdout_fd;
            this.stderr_fd = stderr_fd;

            deadline = request.get_child_value(0).get_int64();
            args = request.get_child_value(1).get_strv();
            environ = request.get_child_value(2).get_strv();
            working_directory = request.get_child_value(3).get_string();
            arg_map = CommandLine.parse_args(args);
        }

        /**
         * Read a request from a new connection. Null if it is not a complete request from the
         * same user, or the caller has stopped waiting for it.
         */
        public static ResidentRequest ? receive(SocketConnection connection) {
            var socket = connection.get_socket();
            int stdout_fd = -1, stderr_fd = -1;
            try {
                if (socket.get_credentials().get_unix_user() != Posix.getuid())
                    return null;

                // The caller writes its request at once; one that does not is not waited for long
                socket.set_timeout(1);
                var unix_connection = connection as UnixConnection;
                if (unix_connection == null)
                    return null;
                stdout_fd = unix_connection.receive_fd();
                stderr_fd = unix_connection.receive_fd();
                var data = read_variant(connection.input_stream, RESIDENT_REQUEST_TYPE);
                socket.set_timeout(0);
                if (data == null)
                    throw new IOError.INVALID_DATA("Incomplete request");

                var request = new ResidentRequest(connection, stdout_fd, stderr_fd, data);
                if (!request.caller_waiting()) {
                    request.drop();
                    return null;
                }
                return request;
            } catch (GLib.Error e) {
                if (stdout_fd >= 0)
                    Posix.close(stdout_fd);
                if (stderr_fd >= 0)
                    Posix.close(stderr_fd);
                try {
                    connection.close();
                } catch (GLib.Error close_error) {
                }
                return null;
            }
        }

        /*
         * True if the caller still waits for the request: it has not hung up, and is not about
         * to give up on it. A request read late, as by a background copy that was stopped,
         * is never shown.
         */
        private bool caller_waiting() {
            if (get_monotonic_time() > deadline - RESIDENT_ACCEPT_MARGIN_US)
                return false;
            return (connection.get_socket().condition_check(IOCondition.HUP | IOCondition.ERR | IOCondition.IN) == 0);
        }

        // Leave a request unanswered: the caller has gone, or shows its window itself
        public void drop() {
            finished = true;
            close();
        }

        /* Tell the caller to show its window itself */
        public void decline() {
            finished = true;
            try {
                connection.output_stream.write({ RESIDENT_DECLINED });
            } catch (GLib.Error e) {
            }
            close();
        }

        /**
         * Take the request: from here on output goes to the caller's standard output and error,
         * programs started get its environment and the working directory is its own, until
         * the request is finished.
         */
        public bool accept() {
            try {
                connection.output_stream.write({ RESIDENT_ACCEPTED });
            } catch (GLib.Error e) {
                drop();
                return false;
            }

            // The caller only writes again by closing its end
            hangup_source = connection.get_socket().create_source(IOCondition.IN | IOCondition.HUP | IOCondition.ERR);
            hangup_source.set_callback((socket, condition) => {
                hangup_source = null;
                if (!finished)
                    cancelled();
                return Source.REMOVE;
            });
            hangup_source.attach(MainContext.default());

            stdout.flush();
            Posix.dup2(stdout_fd, Posix.STDOUT_FILENO);
            Posix.dup2(stderr_fd, Posix.STDERR_FILENO);
            if (Posix.chdir(working_directory) != 0)
                Posix.chdir("/");
            CallerEnvironment.set_environ(environ);
            return true;
        }

        /**
         * Finish the request: the caller ends with the status, or raises the fatal error
         */
        public void finish(int status, string ? fatal_error = null) {
            if (finished)
                return;
            finished = true;

            CallerEnvironment.set_environ(null);
            Posix.chdir("/");
            // Nothing written for this call may reach the next one, nor keep the caller's output open
            stdout.flush();
            int null_fd = Posix.open("/dev/null", Posix.O_RDWR);
            if (null_fd >= 0) {
                Posix.dup2(null_fd, Posix.STDOUT_FILENO);
                Posix.dup2(null_fd, Posix.STDERR_FILENO);
                Posix.close(null_fd);
            }

            try {
                write_variant(connection.output_stream, new Variant.tuple({
                    new Variant.int32(status), new Variant.string(fatal_error ?? "")
                }));
            } catch (GLib.Error e) {
                // The caller has gone
            }
            close();
        }

        private void close() {
            if (hangup_source != null) {
                hangup_source.destroy();
                hangup_source = null;
            }
            if (stdout_fd >= 0) {
                Posix.close(stdout_fd);
                stdout_fd = -1;
            }
            if (stderr_fd >= 0) {
                Posix.close(stderr_fd);
                stderr_fd = -1;
            }
            try {
                connection.close();
            } catch (GLib.Error e) {
            }
        }
    }

    /**
     * The serving side: the listening socket of the background copy
     */
    public class ResidentServer : GLib.Object {
        // A request was read and the caller waits for it; it is still to be accepted or declined
        public signal void request_received(ResidentRequest request);

        private Socket socket;
        private SocketService ? service = null;

        // The listening socket taken by bind_resident_socket(), as a file descriptor
        public ResidentServer (int socket_fd) throws GLib.Error {
            socket = new Socket.from_fd(socket_fd);
        }

        // Start taking requests, from the main loop
        public void start() throws GLib.Error {
            service = new SocketService();
            service.add_socket(socket, null);
            service.incoming.connect((connection, source_object) => {
                var request = ResidentRequest.receive(connection);
                if (request != null)
                    request_received(request);
                return true;
            });
            service.start();
        }
    }
}
