/**
 * A client library for rofication.
 *
 * This client, once constructed, can only send one command.
 */
namespace Ilia {
    enum ROFICATION_COMMAND {
        COUNT
    }

    public class NotificationDesc {
        // 0 when the daemon sent no usable id, see read_id()
        public int64 id { get; private set; }
        public string summary { get; private set; }
        public string body { get; private set; }
        public string application { get; private set; }
        public string icon { get; private set; }
        public int64 urgency { get; private set; }
        // Time the notification arrived, in seconds since the epoch; 0 if unknown
        public double timestamp { get; private set; }
        // TODO add 'actions' (list of string)

        // Members that are missing, null or of another type read as "" or 0
        internal NotificationDesc (Json.Object responseJson) {
            id = read_id(responseJson.get_member("id"));
            summary = string_member(responseJson, "summary");
            body = string_member(responseJson, "body");
            application = string_member(responseJson, "application");
            icon = string_member(responseJson, "icon");

            var urgency_node = responseJson.get_member("urgency");
            if (is_value_of_type(urgency_node, typeof (int64)))
                urgency = urgency_node.get_int();

            // A float from the daemon; notifications saved by older daemons have none or ""
            var ts = responseJson.get_member("timestamp");
            if (is_value_of_type(ts, typeof (double)) || is_value_of_type(ts, typeof (int64)))
                timestamp = ts.get_double();
        }

        /*
         * A positive JSON integer, or 0. JSON-GLib reads 7.0 and 7e0 as doubles, and an integer
         * beyond int64 as int64.MAX, so int64.MAX could name another notification and is not
         * used either.
         */
        private static int64 read_id(Json.Node ? node) {
            if (!is_value_of_type(node, typeof (int64)))
                return 0;
            int64 value = node.get_int();
            return value > 0 && value < int64.MAX ? value : 0;
        }

        private static bool is_value_of_type(Json.Node ? node, Type type) {
            return node != null && node.get_node_type() == Json.NodeType.VALUE && node.get_value_type() == type;
        }

        private static string string_member(Json.Object object, string name) {
            var node = object.get_member(name);
            if (is_value_of_type(node, typeof (string)))
                return node.get_string();
            return "";
        }
    }

    // The notifications in one reply of the daemon, and how many of its elements were not objects
    public class NotificationList {
        public List<NotificationDesc> notifications = new List<NotificationDesc> ();
        public uint unreadable = 0;
    }

    /**
     * Order notifications newest first
     *
     * The daemon lists notifications in the order they were first added; a notification
     * that is replaced keeps its id and its place but gets a new timestamp. So order by
     * timestamp, newest first, then by id, highest first. Notifications without a
     * timestamp come after those with one.
     */
    public static int compare_notifications_newest_first(NotificationDesc a, NotificationDesc b) {
        if (a.timestamp != b.timestamp)
            return a.timestamp > b.timestamp ? -1 : 1;
        if (a.id != b.id)
            return a.id > b.id ? -1 : 1;
        return 0;
    }

    /*
     * Cancels the I/O of one request when the daemon stays silent for too long, or when its
     * whole reply takes too long, and remembers which of the two happened
     */
    class ReplyDeadline {
        public Cancellable cancellable = new Cancellable();
        public string ? reason = null;
        private uint idle_source = 0;
        private uint reply_source = 0;

        // Start, or start again, the wait for the next byte from the daemon
        public void restart_idle(uint ms) {
            if (idle_source != 0)
                Source.remove(idle_source);
            idle_source = Timeout.add(ms, () => {
                idle_source = 0;
                expire("timed out: nothing came from the notification daemon for %u ms".printf(ms));
                return Source.REMOVE;
            });
        }

        public void start_reply(uint ms) {
            reply_source = Timeout.add(ms, () => {
                reply_source = 0;
                expire("timed out: the reply of the notification daemon was not complete after %u ms".printf(ms));
                return Source.REMOVE;
            });
        }

        public void stop() {
            if (idle_source != 0)
                Source.remove(idle_source);
            if (reply_source != 0)
                Source.remove(reply_source);
            idle_source = reply_source = 0;
        }

        private void expire(string why) {
            if (reason == null)
                reason = why;
            cancellable.cancel();
        }
    }

    public class RoficationClient {
        // Seconds to wait on the daemon: one that accepts the connection but never answers must not hang ilia
        private const uint SOCKET_TIMEOUT = 2;
        // Milliseconds a list request may go without a byte from the daemon
        private const uint REPLY_IDLE_TIMEOUT_MS = 2000;
        // Milliseconds from sending a list request until its reply must be complete
        private const uint REPLY_TIMEOUT_MS = 5000;

        private UnixSocketAddress socket_addr;
        private int buffer_size = 1024 * 8;

        public RoficationClient (string socket_str) throws GLib.Error {
            this.socket_addr = new UnixSocketAddress(socket_str);
        }

