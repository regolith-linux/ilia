using Gtk;

namespace Ilia {
    /**
     * A page from a file whose rows are lines of text: the file's Items, or what its ItemsCommand prints
     *
     * The command runs in the background once the page is first shown: its lines become rows
     * as they arrive, and it is stopped when the page goes away. A row shows and is searched by
     * its label; choosing it runs the file's Exec with its value, or prints the value when the
     * file has no Exec.
     *
     * With Sort=frequency the rows chosen most often come first, the others keep their order,
     * and each choice is recorded in the launch history as <page id>#<value>.
     */
    class PageFileTextPage : PageFilePage {
        private const int ITEM_VIEW_COLUMN_ICON = 0;

        // The widget to display the rows
        private Gtk.TreeView item_view;
        // The rows so far, and the ones matching the entry text
        private TextFilter text_filter;
        // View on the matching rows
        private FilteredLinesModel model;
        // Filters and fills the view from idle
        private FilterWork work;
        private Gtk.TreePath path;
        private Gtk.Widget root_widget;
        private Gtk.Entry entry;
        private GLib.Settings settings;
        private SessionContoller session_controller;
        // Rows show the page icon, unless icon-size is 0
        private bool with_icon;
        // Of each row, in the order of the filter's lines: the label is the filter's line
        private string[] labels = {};
        private string[] values = {};
        // Sort=frequency: how often each row was chosen, and how often each value was
        private int[] counts = {};
        private HashTable<string, int> value_counts;
        // The ItemsCommand was started, or the Items were added
        private bool rows_requested = false;
        // The ItemsCommand while it may still run; it leads a process group of its own
        private Subprocess ? command = null;
        private int command_pid = 0;
        // A row was chosen, or the view is gone: nothing more is done
        private bool closed = false;

        public PageFileTextPage (PageFile file, char keybinding) {
            base(file, keybinding);
        }

        public override string get_help() {
            if (file.exec_argv != null)
                return "This page lists the rows given by the page file %s. Choosing a row runs its command for that row.".printf(file.path);
            return "This page lists the rows given by the page file %s. Choosing a row prints its value.".printf(file.path);
        }

        public override HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", file.exec_argv != null ? "Run Command" : "Select Item");

            return keybindings;
        }

        public override void show() {
            request_rows();
            item_view.grab_focus();
        }

        public override Gtk.Widget get_root() {
            return root_widget;
        }

        public override async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.settings = settings;
            this.session_controller = sessionController;
            if (file.sort_by_frequency)
                value_counts = load_value_counts();

            int icon_size = settings.get_int("icon-size");
            with_icon = icon_size > 0;

            text_filter = new TextFilter();
            text_filter.subsequence_matching = settings.get_boolean("fuzzy-matching");
            text_filter.reset.connect(on_filter_reset);
            var icon = with_icon ? Ilia.load_icon_from_name(Gtk.IconTheme.get_default(), file.icon, icon_size) : null;
            model = new FilteredLinesModel(text_filter, with_icon, icon);
            work = new FilterWork(text_filter, model);
            work.first_rows.connect(select_first);

