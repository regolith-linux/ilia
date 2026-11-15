/**
 * A client library for i3-wm that deserializes into idomatic Vala response types
 */

using GLib;
using Gee;

namespace Ilia {
    enum WM_COMMAND {
        RUN_COMMAND,
        GET_WORKSPACES,
        SUBSCRIBE,
        GET_OUTPUTS,
        GET_TREE,
        GET_MARKS,
        GET_BAR_CONFIG,
        GET_VERSION,
        GET_BINDING_MODES,
        GET_CONFIG,
        SEND_TICK,
        SYNC,
        GET_BINDING_STATE
    }

    // Event types, as they appear in an event message with the high bit cleared
    // https://i3wm.org/docs/ipc.html#_events
    public enum WM_EVENT {
        WORKSPACE,
        OUTPUT,
        MODE,
        WINDOW,
        BARCONFIG_UPDATE,
        BINDING,
        SHUTDOWN,
        TICK
    }

    // Called with each event the window manager sends after a subscription
    public delegate void WmEventHandler(WM_EVENT event, Json.Node payload);

    public errordomain WM_ERROR {
        RPC_ERROR
    }

    // https://i3wm.org/docs/ipc.html#_version_reply
    public class VersionReply {
        public string human_readable { get; private set; }
        public string loaded_config_file_name { get; private set; }
        public string minor { get; private set; }
        public string patch { get; private set; }
        public string major { get; private set; }

        internal VersionReply (Json.Node responseJson) {
            human_readable = responseJson.get_object().get_string_member("human_readable");
            loaded_config_file_name = responseJson.get_object().get_string_member("loaded_config_file_name");
            minor = responseJson.get_object().get_string_member("minor");
            patch = responseJson.get_object().get_string_member("patch");
            major = responseJson.get_object().get_string_member("major");
        }
    }

    // https://i3wm.org/docs/ipc.html#_workspaces_reply
    public class WorkspaceReply {
        public string name { get; private set; }
        // The number the name starts with, or -1 when it starts with none
        public int num { get; private set; }

        internal WorkspaceReply (Json.Object responseJson) {
            name = responseJson.get_string_member_with_default("name", "");
            num = (int) responseJson.get_int_member_with_default("num", -1);
        }
    }

    /**
     * The variables of an i3 configuration, defined as i3 defines them when no resource
     * is set. i3 first reads the set and set_from_resource lines of a file, the last
     * value given to a name winning, and then replaces every variable in that file at
     * once. The variables carry over to the files read after it.
     */
    internal class I3UnsetVariables {
        // Names with their '$', longest first, so that a name wins over its prefixes
        private ArrayList<string> names = new ArrayList<string> ();
        private HashMap<string, string> values = new HashMap<string, string> ();

        // The next whitespace-delimited word of text at or after pos; pos moves past it
        private static string ? next_word(string text, ref int pos) {
            while (pos < text.length && text[pos].isspace()) pos++;
            if (pos >= text.length) return null;
            int start = pos;
            while (pos < text.length && !text[pos].isspace()) pos++;
            return text.substring(start, pos - start);
        }

        // The rest of the line in text after pos and any whitespace, as i3 reads a value
        private static string rest_of_line(string text, int pos) {
            while (pos < text.length && text[pos].isspace()) pos++;
            int end = text.index_of_char('\n', pos);
            return text.substring(pos, (end < 0 ? text.length : end) - pos);
        }

        private void define(string name, string value) {
            if (!values.has_key(name)) {
                int i = 0;
                while (i < names.size && names[i].length > name.length)
                    i++;
                names.insert(i, name);
            }
            values.set(name, value);
        }

        // A set or set_from_resource line defines its variable; resources take their fallback
        private void read_line(string line) {
            int pos = 0;
            string ? key = next_word(line, ref pos);
            if (key == null || key.length < 3 || key[0] == '#')
                return;
            string value = rest_of_line(line, pos);

            int value_pos = 0;
            if (key.ascii_down() == "set" && value != "") {
                string name = next_word(value, ref value_pos);
                if (name.has_prefix("$"))
                    define(name, rest_of_line(value, value_pos));
            } else if (key.ascii_down() == "set_from_resource") {
                string ? name = next_word(value, ref value_pos);
                if (name == null || !name.has_prefix("$"))
                    return;
                string ? resource = next_word(value, ref value_pos);
                define(name, resource != null ? rest_of_line(value, value_pos) : "");
            }
        }

