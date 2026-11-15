namespace Ilia {
    /**
     * Joins and leaves wireless networks through NetworkManager on the system bus.
     *
     * There is a row for each network name (SSID, compared byte for byte) that the access
     * points of the Wi-Fi devices offer. The access point with the strongest signal stands
     * for the network (on a tie the first one listed, devices in NetworkManager's order),
     * and its device is the network's device.
     */
    class WifiPage : QuickPanelPage {
        private const string NM = "org.freedesktop.NetworkManager";
        private const string NM_PATH = "/org/freedesktop/NetworkManager";
        private const string NM_IFACE = "org.freedesktop.NetworkManager";
        private const string SETTINGS_PATH = "/org/freedesktop/NetworkManager/Settings";
        private const string SETTINGS_IFACE = "org.freedesktop.NetworkManager.Settings";
        private const string CONNECTION_IFACE = "org.freedesktop.NetworkManager.Settings.Connection";
        private const string DEVICE_IFACE = "org.freedesktop.NetworkManager.Device";
        private const string WIRELESS_IFACE = "org.freedesktop.NetworkManager.Device.Wireless";
        private const string AP_IFACE = "org.freedesktop.NetworkManager.AccessPoint";
        private const string ACTIVE_IFACE = "org.freedesktop.NetworkManager.Connection.Active";

        private const uint DEVICE_TYPE_WIFI = 2;
        private const uint ACTIVE_STATE_ACTIVATING = 1;
        private const uint ACTIVE_STATE_ACTIVATED = 2;

        public const uint AP_FLAGS_PRIVACY = 0x1;
        public const uint AP_SEC_KEY_MGMT_PSK = 0x100;
        public const uint AP_SEC_KEY_MGMT_802_1X = 0x200;
        public const uint AP_SEC_KEY_MGMT_SAE = 0x400;

        public const string STATE_CONNECTED = "Connected";
        public const string STATE_CONNECTING = "Connecting";
        public const string STATE_SAVED = "Saved";
        public const string STATE_OPEN = "Open";
        public const string STATE_ENTERPRISE = "Enterprise";
        public const string STATE_SECURED = "Secured";

        private const string NOT_AVAILABLE = "Wi-Fi is not available";
        private const string NO_ADAPTER = "No Wi-Fi adapter";
        private const string RADIO_OFF = "Wi-Fi is off";
        private const string RADIO_OFF_KEY = "status:" + RADIO_OFF;

        private class AccessPoint {
            public string path;
            public string device;
            public Bytes ssid;
            public uint strength;
            public uint flags;
            public uint wpa_flags;
            public uint rsn_flags;
        }

        private class Network {
            public string key;
            public string name;
            public Bytes ssid;
            // The access point that stands for the network, and the paths of all of them
            public AccessPoint ap;
            public GenericArray<string> ap_paths = new GenericArray<string>();
            public string state;
            // The active connection of a connected or connecting network
            public string ? active_connection;
            // The first saved connection for the network
            public string ? saved_connection;
        }

        // The networks of the last reading, by key
        private HashTable<string, Network> networks = new HashTable<string, Network>(str_hash, str_equal);
        // Every Wi-Fi device is asked to scan once, when the panel opens
        private bool scan_requested = false;

        public override string get_name() {
            return "<u>W</u>i-Fi";
        }

        public override string get_icon_name() {
            return "network-wireless-symbolic";
        }

        public override string get_help() {
            return "This page lists the wireless networks around. Enter joins the highlighted network, asking for its password when it needs one, or leaves it when it is connected.";
        }

        public override char get_keybinding() {
            return 'w';
        }

        public override HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);
            keybindings.set("enter", "Join or Leave Network");
            keybindings.set("escape", "Leave Password Prompt");
            return keybindings;
        }

        protected override async void start() {
            if (bus == null || !yield has_owner(NM)) {
                set_status(NOT_AVAILABLE);
                return;
            }
            follow_service(NM);
            yield refresh();
        }

        protected override async GenericArray<PanelRow> ? read_rows() {
            try {
                bool enabled = (yield read_property(NM, NM_PATH, NM_IFACE, "WirelessEnabled")).get_boolean();

                var devices = new GenericArray<string>();
                var reply = yield call(NM, NM_PATH, NM_IFACE, "GetDevices", null, "(ao)");
                foreach (var device in object_paths(reply.get_child_value(0))) {
                    try {
                        if ((yield read_property(NM, device, DEVICE_IFACE, "DeviceType")).get_uint32() == DEVICE_TYPE_WIFI)
                            devices.add(device);
                    } catch (GLib.Error err) {
                        // The device went away meanwhile
                    }
                }

                if (!scan_requested) {
                    scan_requested = true;
                    foreach (var device in devices.data)
                        request_scan.begin(device);
                }

                var rows = new GenericArray<PanelRow>();
                if (devices.length == 0) {
                    networks.remove_all();
                    rows.add(new PanelRow.status_row(NO_ADAPTER));
                    return rows;
                }
                if (!enabled) {
                    networks.remove_all();
                    rows.add(new PanelRow.status_row(RADIO_OFF, "Off"));
                    return rows;
                }

                var found = yield read_networks(devices);
                networks = new HashTable<string, Network>(str_hash, str_equal);
                foreach (var network in found.data) {
                    networks.insert(network.key, network);
                    rows.add(new PanelRow(network.key, network.name, "%u %%".printf(network.ap.strength), network.state));
                }
                return rows;
            } catch (GLib.Error err) {
                return null;
            }
        }

        // The networks of the devices' access points, with their states, in the order they are listed
        private async GenericArray<Network> read_networks(GenericArray<string> devices) throws GLib.Error {
            var by_key = new HashTable<string, Network>(str_hash, str_equal);
            var list = new GenericArray<Network>();
            var active_connections = new GenericArray<string>();

            foreach (var device in devices.data) {
                string active = (yield read_property(NM, device, DEVICE_IFACE, "ActiveConnection")).get_string();
                if (active != "/")
                    active_connections.add(active);

                var access_points = yield read_property(NM, device, WIRELESS_IFACE, "AccessPoints");
                foreach (var path in object_paths(access_points)) {
                    AccessPoint ap;
                    try {
                        ap = yield read_access_point(device, path);
                    } catch (GLib.Error err) {
                        continue; // Gone meanwhile
                    }
                    if (ap.ssid.get_size() == 0)
                        continue;

                    string key = ssid_key(ap.ssid);
                    var network = by_key.lookup(key);
                    if (network == null) {
                        network = new Network();
                        network.key = key;
                        network.ssid = ap.ssid;
                        network.name = ssid_name(ap.ssid);
                        network.ap = ap;
                        by_key.insert(key, network);
                        list.add(network);
                    } else if (ap.strength > network.ap.strength) {
                        network.ap = ap;
                    }
                    network.ap_paths.add(ap.path);
                }
            }

            // Connected or connecting: a device's active connection is on one of the network's access points
            foreach (var active in active_connections.data) {
                Variant props;
                try {
                    props = yield get_all(NM, active, ACTIVE_IFACE);
                } catch (GLib.Error err) {
                    continue;
                }
                var specific = props.lookup_value("SpecificObject", VariantType.OBJECT_PATH);
                var state = props.lookup_value("State", VariantType.UINT32);
                if (specific == null || state == null)
                    continue;
                string ? state_name = null;
                if (state.get_uint32() == ACTIVE_STATE_ACTIVATED)
                    state_name = STATE_CONNECTED;
                else if (state.get_uint32() == ACTIVE_STATE_ACTIVATING)
                    state_name = STATE_CONNECTING;
                if (state_name == null)
                    continue;
                foreach (var network in list.data) {
                    if (network.active_connection == null && has_path(network.ap_paths, specific.get_string())) {
                        network.active_connection = active;
                        network.state = state_name;
                    }
                }
            }

            // Saved: a saved connection is for the network's SSID
            var connections = yield call(NM, SETTINGS_PATH, SETTINGS_IFACE, "ListConnections", null, "(ao)");
            foreach (var connection in object_paths(connections.get_child_value(0))) {
                Bytes ? ssid;
                try {
                    ssid = yield read_saved_ssid(connection);
                } catch (GLib.Error err) {
                    continue;
                }
                if (ssid == null)
                    continue;
                var network = by_key.lookup(ssid_key(ssid));
                if (network != null && network.saved_connection == null)
                    network.saved_connection = connection;
            }

            foreach (var network in list.data) {
                if (network.state != null)
                    continue;
                if (network.saved_connection != null)
                    network.state = STATE_SAVED;
                else
                    network.state = security_state(network.ap.flags, network.ap.wpa_flags, network.ap.rsn_flags);
            }

            list.sort(compare_networks);
            return list;
        }

        private async AccessPoint read_access_point(string device, string path) throws GLib.Error {
            var props = yield get_all(NM, path, AP_IFACE);
            var ap = new AccessPoint();
            ap.path = path;
            ap.device = device;
            var ssid = props.lookup_value("Ssid", new VariantType("ay"));
            ap.ssid = ssid != null ? ssid.get_data_as_bytes() : new Bytes(null);
            var strength = props.lookup_value("Strength", VariantType.BYTE);
            ap.strength = strength != null ? strength.get_byte() : 0;
            ap.flags = uint_value(props, "Flags");
            ap.wpa_flags = uint_value(props, "WpaFlags");
            ap.rsn_flags = uint_value(props, "RsnFlags");
            return ap;
        }

        // The SSID of a saved Wi-Fi connection; null for other connections
        private async Bytes ? read_saved_ssid(string connection) throws GLib.Error {
            var reply = yield call(NM, connection, CONNECTION_IFACE, "GetSettings", null, "(a{sa{sv}})");
            var wireless = reply.get_child_value(0).lookup_value("802-11-wireless", new VariantType("a{sv}"));
            if (wireless == null)
                return null;
            var ssid = wireless.lookup_value("ssid", new VariantType("ay"));
            return ssid != null ? ssid.get_data_as_bytes() : null;
        }

        private async void request_scan(string device) {
            try {
                yield call(NM, device, WIRELESS_IFACE, "RequestScan", new Variant("(a{sv})", new VariantBuilder(VariantType.VARDICT)), null, ACTION_TIMEOUT_MS);
            } catch (GLib.Error err) {
                // A device may refuse to scan, as when the radio is off; the list shows what it has
            }
        }

        protected override async void activate(string key) {
            if (key == RADIO_OFF_KEY) {
                try {
                    yield write_property(NM, NM_PATH, NM_IFACE, "WirelessEnabled", new Variant.boolean(true));
                } catch (GLib.Error err) {
                    report_failure(RADIO_OFF, err);
                }
                return; // The networks are listed once NetworkManager reports them
            }

            var network = networks.lookup(key);
            if (network == null)
                return;

            try {
                switch (network.state) {
                    case STATE_CONNECTED:
                    case STATE_CONNECTING:
                        yield call(NM, NM_PATH, NM_IFACE, "DeactivateConnection",
                                   new Variant("(o)", network.active_connection), null, ACTION_TIMEOUT_MS);
                        finish();
                        break;
                    case STATE_SAVED:
                        yield call(NM, NM_PATH, NM_IFACE, "ActivateConnection",
                                   new Variant("(ooo)", network.saved_connection, network.ap.device, network.ap.path),
                                   null, ACTION_TIMEOUT_MS);
                        finish();
                        break;
                    case STATE_OPEN:
                        yield add_and_activate(network, null);
                        finish();
                        break;
                    case STATE_ENTERPRISE:
                        break; // Needs credentials this panel does not ask for
                    default:
                        open_prompt(key);
                        break;
                }
            } catch (GLib.Error err) {
                report_failure(network.name, err);
            }
        }

        protected override async void submit_password(string key, string password) {
            if (!is_valid_password(password))
                return;
            var network = networks.lookup(key);
            if (network == null)
                return;
            try {
                yield add_and_activate(network, password);
                finish();
            } catch (GLib.Error err) {
                report_failure(network.name, err); // The prompt stays, with the password typed
            }
        }

        // A new connection for the network, on its device and access point; with a password for a secured one
        private async void add_and_activate(Network network, string ? password) throws GLib.Error {
            var settings = new VariantBuilder(new VariantType("a{sa{sv}}"));

            var wireless = new VariantBuilder(VariantType.VARDICT);
            wireless.add("{sv}", "ssid", new Variant.from_bytes(new VariantType("ay"), network.ssid, true));
            settings.add("{sa{sv}}", "802-11-wireless", wireless);

            if (password != null) {
                var security = new VariantBuilder(VariantType.VARDICT);
                security.add("{sv}", "key-mgmt", new Variant.string(key_management(network.ap.wpa_flags, network.ap.rsn_flags)));
                security.add("{sv}", "psk", new Variant.string(password));
                settings.add("{sa{sv}}", "802-11-wireless-security", security);
            }

            var parameters = new Variant("(a{sa{sv}}oo)", settings, network.ap.device, network.ap.path);
            yield call(NM, NM_PATH, NM_IFACE, "AddAndActivateConnection", parameters, null, ACTION_TIMEOUT_MS);
        }

        /**
         * The state of a network that is neither active nor saved, from the flags of its access
         * point: Open without privacy and with no WPA or RSN flags; Enterprise with 802.1X key
         * management and neither PSK nor SAE; Secured otherwise.
         */
        public static string security_state(uint flags, uint wpa_flags, uint rsn_flags) {
            uint security = wpa_flags | rsn_flags;
            if ((flags & AP_FLAGS_PRIVACY) == 0 && wpa_flags == 0 && rsn_flags == 0)
                return STATE_OPEN;
            if ((security & AP_SEC_KEY_MGMT_802_1X) != 0 && (security & (AP_SEC_KEY_MGMT_PSK | AP_SEC_KEY_MGMT_SAE)) == 0)
                return STATE_ENTERPRISE;
            return STATE_SECURED;
        }

        /**
         * The key management for a password: sae when only SAE is offered (RSN SAE, and PSK
         * in neither WPA nor RSN), wpa-psk otherwise.
         */
        public static string key_management(uint wpa_flags, uint rsn_flags) {
            if ((rsn_flags & AP_SEC_KEY_MGMT_SAE) != 0 && ((wpa_flags | rsn_flags) & AP_SEC_KEY_MGMT_PSK) == 0)
                return "sae";
            return "wpa-psk";
        }

        // A passphrase of 8 to 63 characters, or a key of exactly 64 hexadecimal digits
        public static bool is_valid_password(string password) {
            int length = password.char_count();
            if (length >= 8 && length <= 63)
                return true;
            if (length != 64)
                return false;
            for (int i = 0; i < password.length; ++i) {
                if (!password[i].isxdigit())
                    return false;
            }
            return true;
        }

        // The SSID as text: UTF-8, with every invalid sequence replaced by U+FFFD
        public static string ssid_name(Bytes ssid) {
            unowned uint8[] data = ssid.get_data();
            if (data == null || data.length == 0)
                return "";
            return ((string) data).make_valid((ssize_t) data.length);
        }

        // Identifies a network by the bytes of its SSID
        private static string ssid_key(Bytes ssid) {
            var key = new StringBuilder("ssid:");
            unowned uint8[] data = ssid.get_data();
            if (data != null) {
                foreach (uint8 byte in data)
                    key.append_printf("%02x", byte);
            }
            return key.str;
        }

        // Active networks first, then the strongest, then by name in code point order
        private static int compare_networks(Network a, Network b) {
            bool a_active = a.active_connection != null;
            bool b_active = b.active_connection != null;
            if (a_active != b_active)
                return a_active ? -1 : 1;
            if (a.ap.strength != b.ap.strength)
                return a.ap.strength > b.ap.strength ? -1 : 1;
            int by_name = strcmp(a.name, b.name);
            if (by_name != 0)
                return by_name;
            return strcmp(a.key, b.key);
        }

        private static bool has_path(GenericArray<string> paths, string path) {
            foreach (var candidate in paths.data) {
                if (candidate == path)
                    return true;
            }
            return false;
        }

        private static string[] object_paths(Variant array) {
            string[] paths = {};
            var iter = array.iterator();
            Variant ? child;
            while ((child = iter.next_value()) != null)
                paths += child.get_string();
            return paths;
        }

        private static uint uint_value(Variant props, string name) {
            var value = props.lookup_value(name, VariantType.UINT32);
            return value != null ? value.get_uint32() : 0;
        }
    }
}