            create_item_view();

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.get_style_context().add_class("scrolled_window");
            scrolled.add(item_view);
            scrolled.expand = true;
            root_widget = scrolled;
        }

        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(model);
            item_view.get_style_context().add_class("item_view");
            item_view.headers_visible = false;
            item_view.fixed_height_mode = true;
            item_view.enable_search = false;

            if (with_icon)
                item_view.insert_column_with_attributes(-1, "Icon", new CellRendererPixbuf(), "pixbuf", ITEM_VIEW_COLUMN_ICON);
            item_view.insert_column_with_attributes(-1, "Name", new CellRendererText(), "text", with_icon ? 1 : 0);

            item_view.set_activate_on_single_click(true);
            item_view.row_activated.connect(on_row_activated);
            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            path = new Gtk.TreePath.first();

            // The command may still print when the window closes: leave the view alone, and stop it
            item_view.destroy.connect(() => {
                closed = true;
                work.stop();
                stop_command();
            });
        }

        // Fill the page the first time it is shown: with -a, a command only runs once its page is visited
        private void request_rows() {
            if (rows_requested)
                return;
            rows_requested = true;

            if (file.source == PageSource.COMMAND)
                start_command();
            else
                add_rows(file.items);
        }

        // Run ItemsCommand through the shell, in ilia's directory and environment, with stdin from /dev/null
        private void start_command() {
            try {
                var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE);
                // A process group of its own, so that stopping the command also stops what it started
                launcher.set_child_setup(() => {
                    Posix.setpgid(0, 0);
                });
                string[] argv = { "/bin/sh", "-c", file.command };
                command = launcher.spawnv(argv);
            } catch (GLib.Error e) {
                stderr.printf("ilia: page file '%s': cannot run ItemsCommand: %s\n", file.path, e.message);
                return;
            }
            unowned string ? identifier = command.get_identifier();
            if (identifier != null)
                command_pid = int.parse(identifier);

            command.wait_async.begin(null, (obj, res) => {
                // The rows that arrived stay, however the command ended
                try {
                    command.wait_async.end(res);
                } catch (GLib.Error e) {
                    debug("ItemsCommand of %s: %s", file.path, e.message);
                }
                command = null;
            });

            var reader = new LineReader(command.get_stdout_pipe());
            reader.lines_read.connect(add_rows);
            reader.read_all.begin();
        }

        private void stop_command() {
            if (command_pid == 0)
                return;
            // Also what the command started, which may outlive the shell
            Posix.kill((Posix.pid_t) (-command_pid), Posix.Signal.TERM);
            if (command != null)
                command.send_signal(Posix.Signal.TERM);
            command_pid = 0;
        }

        // The key the choices of a row are recorded under in the launch history
        private string history_key(string value) {
            return file.id.ascii_down() + "#" + value;
        }

        // How often each value of this page was chosen, from the launch history
        private HashTable<string, int> load_value_counts() {
            var table = new HashTable<string, int>(str_hash, str_equal);
            string prefix = history_key("");
            foreach (unowned string entry in settings.get_strv("app-launch-counts")) {
                if (entry.has_prefix(prefix)) {
                    string value = entry.substring(prefix.length);
                    table.insert(value, table.get(value) + 1);
                }
            }
            return table;
        }

        // Each line is a row, except empty ones and those that are only a tab
        private void add_rows(string[] lines) {
            if (closed)
                return;

            int first_new = labels.length;
            bool reordered = false;

            foreach (unowned string line in lines) {
                string label, value;
                if (!PageFile.split_row(line, out label, out value))
                    continue;
                if (!file.sort_by_frequency) {
                    labels += label;
                    values += value;
                    continue;
                }

                // After the rows chosen as often or more often, which come in the order they arrived
                int count = value_counts.get(value);
                int position = insertion_point(count);
                if (position < labels.length)
                    reordered = true;
                insert_row(position, label, value, count);
            }

            if (reordered) {
                // The filter gets the rows in their new order, and the view is refreshed in one go
                text_filter.replace_lines(labels);
            } else if (labels.length > first_new) {
                text_filter.add_lines(labels[first_new : labels.length]);
                work.schedule();
            }
        }

        // The first row chosen less often than count; the counts of the rows never increase down the list
        private int insertion_point(int count) {
            int low = 0, high = counts.length;
            while (low < high) {
                int middle = low + (high - low) / 2;
                if (counts[middle] >= count)
                    low = middle + 1;
                else
                    high = middle;
            }
            return low;
        }

        private void insert_row(int position, string label, string value, int count) {
            labels += label;
            values += value;
            counts += count;
            for (int i = labels.length - 1; i > position; --i) {
                labels[i] = labels[i - 1];
                values[i] = values[i - 1];
                counts[i] = counts[i - 1];
            }
            labels[position] = label;
            values[position] = value;
            counts[position] = count;
        }

        public override bool key_event(Gdk.EventKey event_key) {
            if (handle_emacs_vim_nav(item_view, path, event_key))
                return true;

            if (is_enter_key(event_key.keyval)) {
                // Act on the matches for the text as typed, among all rows so far
                text_filter.finish();
                // The view activates the selected row: make sure the first match is in it
                if (model.row_count == 0 && model.pending > 0) {
                    model.announce(1);
                    select_first();
                }
                // No row matches: Enter does nothing
                if (text_filter.visible_count == 0)
                    return true;
            }

            return false;
        }

        // filter the rows based on contents of Entry; the work is done in slices from idle
        public override void on_entry_changed() {
            text_filter.set_query(entry.get_text());
            work.schedule();
        }

        // called on enter when in text box
        public override void on_entry_activated() {
            text_filter.finish();
            int position = path.get_indices()[0];
            if (position < text_filter.visible_count)
                choose(values[text_filter.get_visible_index(position)]);
        }

        private void on_row_activated(Gtk.TreeView treeview, Gtk.TreePath row_path, Gtk.TreeViewColumn column) {
            // The view shows the first of the filter's visible lines, in order
            int position = row_path.get_indices()[0];
            if (position < model.row_count)
                choose(values[text_filter.get_visible_index(position)]);
        }

        // Filtering for new text completed: give the view the new rows in one go
        private void on_filter_reset() {
            if (closed)
                return;
            item_view.set_model(null);
            model.sync();
            item_view.set_model(model);
            select_first();
        }

        private void select_first() {
            if (model.row_count > 0)
                select_first_row(item_view, path);
        }

        // Run Exec for the row's value, or print the value when there is no Exec, then close; at most once
        private void choose(string value) {
            // Exec could not be split into words, which was reported at start-up
            if (closed || file.exec_invalid)
                return;
            closed = true;

            work.stop();
            if (file.sort_by_frequency)
                record_launch(settings, history_key(value));

            if (file.exec_argv == null) {
                stdout.printf("%s\n", value);
            } else {
                string[] argv = get_scope_argv(file.id, PageFile.expand_exec(file.exec_argv, value));
                try {
                    Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
                } catch (SpawnError e) {
                    stderr.printf("ilia: page file '%s': cannot run Exec: %s\n", file.path, e.message);
                }
            }

            session_controller.quit();
        }
    }
}