        /**
         * The contents of a file as i3 would hold them with no resource set. Like i3,
         * a line ending in a backslash runs on into the next one, unless it is a comment,
         * and a variable name matches regardless of case.
         */
        public string replace_in_file(string raw) {
            var text = new StringBuilder();
            var line = new StringBuilder();
            string[] lines = raw.split("\n");
            for (int n = 0; n < lines.length; n++) {
                bool has_newline = n < lines.length - 1;
                line.append(lines[n]);
                int pos = 0;
                string ? first = next_word(line.str, ref pos);
                if (has_newline && lines[n].has_suffix("\\") && (first == null || first[0] != '#')) {
                    line.truncate(line.len - 1);
                    continue;
                }
                if (has_newline)
                    line.append_c('\n');
                read_line(line.str);
                text.append(line.str);
                line.truncate(0);
            }
            return replace(text.str);
        }

        // Replace each variable in text, the nearest first, without replacing in the values
        private string replace(string text) {
            string lowered = text.ascii_down();
            var lowered_names = new string[names.size];
            var next = new int[names.size];
            for (int i = 0; i < names.size; i++) {
                lowered_names[i] = names[i].ascii_down();
                next[i] = -2;
            }

            var result = new StringBuilder();
            int walk = 0;
            while (true) {
                int nearest = -1;
                for (int i = 0; i < names.size; i++) {
                    if (next[i] != -1 && next[i] < walk)
                        next[i] = lowered.index_of(lowered_names[i], walk);
                    if (next[i] >= 0 && (nearest < 0 || next[i] < next[nearest]))
                        nearest = i;
                }
                if (nearest < 0) {
                    result.append(text.substring(walk));
                    break;
                }
                result.append(text.substring(walk, next[nearest] - walk));
                result.append(values.get(names[nearest]));
                walk = next[nearest] + names[nearest].length;
            }
            return result.str;
        }
    }

    // https://i3wm.org/docs/ipc.html#_config_reply
    public class ConfigReply {
        public string config { get; private set; }

        // config in pieces, each from a single file. i3: each included file, its variables
        // replaced; sway: the files as sway reads them, split where they include others
        public string[] configs { get; private set; }

        /**
         * i3: each included file as i3 would hold it with no resource set, every
         * set_from_resource taking its fallback; when i3 does not send the raw files,
         * the files as i3 holds them. null for sway, which hands its files over as written.
         */
        public string[] ? unset_resources_configs { get; private set; }

        // Expand $NAME and ${NAME} from the environment; unknown variables are left as written
        private static string expand_path_vars(string path) {
            if (!path.contains("$"))
                return path;

            var result = new StringBuilder();
            int i = 0;
            while (i < path.length) {
                char c = path[i];
                int start = i + 1;
                bool braced = c == '$' && start < path.length && path[start] == '{';
                if (braced)
                    start++;
                int end = start;
                if (c == '$' && end < path.length && (path[end].isalpha() || path[end] == '_')) {
                    while (end < path.length && (path[end].isalnum() || path[end] == '_'))
                        end++;
                }
                if (end == start || (braced && (end >= path.length || path[end] != '}'))) {
                    result.append_c(c);
                    i++;
                    continue;
                }

                string ? value = Environment.get_variable(path.substring(start, end - start));
                int next = braced ? end + 1 : end;
                result.append(value ?? path.substring(i, next - i));
                i = next;
            }
            return result.str;
        }

        // Append text to builder, keeping the files' lines apart when one does not end with a newline
        private static void append_file(StringBuilder builder, string text) {
            if (builder.len > 0 && builder.str[builder.len - 1] != '\n')
                builder.append_c('\n');
            builder.append(text);
        }

