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
        SYNC
    }

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

    // https://i3wm.org/docs/ipc.html#_config_reply
    public class ConfigReply {
        public string config { get; private set; }

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
         */
        private static void read_sway_config(string text, string ? dir, HashSet<string> visited, StringBuilder builder) {
            string[] lines = text.split("\n");
            for (int n = 0; n < lines.length; n++) {
                unowned string line = lines[n];
                // the last element is what follows the final newline, if any
                append_file(builder, n < lines.length - 1 ? line + "\n" : line);

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
                    read_sway_config(partial, Path.get_dirname(matched_path), visited, builder);
                }
            }
        }

        private string get_i3_config(Json.Node responseJson) {

            var configBuilder = new StringBuilder("");
            var configs = responseJson.get_object().get_array_member("included_configs");

            configs.foreach_element((arr, index, node) => {
                append_file(configBuilder, node.get_object().get_string_member("variable_replaced_contents"));
            });

            return configBuilder.str;
        }

        private string get_sway_config(Json.Node responseJson) {
            string baseConfig = responseJson.get_object().get_string_member("config");
            var configBuilder = new StringBuilder("");
            read_sway_config(baseConfig, null, new HashSet<string> (), configBuilder);
            return configBuilder.str;
        }

        internal ConfigReply (Json.Node responseJson, string wm_name) throws GLib.FileError {
            if (wm_name == "sway")
                config = get_sway_config(responseJson);
            else
                config = get_i3_config(responseJson);
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
        private string wm_name;

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

        private uint8[] generate_request(WM_COMMAND cmd) {
            ByteArray np = new ByteArray();

            np.append(magic_number);
            np.append(int32_to_uint8_array(0));   // payloadSize.get_data_as_bytes().get_data());
            np.append(int32_to_uint8_array(cmd));   // command.get_data_as_bytes().get_data());

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

        private Json.Node ? wm_ipc(WM_COMMAND command) throws GLib.Error {
            ssize_t sent = socket.send(generate_request(command));

            debug("Sent " + sent.to_string() + " bytes to " + wm_name);

            uint8[] header = receive_exactly(HEADER_SIZE);

            if (Memory.cmp(header, magic_number, magic_number.length) != 0)
                throw new WM_ERROR.RPC_ERROR("Invalid reply header from %s".printf(wm_name));

            uint32 payload_length = 0;
            Memory.copy(&payload_length, &header[magic_number.length], sizeof (uint32));

            debug("Receiving " + payload_length.to_string() + " bytes from " + wm_name);

            if (payload_length == 0)
                return null;

            uint8[] payload = receive_exactly(payload_length);

            Json.Parser parser = new Json.Parser();
            parser.load_from_data((string) payload, payload_length);

            return parser.get_root();
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

        public TreeReply getTree() throws WM_ERROR, GLib.Error {
            var response = wm_ipc(WM_COMMAND.GET_TREE);

            if (response == null)
                throw new WM_ERROR.RPC_ERROR("No Response");

            return new TreeReply(response);
        }
    }
}
