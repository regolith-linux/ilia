using Gtk;

namespace Ilia {
    /**
     * Evaluates the entry text as it is typed and shows its value on a line below the entry.
     * Enter prints the value and keeps it on the clipboard.
     *
     * Each value is worked out by a helper process (see ilia-calculator.cc), which is ended
     * as soon as the text changes again or the evaluation takes too long.
     */
    class CalculatorPage : DialogPage, GLib.Object {
        // An evaluation is given up when it has not finished this long after the latest change
        private const uint EVALUATION_TIMEOUT_MS = 3000;
        private const string TOO_LONG = "Too long";

        private Gtk.Entry entry;
        private Gtk.Label answer_label;
        private Gtk.Widget root_widget;
        private SessionContoller session_controller;
        // The decimal separator of the locale, in the values shown
        private string decimal_mark;
        // The program that works out a value
        private string helper;

        // The value of the entry text, or null if it has none (yet)
        private string ? value = null;

        // The running evaluation
        private Subprocess ? helper_process = null;
        private Cancellable ? evaluation = null;
        private uint timeout_id = 0;
        // Enter was pressed while the value was being worked out: confirm it once it is known
        private bool confirm_when_known = false;

        public string get_name() {
            return "Ca<u>l</u>culator";
        }

        public string get_icon_name() {
            return "accessories-calculator";
        }

        public string get_help() {
            return "This dialog evaluates the typed expression as you type. Enter prints the value and puts it on the clipboard, where it stays after the dialog closes.";
        }

        public char get_keybinding() {
            return 'l';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Print and Copy Value");

            return keybindings;
        }

        public void show() {
            entry.grab_focus_without_selecting();
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            decimal_mark = Posix.nl_langinfo(Posix.NLItem.RADIXCHAR);
            if (decimal_mark == "")
                decimal_mark = ".";
            helper = Calculator.helper_path();

            // A line of text, shown even while it is empty
            answer_label = new Gtk.Label("");
            answer_label.xalign = 0;
            answer_label.single_line_mode = true;
            answer_label.margin = 8;
            answer_label.get_style_context().add_class("calculator_answer");

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            box.pack_start(answer_label, false, false, 0);
            box.destroy.connect(stop_evaluation);
            root_widget = box;
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        public void on_entry_changed() {
            stop_evaluation();
            confirm_when_known = false;
            show_value(null);

            string ? expression = Calculator.to_expression(entry.text);
            if (expression != null)
                evaluate.begin(expression);
        }

        public void on_entry_activated() {
            confirm_value();
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (event_key.keyval == KEY_CODE_ENTER || event_key.keyval == KEY_CODE_KP_ENTER) {
                confirm_value();
                return true;
            }
            return false;
        }

        // Print the value and keep it on the clipboard. While the value is still being worked
        // out, do that once it is known. Without a value, do nothing at all.
        private void confirm_value() {
            if (value == null) {
                confirm_when_known = evaluation != null;
                return;
            }

            stdout.printf("%s\n", value);
            stdout.flush();
            ClipboardHolder.hold(entry.get_display(), value);
            session_controller.quit();
        }

        private async void evaluate(string expression) {
            var cancellable = new Cancellable();
            evaluation = cancellable;
            timeout_id = Timeout.add(EVALUATION_TIMEOUT_MS, () => {
                timeout_id = 0;
                stop_evaluation();
                confirm_when_known = false;
                answer_label.label = TOO_LONG;
                return Source.REMOVE;
            });

            string ? output = null;
            try {
                helper_process = new Subprocess.newv({ helper, expression }, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                yield helper_process.communicate_utf8_async(null, cancellable, out output, null);
            } catch (GLib.Error e) {
                if (!cancellable.is_cancelled())
                    stderr.printf("Cannot evaluate %s: %s\n", expression, e.message);
            }
            if (cancellable.is_cancelled())
                return; // The text changed, the evaluation took too long, or the page is gone

            stop_evaluation();
            show_value(Calculator.read_helper_output(output, decimal_mark));
            if (confirm_when_known) {
                confirm_when_known = false;
                confirm_value();
            }
        }

        // Abandon the running evaluation, if any, and end its helper process
        private void stop_evaluation() {
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            if (evaluation != null) {
                evaluation.cancel();
                evaluation = null;
            }
            if (helper_process != null) {
                helper_process.force_exit();
                helper_process = null;
            }
        }

        private void show_value(string ? new_value) {
            value = new_value;
            answer_label.label = value ?? "";
        }
    }
}