        /**
         * Read a sway configuration as sway does: each "include" is read in place, its
         * matches in sorted order, each file once. Relative paths are relative to the
         * including file. The order matters, as sway sets and uses variables in it.
         * The text is added to pieces as it is read, a new piece after each include.
         */
        private static void read_sway_config(string text, string ? dir, HashSet<string> visited, ArrayList<string> pieces) {
            var piece = new StringBuilder();
            string[] lines = text.split("\n");
            for (int n = 0; n < lines.length; n++) {
                unowned string line = lines[n];
                // the last element is what follows the final newline, if any
                piece.append(n < lines.length - 1 ? line + "\n" : line);

                string stripped_line = line.strip();
                if (!stripped_line.has_prefix("include "))
                    continue;

                string path = expand_path_vars(stripped_line.substring("include ".length).strip());
                if (path.has_prefix("~/"))
                    path = Path.build_filename(Environment.get_home_dir(), path.substring(2));
                if (!Path.is_absolute(path) && dir != null)
                    path = Path.build_filename(dir, path);

                Posix.Glob matcher = Posix.Glob();
                if (matcher.glob(path, Posix.GLOB_NOSORT) != 0)
                    continue;
                var matches = new ArrayList<string> ();
                foreach (unowned string matched_path in matcher.pathv)
                    matches.add(matched_path);
                matches.sort((a, b) => strcmp(a, b));

                pieces.add(piece.str);
                piece.truncate(0);
                foreach (var matched_path in matches) {
                    if (!FileUtils.test(matched_path, FileTest.IS_REGULAR))
                        continue;
                    string real_path = Posix.realpath(matched_path) ?? matched_path;
                    if (visited.contains(real_path))
                        continue;
                    visited.add(real_path);

                    string partial;
                    try {
                        FileUtils.get_contents(matched_path, out partial);
                    } catch (GLib.Error err) {
                        continue;
                    }
                    read_sway_config(partial, Path.get_dirname(matched_path), visited, pieces);
                }
            }
            pieces.add(piece.str);
        }

        private string get_i3_config(Json.Node responseJson) {

            var configBuilder = new StringBuilder("");
            var included = responseJson.get_object().get_array_member("included_configs");
            string[] replaced = {};
            string[] unset = {};
            bool have_raw = true;
            var variables = new I3UnsetVariables();

            for (uint i = 0; i < included.get_length(); i++) {
                var file = included.get_object_element(i);
                string contents = file.get_string_member("variable_replaced_contents");
                append_file(configBuilder, contents);
                replaced += contents;
                if (have_raw && file.has_member("raw_contents"))
                    unset += variables.replace_in_file(file.get_string_member("raw_contents"));
                else
                    have_raw = false;
            }

            configs = replaced;
            unset_resources_configs = have_raw ? unset : replaced;
            return configBuilder.str;
        }

        private string get_sway_config(Json.Node responseJson) {
            string baseConfig = responseJson.get_object().get_string_member("config");
            var pieces = new ArrayList<string> ();
            read_sway_config(baseConfig, null, new HashSet<string> (), pieces);
            configs = pieces.to_array();

            var configBuilder = new StringBuilder("");
            foreach (var piece in pieces)
                append_file(configBuilder, piece);
            return configBuilder.str;
        }

        internal ConfigReply (Json.Node responseJson, string wm_name) throws GLib.FileError {
            if (wm_name == "sway") {
                config = get_sway_config(responseJson);
                unset_resources_configs = null;
            } else {
                config = get_i3_config(responseJson);
            }
        }
    }

    public class WindowProperties {
        public string clazz { get; private set; }
        public string instance { get; private set; }
        public string window_role { get; private set; }
        public string machine { get; private set; }
        public string title { get; private set; }

        internal WindowProperties (Json.Object responseJson) {
            if (responseJson.has_member("class")) clazz = responseJson.get_string_member("class");
            if (responseJson.has_member("instance")) instance = responseJson.get_string_member("instance");
            if (responseJson.has_member("machine")) machine = responseJson.get_string_member("machine");
            if (responseJson.has_member("title")) title = responseJson.get_string_member("title");
            if (responseJson.has_member("window_role")) window_role = responseJson.get_string_member("window_role");
        }
    }

    public class TreeReply {
        public string id { get; private set; }
        public string ntype { get; private set; }
        public string window_type { get; private set; }
        public bool urgent { get; private set; }
        public string output { get; private set; }
        public string name { get; private set; }
        public string app_id { get; private set; }
        public string layout { get; private set; }
        public WindowProperties windowProperties { get; private set; }
        public TreeReply[] nodes { get; private set; }
        public TreeReply[] floating_nodes { get; private set; }

