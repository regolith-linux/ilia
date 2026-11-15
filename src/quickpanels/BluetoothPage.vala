namespace Ilia {
    /**
     * Connects and disconnects Bluetooth devices through BlueZ on the system bus.
     *
     * The devices listed are those that are paired or connected, or that have a name.
     * While the panel is open the powered adapters that were not looking for devices do;
     * they stop again before the launcher leaves.
     */
    class BluetoothPage : QuickPanelPage {
        private const string BLUEZ = "org.bluez";
        private const string ADAPTER_IFACE = "org.bluez.Adapter1";
        private const string DEVICE_IFACE = "org.bluez.Device1";
        private const string BATTERY_IFACE = "org.bluez.Battery1";

        private const string NO_ADAPTER = "No Bluetooth adapter";
        private const string POWERED_OFF = "Bluetooth is off";
        private const string POWERED_OFF_KEY = "status:" + POWERED_OFF;

        public const string STATE_CONNECTED = "Connected";
        public const string STATE_PAIRED = "Paired";

        public class Device {
            public string path;
            public string address;
            public string alias;
            public bool paired;
            public bool connected;
            public int battery = -1;

            // 0: connected, 1: paired, 2: the rest
            public int group() {
                return connected ? 0 : (paired ? 1 : 2);
            }

            public string state() {
                return connected ? STATE_CONNECTED : (paired ? STATE_PAIRED : "");
            }
        }

        // The devices of the last reading, by address, and the adapters
        private HashTable<string, Device> devices = new HashTable<string, Device>(str_hash, str_equal);
        private GenericArray<string> adapters = new GenericArray<string>();
        // The adapters this panel started discovery on, to stop it on exactly those
        private GenericArray<string> discovering = new GenericArray<string>();
        private bool discovery_started = false;

        public override string get_name() {
            return "<u>B</u>luetooth";
        }

        public override string get_icon_name() {
            return "bluetooth-symbolic";
        }

        public override string get_help() {
            return "This page lists Bluetooth devices. Enter connects the highlighted device, pairing with it first when needed, or disconnects it when it is connected.";
        }

        public override char get_keybinding() {
            return 'b';
        }

        public override HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);
            keybindings.set("enter", "Connect or Disconnect Device");
            return keybindings;
        }

        protected override async void start() {
            if (bus == null || !yield has_owner(BLUEZ)) {
                set_status(NO_ADAPTER);
                return;
            }
            follow_service(BLUEZ);
            yield refresh();
        }

        protected override async GenericArray<PanelRow> ? read_rows() {
            Variant objects;
            try {
                var reply = yield call(BLUEZ, "/", OBJECT_MANAGER_IFACE, "GetManagedObjects", null, "(a{oa{sa{sv}}})");
                objects = reply.get_child_value(0);
            } catch (GLib.Error err) {
                return null;
            }

            var found_adapters = new GenericArray<string>();
            var to_discover = new GenericArray<string>();
            bool any_powered = false;
            var found = new GenericArray<Device>();

            var iter = objects.iterator();
            string path;
            Variant interfaces;
            while (iter.next("{o@a{sa{sv}}}", out path, out interfaces)) {
                var adapter = interfaces.lookup_value(ADAPTER_IFACE, VariantType.VARDICT);
                if (adapter != null) {
                    found_adapters.add(path);
                    bool powered = bool_value(adapter, "Powered");
                    any_powered |= powered;
                    if (powered && !bool_value(adapter, "Discovering"))
                        to_discover.add(path);
                }

                var props = interfaces.lookup_value(DEVICE_IFACE, VariantType.VARDICT);
                if (props == null)
                    continue;
                var device = new Device();
                device.path = path;
                device.paired = bool_value(props, "Paired");
                device.connected = bool_value(props, "Connected");
                bool named = props.lookup_value("Name", null) != null;
                if (!device.paired && !device.connected && !named)
                    continue;
                device.address = string_value(props, "Address") ?? path;
                device.alias = string_value(props, "Alias") ?? string_value(props, "Name") ?? device.address;
                var battery = interfaces.lookup_value(BATTERY_IFACE, VariantType.VARDICT);
                if (battery != null) {
                    var percentage = battery.lookup_value("Percentage", VariantType.BYTE);
                    if (percentage != null)
                        device.battery = percentage.get_byte();
                }
                found.add(device);
            }

            // When the panel opens, the powered adapters that are not discovering start
            if (!discovery_started) {
                discovery_started = true;
                foreach (var adapter in to_discover.data)
                    start_discovery.begin(adapter);
            }

            adapters = found_adapters;
            devices = new HashTable<string, Device>(str_hash, str_equal);
            var rows = new GenericArray<PanelRow>();
            if (found_adapters.length == 0) {
                rows.add(new PanelRow.status_row(NO_ADAPTER));
                return rows;
            }
            if (!any_powered) {
                rows.add(new PanelRow.status_row(POWERED_OFF, "Off"));
                return rows;
            }

            found.sort(compare_devices);
            foreach (var device in found.data) {
                devices.insert(device.address, device);
                string detail = device.battery >= 0 ? "%d %%".printf(device.battery) : "";
                rows.add(new PanelRow(device.address, device.alias, detail, device.state()));
            }
            return rows;
        }

        // Counted as started while the call is out, since the launcher may leave before the reply
        private async void start_discovery(string adapter) {
            discovering.add(adapter);
            try {
                yield call(BLUEZ, adapter, ADAPTER_IFACE, "StartDiscovery", null, null, ACTION_TIMEOUT_MS);
            } catch (GLib.Error err) {
                // An error reply means it did not start; with no reply it may have
                if (!(err is IOError.TIMED_OUT))
                    remove_path(discovering, adapter);
            }
        }

        /**
         * Remove the first entry equal to path. GenericArray.remove() compares pointers, and
         * the array holds its own copies of the strings.
         */
        public static bool remove_path(GenericArray<string> paths, string path) {
            uint index;
            if (!paths.find_with_equal_func(path, str_equal, out index))
                return false;
            paths.remove_index(index);
            return true;
        }

        // Stop discovery where this panel started it. The launcher is leaving: do not wait for replies
        protected override void leaving() {
            if (bus == null || discovering.length == 0)
                return;
            foreach (var adapter in discovering.data) {
                var message = new DBusMessage.method_call(BLUEZ, adapter, ADAPTER_IFACE, "StopDiscovery");
                message.set_flags(DBusMessageFlags.NO_REPLY_EXPECTED);
                try {
                    bus.send_message(message, DBusSendMessageFlags.NONE, null);
                } catch (GLib.Error err) {
                }
            }
            discovering = new GenericArray<string>();
            try {
                bus.flush_sync(null);
            } catch (GLib.Error err) {
            }
        }

        protected override async void activate(string key) {
            if (key == POWERED_OFF_KEY) {
                yield power_on();
                return;
            }

            var device = devices.lookup(key);
            if (device == null)
                return;

            try {
                if (device.connected) {
                    yield call(BLUEZ, device.path, DEVICE_IFACE, "Disconnect", null, null, ACTION_TIMEOUT_MS);
                } else if (device.paired) {
                    yield call(BLUEZ, device.path, DEVICE_IFACE, "Connect", null, null, ACTION_TIMEOUT_MS);
                } else {
                    // Each step waits for the previous one; the first error ends the sequence
                    yield call(BLUEZ, device.path, DEVICE_IFACE, "Pair", null, null, ACTION_TIMEOUT_MS);
                    yield write_property(BLUEZ, device.path, DEVICE_IFACE, "Trusted", new Variant.boolean(true));
                    yield call(BLUEZ, device.path, DEVICE_IFACE, "Connect", null, null, ACTION_TIMEOUT_MS);
                }
                finish();
            } catch (GLib.Error err) {
                report_failure(device.alias, err);
            }
        }

        // Power every adapter on, all at once; one failure is reported. The launcher stays open
        private async void power_on() {
            if (adapters.length == 0)
                return;
            int pending = adapters.length;
            GLib.Error ? failure = null;
            foreach (var adapter in adapters.data) {
                write_property.begin(BLUEZ, adapter, ADAPTER_IFACE, "Powered", new Variant.boolean(true), (obj, res) => {
                    try {
                        write_property.end(res);
                    } catch (GLib.Error err) {
                        if (failure == null)
                            failure = err.copy();
                    }
                    if (--pending == 0)
                        power_on.callback();
                });
            }
            yield;
            if (failure != null)
                report_failure(POWERED_OFF, failure);
        }

        /**
         * Connected devices first, then paired ones, then the rest; within each group by
         * name ignoring case (case-folded, code point order), then by address.
         */
        public static int compare_devices(Device a, Device b) {
            if (a.group() != b.group())
                return a.group() < b.group() ? -1 : 1;
            int by_name = strcmp(a.alias.casefold(), b.alias.casefold());
            if (by_name != 0)
                return by_name;
            return strcmp(a.address, b.address);
        }

        private static bool bool_value(Variant props, string name) {
            var value = props.lookup_value(name, VariantType.BOOLEAN);
            return value != null && value.get_boolean();
        }

        private static string ? string_value(Variant props, string name) {
            var value = props.lookup_value(name, VariantType.STRING);
            return value != null ? value.get_string() : null;
        }
    }
}