        /**
         * Ask for the list without blocking the main loop. Fails with IOError.TIMED_OUT when
         * no byte arrives for two seconds or the reply is not complete five seconds after the
         * request was sent, with IOError.CANCELLED when cancellable is cancelled, and with
         * IOError.INVALID_DATA when the reply is not a JSON array.
         */
        public async NotificationList get_notifications(Cancellable ? cancellable = null) throws GLib.Error {
            var deadline = new ReplyDeadline();
            ulong cancel_handler = 0;
            if (cancellable != null)
                cancel_handler = cancellable.connect(() => deadline.cancellable.cancel());

            SocketConnection ? connection = null;
            var reply = new StringBuilder();
            try {
                deadline.restart_idle(REPLY_IDLE_TIMEOUT_MS);

                var socket_client = new SocketClient();
                socket_client.enable_proxy = false;
                connection = yield socket_client.connect_async(socket_addr, deadline.cancellable);

                size_t sent;
                yield connection.output_stream.write_all_async("list\n".data, Priority.DEFAULT, deadline.cancellable, out sent);

                debug("Sent " + sent.to_string() + " bytes to notification backend.");

                deadline.restart_idle(REPLY_IDLE_TIMEOUT_MS);
                deadline.start_reply(REPLY_TIMEOUT_MS);

                while (true) {
                    var bytes = yield connection.input_stream.read_bytes_async(buffer_size, Priority.DEFAULT, deadline.cancellable);

                    if (bytes.get_size() == 0)
                        break;
                    reply.append_len((string) bytes.get_data(), (ssize_t) bytes.get_size());
                    deadline.restart_idle(REPLY_IDLE_TIMEOUT_MS);
                }
            } catch (IOError.CANCELLED e) {
                if (deadline.reason != null)
                    throw new IOError.TIMED_OUT(deadline.reason);
                throw e;
            } finally {
                deadline.stop();
                if (cancel_handler != 0)
                    cancellable.disconnect(cancel_handler);
                if (connection != null) {
                    try {
                        connection.close();
                    } catch (GLib.Error e) {
                        debug("Closing the notification backend connection: %s", e.message);
                    }
                }
            }

            return parse_notifications(reply.str, reply.len);
        }

        /*
         * A reply loads when it is a JSON array in UTF-8. Each object in it becomes a
         * notification; other elements are only counted.
         */
        internal static NotificationList parse_notifications(string reply, size_t length) throws GLib.Error {
            if (length == 0)
                throw new IOError.INVALID_DATA("The notification daemon sent an empty reply");
            if (!reply.validate((ssize_t) length))
                throw new IOError.INVALID_DATA("The reply of the notification daemon is not UTF-8 text");

            Json.Parser parser = new Json.Parser();
            parser.load_from_data(reply, (ssize_t) length);

            var root = parser.get_root();
            if (root == null)
                throw new IOError.INVALID_DATA("The notification daemon sent an empty reply");
            if (root.get_node_type() != Json.NodeType.ARRAY)
                throw new IOError.INVALID_DATA("The reply of the notification daemon is %s, not a JSON array", root.type_name());

            var result = new NotificationList();
            foreach (unowned Json.Node element in root.get_array().get_elements()) {
                if (element.get_node_type() == Json.NodeType.OBJECT)
                    result.notifications.append(new NotificationDesc(element.get_object()));
                else
                    result.unreadable++;
            }

            return result;
        }

        public void delete_notification_by_id(int64 id) throws GLib.Error {
            var socket = open_socket(socket_addr);

            var message = "del:" + id.to_string() + "\n";
            debug(message);

            send_all(socket, message);
        }

        public void delete_notifications_by_ids(string[] ids) throws GLib.Error {
            var str_builder = new StringBuilder();

            bool first = true;
            foreach (string item in ids) {
                if (item != null) {
                    if (!first) str_builder.append(",");
                    str_builder.append(item);
                    first = false;
                }
            }
            var cmd = "delm:" + str_builder.str + "\n";

            var socket = open_socket(socket_addr);

            send_all(socket, cmd);
        }

        public void delete_notification_by_app(string app) throws GLib.Error {
            var socket = open_socket(socket_addr);

            send_all(socket, "dela:" + app + "\n");
        }

        // Send all of message and close the socket; sending only part of it is an error
        private void send_all(Socket socket, string message) throws GLib.Error {
            try {
                ssize_t sent = socket.send(message.data);
                debug("Sent " + sent.to_string() + " bytes to notification backend.");
                if (sent != message.length)
                    throw new IOError.FAILED("Sent only %s of %d bytes to the notification daemon", sent.to_string(), message.length);
            } finally {
                try {
                    socket.close();
                } catch (GLib.Error e) {
                    debug("Closing the notification backend socket: %s", e.message);
                }
            }
        }

        private Socket open_socket(UnixSocketAddress addr) throws GLib.Error {
            var socket = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
            assert(socket != null);

            socket.timeout = SOCKET_TIMEOUT;
            socket.connect(addr);
            socket.set_blocking(true);

            return socket;
        }
    }
}
