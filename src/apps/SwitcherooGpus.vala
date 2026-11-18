namespace Ilia {
    /*
     * The environment that makes a program run on the other GPU, from the GPUs property of
     * switcheroo-control (a list of dictionaries with Name, Default, Discrete and Environment)
     *
     * The GPU is the first discrete one that is not the default, else the first discrete one,
     * else the first one that is not the default; at each step a GPU without an Environment
     * is passed over. Its Environment holds names and values in turn: the result is those
     * pairs, without a name left over at the end. Empty when no GPU qualifies, and when the
     * GPU found has an empty Environment.
     */
    public static string[] other_gpu_environment(Variant ? gpus) {
        string[] environment = {};
        if (gpus == null || !gpus.is_of_type(new VariantType("aa{sv}")))
            return environment;

        for (int step = 0; step < 3; ++step) {
            for (size_t i = 0; i < gpus.n_children(); ++i) {
                var gpu = gpus.get_child_value(i);
                var is_default = gpu.lookup_value("Default", VariantType.BOOLEAN);
                var is_discrete = gpu.lookup_value("Discrete", VariantType.BOOLEAN);
                bool default_gpu = is_default != null && is_default.get_boolean();
                bool discrete_gpu = is_discrete != null && is_discrete.get_boolean();

                bool qualifies;
                if (step == 0)
                    qualifies = discrete_gpu && !default_gpu;
                else if (step == 1)
                    qualifies = discrete_gpu;
                else
                    qualifies = !default_gpu;
                if (!qualifies)
                    continue;

                var gpu_environment = gpu.lookup_value("Environment", VariantType.STRING_ARRAY);
                if (gpu_environment == null)
                    continue;

                string[] names_and_values = gpu_environment.get_strv();
                for (int pair = 0; pair + 1 < names_and_values.length; pair += 2) {
                    environment += names_and_values[pair];
                    environment += names_and_values[pair + 1];
                }
                return environment;
            }
        }
        return environment;
    }

    /*
     * What switcheroo-control says about the GPUs: whether the machine has two, and the
     * variables that start a program on the other one. It starts out unknown, is filled in by
     * reading the properties, and follows the service's PropertiesChanged signal: a property
     * sent with its new value takes that value, and one that is only invalidated is unknown
     * until it has been read again.
     */
    public class GpuState : Object {
        public const string HAS_DUAL_GPU = "HasDualGpu";
        public const string GPUS = "GPUs";

        // Null when unknown
        public bool ? has_dual_gpu = null;
        // Names and values in turn; empty when unknown, and when no GPU supplies any
        public string[] other_gpu_env = {};

        // Bumped whenever a property's value is set or invalidated, so that a read that was
        // started before then cannot overwrite the newer information when it completes
        private uint has_dual_gpu_serial = 0;
        private uint gpus_serial = 0;

        /* The serial of each of the properties named, for apply_read */
        public uint[] serials_of(string[] names) {
            uint[] serials = {};
            foreach (unowned string name in names)
                serials += name == HAS_DUAL_GPU ? has_dual_gpu_serial : gpus_serial;
            return serials;
        }

        private void set_has_dual_gpu(Variant ? value) {
            if (value != null && value.is_of_type(VariantType.BOOLEAN))
                has_dual_gpu = value.get_boolean();
            else
                has_dual_gpu = null;
        }

        private void set_gpus(Variant ? value) {
            other_gpu_env = other_gpu_environment(value);
        }

        /*
         * Take the result of reading the properties named (an a{sv} of the properties the
         * service gave), whose serials were serials_of(names) when the read was started.
         * A property the read did not return is unknown. A property that has changed since the
         * read was started keeps its newer information.
         */
        public void apply_read(Variant properties, string[] names, uint[] serials) {
            for (int i = 0; i < names.length && i < serials.length; ++i) {
                if (serials_of({ names[i] })[0] != serials[i])
                    continue;
                if (names[i] == HAS_DUAL_GPU)
                    set_has_dual_gpu(properties.lookup_value(HAS_DUAL_GPU, null));
                else if (names[i] == GPUS)
                    set_gpus(properties.lookup_value(GPUS, null));
            }
        }

        /*
         * Take a PropertiesChanged signal, its parameters being the interface name, the
         * changed properties with their values, and the invalidated property names (sa{sv}as).
         * Returns the names of the properties that were invalidated without a value, which are
         * now unknown and should be read again. Signals for another interface change nothing.
         */
        public string[] properties_changed(Variant parameters, string interface_name) {
            string[] to_read = {};
            if (!parameters.is_of_type(new VariantType("(sa{sv}as)")))
                return to_read;
            if (parameters.get_child_value(0).get_string() != interface_name)
                return to_read;

            var changed = parameters.get_child_value(1);
            var dual = changed.lookup_value(HAS_DUAL_GPU, null);
            if (dual != null) {
                set_has_dual_gpu(dual);
                has_dual_gpu_serial++;
            }
            var gpus = changed.lookup_value(GPUS, null);
            if (gpus != null) {
                set_gpus(gpus);
                gpus_serial++;
            }

            string[] invalidated = parameters.get_child_value(2).get_strv();
            foreach (unowned string name in invalidated) {
                if (name == HAS_DUAL_GPU && dual == null && !(HAS_DUAL_GPU in to_read)) {
                    set_has_dual_gpu(null);
                    has_dual_gpu_serial++;
                    to_read += HAS_DUAL_GPU;
                } else if (name == GPUS && gpus == null && !(GPUS in to_read)) {
                    set_gpus(null);
                    gpus_serial++;
                    to_read += GPUS;
                }
            }
            return to_read;
        }
    }

    /*
     * The GPUs of the machine as switcheroo-control reports them on the system bus
     *
     * start() reads them without blocking and follows the service's PropertiesChanged signal
     * from then on. Without the service, or when it fails, nothing is known about them.
     */
    public class SwitcherooGpus : Object {
        private const string BUS_NAME = "net.hadess.SwitcherooControl";
        private const string OBJECT_PATH = "/net/hadess/SwitcherooControl";
        private const string PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties";

        private GpuState state = new GpuState();
        private DBusConnection ? bus = null;
        // Set once the first read has completed or failed
        private bool first_read_done = false;
        // Reads of properties the service invalidated without a value, not yet answered
        private int rereads_pending = 0;
        // The caller of wait(), while it waits
        private SourceFunc ? waiter = null;
        private uint waiter_timeout_id = 0;

        /* Whether the machine has two GPUs; null when unknown */
        public bool ? has_dual_gpu() {
            return state.has_dual_gpu;
        }

        /*
         * The variables that start a program on the other GPU, names and values in turn; empty
         * when unknown, and when no GPU supplies any
         */
        public string[] other_gpu_env() {
            return state.other_gpu_env;
        }

        /* Read the GPU information, and follow the service's announcements of changes to it */
        public async void start() {
            try {
                bus = yield Bus.get(BusType.SYSTEM);
                // Subscribe before reading, so that no change made after the read is missed
                bus.signal_subscribe(BUS_NAME, PROPERTIES_INTERFACE, "PropertiesChanged", OBJECT_PATH, BUS_NAME,
                                     DBusSignalFlags.NONE, on_properties_changed);
                string[] names = { GpuState.HAS_DUAL_GPU, GpuState.GPUS };
                var serials = state.serials_of(names);
                var properties = yield get_all();
                state.apply_read(properties, names, serials);
            } catch (GLib.Error e) {
                debug("No GPU information from switcheroo-control: %s", e.message);
            }
            first_read_done = true;
            if (ready())
                wake_waiter();
        }

        /*
         * Wait until the GPU information has been read, including the properties being read
         * again, or until deadline (monotonic time) has passed. True if the first read had
         * completed by then; a property whose new value has not arrived by then is unknown.
         * One caller at a time.
         */
        public async bool wait(int64 deadline) {
            return_val_if_fail(waiter == null, first_read_done);
            if (!ready()) {
                int64 remaining_ms = (deadline - get_monotonic_time()) / 1000;
                if (remaining_ms > 0) {
                    waiter = wait.callback;
                    waiter_timeout_id = Timeout.add((uint) remaining_ms, () => {
                        waiter_timeout_id = 0;
                        wake_waiter();
                        return Source.REMOVE;
                    });
                    yield;
                }
            }
            return first_read_done;
        }

        /* True when the first read has completed and no property is being read again */
        private bool ready() {
            return first_read_done && rereads_pending == 0;
        }

        private void wake_waiter() {
            if (waiter_timeout_id != 0) {
                Source.remove(waiter_timeout_id);
                waiter_timeout_id = 0;
            }
            if (waiter != null) {
                var resume = (owned) waiter;
                resume();
            }
        }

        /* All the properties of switcheroo-control, as an a{sv} */
        private async Variant get_all() throws GLib.Error {
            // No timeout: a launch waits for the reply only until its own deadline
            var reply = yield bus.call(BUS_NAME, OBJECT_PATH, PROPERTIES_INTERFACE, "GetAll",
                                       new Variant("(s)", BUS_NAME), new VariantType("(a{sv})"),
                                       DBusCallFlags.NO_AUTO_START, int.MAX);
            return reply.get_child_value(0);
        }

        /* Take the new values the service sends, and read again the properties it only invalidated */
        private void on_properties_changed(DBusConnection connection, string ? sender_name, string object_path,
                                           string interface_name, string signal_name, Variant parameters) {
            string[] to_read = state.properties_changed(parameters, BUS_NAME);
            if (to_read.length > 0)
                reread.begin((owned) to_read);
        }

        private async void reread(owned string[] names) {
            var serials = state.serials_of(names);
            rereads_pending++;
            try {
                var properties = yield get_all();
                state.apply_read(properties, names, serials);
            } catch (GLib.Error e) {
                // The properties stay unknown
                debug("Could not read the GPU information again from switcheroo-control: %s", e.message);
            }
            rereads_pending--;
            if (ready())
                wake_waiter();
        }
    }
}