        internal TreeReply (Json.Node responseJson) {
            var obj = responseJson.get_object();

            id = obj.get_int_member("id").to_string();
            ntype = obj.get_string_member("type");
            urgent = obj.get_boolean_member("urgent");
            name = obj.get_string_member("name");

            if (obj.has_member("window_type"))
                window_type = obj.get_string_member("window_type");
            if (obj.has_member("output"))
                output = obj.get_string_member("output");
            if (obj.has_member("window_properties"))
                windowProperties = new WindowProperties(obj.get_object_member("window_properties"));
            if (obj.has_member("app_id"))
                app_id = obj.get_string_member("app_id");
            if (obj.has_member("layout"))
                layout = obj.get_string_member("layout");

            var jnodes = responseJson.get_object().get_array_member("nodes");

            if (jnodes == null || jnodes.get_length() == 0) {
                nodes = new TreeReply[0];
            } else {
                nodes = new TreeReply[jnodes.get_length()];
                jnodes.foreach_element((arr, index, node) => {
                    nodes[index] = new TreeReply(node);
                });
            }

            var fnodes = responseJson.get_object().get_array_member("floating_nodes");

            if (fnodes == null || fnodes.get_length() == 0) {
                floating_nodes = new TreeReply[0];
            } else {
                floating_nodes = new TreeReply[fnodes.get_length()];
                fnodes.foreach_element((arr, index, node) => {
                    floating_nodes[index] = new TreeReply(node);
                });
            }
        }
    }

    public class IPCClient {
        private Socket socket;
        private uint8[] magic_number = "i3-ipc".data;
        // "i3-ipc" + payload length (uint32) + message type (uint32), native byte order
        private const int HEADER_SIZE = 14;
        private const uint32 EVENT_FLAG = 1U << 31;
        private string wm_name;
        // Watches the socket for events after subscribe()
        private SocketSource ? event_source = null;

        public IPCClient (string wm_name) throws GLib.Error {
            this.wm_name = wm_name;
            // sway is detected from SWAYSOCK; it sets I3SOCK too, but only for the programs it starts
            var socket_path = Environment.get_variable(wm_name == "sway" ? "SWAYSOCK" : "I3SOCK");
            if (socket_path == null)
                throw new IOError.NOT_FOUND("No IPC socket for window manager %s", wm_name);

            var socketAddress = new UnixSocketAddress(socket_path);

            socket = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
            assert(socket != null);

            socket.connect(socketAddress);
            socket.set_blocking(true);
        }

        ~IPCClient () {
            if (event_source != null)
                event_source.destroy();
            if (socket != null) {
                try {
                    socket.close();
                } catch (GLib.Error err) {
                    // TODO consistent error handling
                    stderr.printf("Failed to close %s socket: %s\n", wm_name, err.message);
                }
            }
        }

        private uint8[] int32_to_uint8_array(int32 input) {
            Variant val = new Variant.int32(input);
            return val.get_data_as_bytes().get_data();
        }

        private uint8[] generate_request(WM_COMMAND cmd, string payload = "") {
            ByteArray np = new ByteArray();

            np.append(magic_number);
            np.append(int32_to_uint8_array(payload.length));
            np.append(int32_to_uint8_array(cmd));
            np.append(payload.data);

            Bytes message = ByteArray.free_to_bytes(np);

            return message.get_data();
        }

        // Read exactly count bytes; large replies arrive in several chunks.
        private uint8[] receive_exactly(size_t count) throws GLib.Error {
            var data = new uint8[count];
            size_t received = 0;

            while (received < count) {
                ssize_t len = socket.receive(data[received: count]);

                if (len <= 0)
                    throw new WM_ERROR.RPC_ERROR("%s closed the connection after %zu of %zu bytes".printf(wm_name, received, count));
                received += len;
            }

            return data;
        }

        // Read one message: a reply, or an event when subscribed. Returns null for an empty payload.
        private Json.Node ? read_message(out uint32 message_type) throws GLib.Error {
            message_type = 0;
            uint8[] header = receive_exactly(HEADER_SIZE);

            if (Memory.cmp(header, magic_number, magic_number.length) != 0)
                throw new WM_ERROR.RPC_ERROR("Invalid reply header from %s".printf(wm_name));

            uint32 payload_length = 0;
            Memory.copy(&payload_length, &header[magic_number.length], sizeof (uint32));
            Memory.copy(&message_type, &header[magic_number.length + sizeof (uint32)], sizeof (uint32));

            debug("Receiving " + payload_length.to_string() + " bytes from " + wm_name);

            if (payload_length == 0)
                return null;

            uint8[] payload = receive_exactly(payload_length);

            Json.Parser parser = new Json.Parser();
            parser.load_from_data((string) payload, payload_length);

            return parser.get_root();
        }

