/**
 * A client library for i3-wm that deserializes into idomatic Vala response objects.
 */
namespace Ilia {
    enum I3_COMMAND {
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

    public errordomain I3_ERROR {
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
            human_readable = responseJson.get_object ().get_string_member ("human_readable");
            loaded_config_file_name = responseJson.get_object ().get_string_member ("loaded_config_file_name");
            minor = responseJson.get_object ().get_string_member ("minor");
            patch = responseJson.get_object ().get_string_member ("patch");
            major = responseJson.get_object ().get_string_member ("major");
        }
    }

    // https://i3wm.org/docs/ipc.html#_config_reply
    public class ConfigReply {
        public string config { get; private set; }

        internal ConfigReply (Json.Node responseJson) {
            config = responseJson.get_object ().get_string_member ("config");
        }
    }

    public class WindowProperties {
        public string clazz { get; private set; }
        public string instance { get; private set; }
        public string machine { get; private set; }
        public string title { get; private set; }

        internal WindowProperties (Json.Object responseJson) {
            clazz = responseJson.get_string_member ("class");
            instance = responseJson.get_string_member ("instance");
            machine = responseJson.get_string_member ("machine");
            title = responseJson.get_string_member ("title");
        }
    }

    public class TreeReply {
        public string id { get; private set; }
        public string ntype { get; private set; }
        public bool urgent { get; private set; }
        public string output { get; private set; }
        public string name { get; private set; }
        public WindowProperties windowProperties { get; private set; }
        public TreeReply[] nodes { get; private set; }

        internal TreeReply (Json.Node responseJson) {
            id = responseJson.get_object ().get_string_member ("id");
            ntype = responseJson.get_object ().get_string_member ("type");
            urgent = responseJson.get_object ().get_boolean_member ("urgent");
            output = responseJson.get_object ().get_string_member ("output");
            name = responseJson.get_object ().get_string_member ("name");
            windowProperties = new WindowProperties(responseJson.get_object ().get_object_member ("window_properties"));

            var jnodes = responseJson.get_object ().get_array_member("nodes");

            if (jnodes == null || jnodes.get_length () == 0) {
                nodes = new TreeReply[0];
            } else {
                nodes = new TreeReply[jnodes.get_length ()];
                jnodes.foreach_element ((arr, index, node) => {
                    nodes[index] = new TreeReply(node);
                });
            }
        }
    }

    public class I3Client {
        private Socket socket;
        private uint8[] magic_number = "i3-ipc".data;
        private uint8[] terminator = { '\0' };
        private int bytes_to_payload = 14;
        private int buffer_size = 1024 * 128;

        public I3Client () throws GLib.Error {
            var socket_path = Environment.get_variable("I3SOCK");

            var socketAddress = new UnixSocketAddress (socket_path);

            socket = new Socket (SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
            assert (socket != null);

            socket.connect (socketAddress);
            socket.set_blocking (true);
        }

        ~I3Client () {
            if (socket != null) {
                socket.close ();
            }
        }

        private uint8[] int32_to_uint8_array (int32 input) {
            Variant val = new Variant.int32 (input);
            return val.get_data_as_bytes ().get_data ();
        }

        private string terminate_string (uint8[] rawString) {
            ByteArray b = new ByteArray ();
            b.append (rawString);
            b.append (terminator);

            return (string) b.data;
        }

        private uint8[] generate_request (I3_COMMAND cmd) {
            ByteArray np = new ByteArray ();

            np.append (magic_number);
            np.append (int32_to_uint8_array (0)); // payloadSize.get_data_as_bytes().get_data());
            np.append (int32_to_uint8_array (cmd)); // command.get_data_as_bytes().get_data());

            Bytes message = ByteArray.free_to_bytes (np);

            return message.get_data ();
        }

        private Json.Node ? i3_ipc (I3_COMMAND command) throws GLib.Error {
            ssize_t sent = socket.send (generate_request (command));

            debug ("Sent " + sent.to_string () + " bytes to i3.\n");
            uint8[] buffer = new uint8[buffer_size];

            ssize_t len = socket.receive (buffer);

            debug ("Received  " + len.to_string () + " bytes from i3.\n");

            Bytes responseBytes = new Bytes.take (buffer[0 : len]);

            string payload = terminate_string (responseBytes.slice (bytes_to_payload, responseBytes.length).get_data ());

            Json.Parser parser = new Json.Parser ();
            parser.load_from_data (payload);

            return parser.get_root ();
        }

        public VersionReply getVersion () throws I3_ERROR, GLib.Error {
            var response = i3_ipc (I3_COMMAND.GET_VERSION);

            if (response == null) {
                throw new I3_ERROR.RPC_ERROR ("No Response");
            }

            return new VersionReply (response);
        }

        public ConfigReply getConfig () throws I3_ERROR, GLib.Error {
            var response = i3_ipc (I3_COMMAND.GET_CONFIG);

            if (response == null) {
                throw new I3_ERROR.RPC_ERROR ("No Response");
            }

            return new ConfigReply (response);
        }

        public TreeReply getTree() throws I3_ERROR, GLib.Error {
            var response = i3_ipc (I3_COMMAND.GET_TREE);

            if (response == null) {
                throw new I3_ERROR.RPC_ERROR ("No Response");
            }

            return new TreeReply (response);
        }
    }
}
