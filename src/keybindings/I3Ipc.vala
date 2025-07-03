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

        private string expand_path_vars(string path) {
            if (!path.contains("$"))
                return path;
            string[] parts = path.split("$");
            string result = "";
            for (int i = 0; i < parts.length; i++) {
                string part = parts[i];

                // part is empty if we either have two consequtive '$' or
                // if the path starts with '$' and it is the first segment
                // of the split
                if (part == "") {
                    bool is_first_segment = i == 0;
                    if (is_first_segment)
                        continue;
                    result += "$";
                    continue;
                }
                int end = part.index_of("/");
                if (end == -1)
                    end = part.length;
                string var_name = part[0 : end];
                string value = Environment.get_variable(var_name);
                if (value != null)
                    result += value + part[end:part.length];
                else
                    result += "$" + part;
            }
            return result;
        }

        // Get array of include paths from config partial (may contain glob patterns)
        private string[] get_includes_from_partial(string config) {
            string[] lines = config.split("\n");
            string[] include_paths = {};
            foreach (unowned string line in lines) {
                string stripped_line = line.strip();

                // First token of include lines must be "include" followed by the path.
                // Also supports globbing.
                // Examples:
                // "include /path/to/config"
                // "include /path/to/config.d/*"
                if (!stripped_line.has_prefix("include "))
                    continue;
                string path = stripped_line.split("include ", 2)[1];
                include_paths += expand_path_vars(path);
            }
            return include_paths;
        }

        private string walk_included_configs(string baseConfig) throws GLib.FileError {
            var configBuilder = new StringBuilder("\n");
            HashSet<string> visited_paths = new HashSet<string> ();
            GLib.Queue<string> path_queue = new GLib.Queue<string> ();

            string[] included_paths = get_includes_from_partial(baseConfig);
            foreach (unowned string path in included_paths) {
                path_queue.push_tail(path);
            }

            while (!path_queue.is_empty()) {

                // Replace head of queue with paths obtained from glob matching
                // Head of queue doesn't change if the string doesn't contain widcards
                Posix.Glob pathMatcher = Posix.Glob();
                string path_glob = path_queue.pop_head();
                pathMatcher.glob(path_glob, Posix.GLOB_NOCHECK | Posix.GLOB_NOSORT);
                foreach (unowned string matched_path in pathMatcher.pathv) {
                    path_queue.push_head(matched_path);
                }

                // Path of config partial to be read
                string config_path = path_queue.pop_head();

                // Skip if the config partial already visited / read
                if (visited_paths.contains(config_path))
                    continue;
                visited_paths.add(config_path);

                // Read config partial and append to config builder
                string config_partial;
                try {
                    FileUtils.get_contents(config_path, out config_partial);
                } catch (GLib.Error err) {
                    continue;
                }

                configBuilder.append(config_partial);

                // Append paths of configs included from current config partial to queue for bfs
                string[] include_paths = get_includes_from_partial(config_partial);
                foreach (unowned string path in include_paths) {
                    path_queue.push_tail(path);
                }
            }
            return configBuilder.str;
        }

        private string get_i3_config(Json.Node responseJson) {

            var configBuilder = new StringBuilder("");
            var configs = responseJson.get_object().get_array_member("included_configs");

            configs.foreach_element((arr, index, node) => {
                configBuilder.append(node.get_object().get_string_member("variable_replaced_contents"));
            });

            return configBuilder.str;
        }

        private string get_sway_config(Json.Node responseJson) throws GLib.FileError {
            string baseConfig = responseJson.get_object().get_string_member("config");
            string walked_configs = walk_included_configs(baseConfig);
            return baseConfig + walked_configs;
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
            if (responseJson.has_member("class"))clazz = responseJson.get_string_member("class");
            if (responseJson.has_member("instance"))instance = responseJson.get_string_member("instance");
            if (responseJson.has_member("machine"))machine = responseJson.get_string_member("machine");
            if (responseJson.has_member("title"))title = responseJson.get_string_member("title");
            if (responseJson.has_member("window_role"))window_role = responseJson.get_string_member("window_role");
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
        private uint8[] terminator = { '\0' };
        private int bytes_to_payload = 14;
        private int buffer_size = 1024 * 128;
        private string wm_name;

        public IPCClient (string wm_name) throws GLib.Error {
            this.wm_name = wm_name;
            var socket_path = Environment.get_variable("I3SOCK");

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

        private string terminate_string(uint8[] rawString) {
            ByteArray b = new ByteArray();
            b.append(rawString);
            b.append(terminator);

            return (string) b.data;
        }

        private uint8[] generate_request(WM_COMMAND cmd) {
            ByteArray np = new ByteArray();

            np.append(magic_number);
            np.append(int32_to_uint8_array(0));   // payloadSize.get_data_as_bytes().get_data());
            np.append(int32_to_uint8_array(cmd));   // command.get_data_as_bytes().get_data());

            Bytes message = ByteArray.free_to_bytes(np);

            return message.get_data();
        }

        private Json.Node ? wm_ipc(WM_COMMAND command) throws GLib.Error {
            ssize_t sent = socket.send(generate_request(command));

            debug("Sent " + sent.to_string() + " bytes to " + wm_name);
            uint8[] buffer = new uint8[buffer_size];

            ssize_t len = socket.receive(buffer);

            debug("Received  " + len.to_string() + " bytes from " + wm_name);

            Bytes responseBytes = new Bytes.take(buffer[0 : len]);

            string payload = terminate_string(responseBytes.slice(bytes_to_payload, responseBytes.length).get_data());

            Json.Parser parser = new Json.Parser();
            parser.load_from_data(payload);

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