        private Json.Node ? wm_ipc(WM_COMMAND command, string request_payload = "") throws GLib.Error {
            uint8[] request = generate_request(command, request_payload);
            ssize_t sent = 0;
            while (sent < request.length)
                sent += socket.send(request[sent: request.length]);

            debug("Sent " + sent.to_string() + " bytes to " + wm_name);

            uint32 message_type;
            return read_message(out message_type);
        }

        public VersionReply getVersion() throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.GET_VERSION);

            if (response == null)
                throw new WM_ERROR.RPC_ERROR("No Response");

            return new VersionReply(response);
        }

        public ConfigReply getConfig() throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.GET_CONFIG);

            if (response == null)
                throw new WM_ERROR.RPC_ERROR("No Response");

            return new ConfigReply(response, this.wm_name);
        }

        /**
         * Run a command in the window manager, in its own message: the text reaches
         * the window manager unchanged, with no shell or command line in between.
         * Throws if the window manager reports that the command failed.
         */
        public void runCommand(string command) throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.RUN_COMMAND, command);

            if (response == null || response.get_node_type() != Json.NodeType.ARRAY)
                throw new WM_ERROR.RPC_ERROR("No Response");

            foreach (unowned Json.Node result in response.get_array().get_elements()) {
                var obj = result.get_object();
                if (obj != null && obj.has_member("success") && !obj.get_boolean_member("success")) {
                    string reason = obj.has_member("error") ? obj.get_string_member("error") : "unknown error";
                    throw new WM_ERROR.RPC_ERROR("%s: %s".printf(command, reason));
                }
            }
        }

        public TreeReply getTree() throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.GET_TREE);

            if (response == null)
                throw new WM_ERROR.RPC_ERROR("No Response");

            return new TreeReply(response);
        }

        /**
         * The workspaces the window manager has, on every output, in the order it gives them
         */
        public WorkspaceReply[] getWorkspaces() throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.GET_WORKSPACES);

            if (response == null || response.get_node_type() != Json.NodeType.ARRAY)
                throw new WM_ERROR.RPC_ERROR("No Response");

            WorkspaceReply[] workspaces = {};
            foreach (unowned Json.Node workspace in response.get_array().get_elements()) {
                if (workspace.get_node_type() == Json.NodeType.OBJECT)
                    workspaces += new WorkspaceReply(workspace.get_object());
            }
            return workspaces;
        }

        /**
         * The name of the current binding mode ("default" outside any mode)
         */
        public string getBindingState() throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.GET_BINDING_STATE);

            if (response == null || response.get_node_type() != Json.NodeType.OBJECT || !response.get_object().has_member("name"))
                throw new WM_ERROR.RPC_ERROR("No Response");

            return response.get_object().get_string_member("name");
        }

        /**
         * Subscribe this connection to events, and call handler from the main loop for each
         * event that arrives. The connection is then used for events only.
         *
         * @param events Event names, such as "binding"
         */
        public void subscribe(string[] events, owned WmEventHandler handler) throws WM_ERROR, GLib.Error {
            var names = new Json.Builder();
            names.begin_array();
            foreach (unowned string name in events)
                names.add_string_value(name);
            names.end_array();
            var generator = new Json.Generator();
            generator.set_root(names.get_root());

            var response = wm_ipc(WM_COMMAND.SUBSCRIBE, generator.to_data(null));
            if (response == null || response.get_node_type() != Json.NodeType.OBJECT || !response.get_object().get_boolean_member_with_default("success", false))
                throw new WM_ERROR.RPC_ERROR("%s refused the subscription".printf(wm_name));

            event_source = socket.create_source(IOCondition.IN | IOCondition.HUP | IOCondition.ERR);
            event_source.set_callback((source_socket, condition) => {
                if ((condition & IOCondition.IN) == 0) {
                    event_source = null;
                    return Source.REMOVE;
                }
                try {
                    uint32 message_type;
                    var payload = read_message(out message_type);
                    // Events have the highest bit set; the reply to a request does not
                    if ((message_type & EVENT_FLAG) != 0 && payload != null)
                        handler((WM_EVENT) (message_type & ~EVENT_FLAG), payload);
                } catch (GLib.Error err) {
                    stderr.printf("Stopped reading %s events: %s\n", wm_name, err.message);
                    event_source = null;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
            event_source.attach(MainContext.default());
        }
    }
}
