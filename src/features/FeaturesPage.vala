using Gtk;

namespace Ilia {
    /**
     * Lists Regolith's optional feature packages for the running session, and installs or removes
     * the selected one through PackageKit. Nothing is asked of PackageKit until the page is first shown.
     */
    class FeaturesPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 4;
        private const int ITEM_VIEW_COLUMN_KIND = 0;
        private const int ITEM_VIEW_COLUMN_NAME = 1;
        private const int ITEM_VIEW_COLUMN_SUMMARY = 2;
        private const int ITEM_VIEW_COLUMN_STATE = 3;

        private const string UNAVAILABLE_TEXT = "Package management is not available";

        // What the page is doing for the package named by target_name
        private enum Activity {
            IDLE,
            TRIAL,       // asking PackageKit what the change would do
            PROMPT,      // waiting for the user to confirm the change
            TRANSACTION, // changing the system
            REFRESHING   // the change has ended; its row keeps its state until the packages are listed afresh
        }

        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;
        private Gtk.TreePath path;
        // The confirmation question, or why there is nothing to list
        private Gtk.Label message_label;
        private Gtk.Widget root_widget;
        private Gtk.Entry entry;
        private SessionContoller session_controller;
        private bool is_wayland;

        private FeatureSession session;
        // Created when the page is first shown
        private Pk.Client ? client = null;
        private bool catalogue_requested = false;
        // Only the reply to the latest catalogue request is shown
        private uint catalogue_generation = 0;
        // False when the catalogue could not be obtained
        private bool available = true;
        private Gee.HashMap<string, FeaturePackage> packages = new Gee.HashMap<string, FeaturePackage>();

        private Activity activity = Activity.IDLE;
        private string ? target_name = null;
        private string ? target_id = null;
        private bool target_install;
        private string ? prompt_text = null;
        private int percentage = -1;
        private bool allow_cancel = false;
        private bool cancel_requested = false;
        private GLib.Cancellable ? cancellable = null;
        // True while PackageKit waits for the user to authorise the change
        private bool waiting_for_auth = false;
        // True while ilia lets other windows have the keyboard and pointer, for the authorisation prompt
        private bool input_shared = false;

        // The package whose last transaction failed, and why, until the next transaction begins
        private string ? failed_name = null;
        private string ? failed_details = null;

        public string get_name() {
            return "F<u>e</u>atures";
        }

        public string get_icon_name() {
            return "system-software-install";
        }

        public string get_help() {
            return "This dialog lists the optional Regolith features for the running session: looks, bar blocks, compositors and window manager extensions. Installed features are marked. Enter installs the selected feature, or removes it if it is installed, asking first when other packages would be removed.";
        }

        public char get_keybinding() {
            return 'e';
        }

        public HashTable<string, string> ? get_keybindings() {
            var keybindings = new HashTable<string, string ?>(str_hash, str_equal);

            keybindings.set("enter", "Install or Remove Package");
            keybindings.set("escape", "Cancel");

            return keybindings;
        }

        public async void initialize(GLib.Settings settings, HashTable<string, string ?> arg_map, Gtk.Entry entry, SessionContoller sessionController, string wm_name, bool is_wayland) throws GLib.Error {
            this.entry = entry;
            this.session_controller = sessionController;
            this.is_wayland = is_wayland;
            this.session = FeatureSession.from_wm_name(wm_name);

            model = new Gtk.ListStore(ITEM_VIEW_COLUMNS, typeof (string), typeof (string), typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter(model, null);
            filter.set_visible_func(filter_func);

            create_item_view();
            path = new Gtk.TreePath.first();

            message_label = new Gtk.Label(null);
            message_label.set_line_wrap(true);
            message_label.xalign = 0;
            // Shown only while there is something to say, also when the window shows all its widgets
            message_label.no_show_all = true;

            var scrolled = new Gtk.ScrolledWindow(null, null);
            scrolled.add(item_view);
            scrolled.expand = true;

            // The heading and symbol of the tab, repeated on the page: GTK does not show tab labels to accessibility tools
            var heading = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 5);
            heading.pack_start(new Gtk.Image.from_icon_name(get_icon_name(), Gtk.IconSize.BUTTON), false, false, 0);
            var heading_label = new Gtk.Label(null);
            heading_label.set_markup(get_name());
            heading_label.get_style_context().add_class("help_heading");
            heading.pack_start(heading_label, false, false, 0);

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
            box.pack_start(heading, false, false, 0);
            box.pack_start(message_label, false, false, 0);
            box.pack_start(scrolled, true, true, 0);
            root_widget = box;
        }

        public Gtk.Widget get_root() {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view() {
            item_view = new Gtk.TreeView.with_model(filter);

            // Do not show column headers
            item_view.headers_visible = false;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            item_view.insert_column_with_attributes(-1, "Kind", new CellRendererText(), "text", ITEM_VIEW_COLUMN_KIND);
            // The summary goes under the name: in a column of its own, next to long package names, it gets no room
            var package_renderer = new CellRendererText();
            package_renderer.ellipsize = Pango.EllipsizeMode.END;
            var package_column = new Gtk.TreeViewColumn();
            package_column.title = "Package";
            package_column.expand = true;
            package_column.pack_start(package_renderer, true);
            package_column.set_cell_data_func(package_renderer, (column, cell, m, iter) => {
                string name, summary;
                m.@get(iter, ITEM_VIEW_COLUMN_NAME, out name, ITEM_VIEW_COLUMN_SUMMARY, out summary);
                ((CellRendererText) cell).markup = "%s\n<small>%s</small>".printf(Markup.escape_text(name ?? ""), Markup.escape_text(summary ?? ""));
            });
            item_view.append_column(package_column);
            item_view.insert_column_with_attributes(-1, "State", new CellRendererText(), "text", ITEM_VIEW_COLUMN_STATE);

            item_view.get_selection().set_mode(SelectionMode.SINGLE);
            item_view.row_activated.connect((row_path, column) => {
                activate_selection();
            });
        }

        public void show() {
            // The first appearance of the page loads the catalogue
            if (!catalogue_requested) {
                catalogue_requested = true;
                refresh_catalogue();
            }
            item_view.grab_focus();
        }

        public void on_entry_changed() {
            filter.refilter();
            select_first_row(item_view, path);
        }

        // Enter is handled in key_event, which runs first
        public void on_entry_activated() {
        }

        public bool key_event(Gdk.EventKey event_key) {
            if (is_enter_key(event_key.keyval)) {
                activate_selection();
                return true;
            }

            return handle_emacs_vim_nav(item_view, path, event_key);
        }

        /**
         * Escape discards a confirmation question or cancels the running trial or transaction, if
         * PackageKit allows it; the launcher stays open then. With nothing under way, it closes.
         */
        public bool cancel() {
            switch (activity) {
                case Activity.PROMPT:
                    end_activity();
                    return true;
                case Activity.TRIAL:
                case Activity.TRANSACTION:
                    if (allow_cancel && !cancel_requested && cancellable != null) {
                        cancel_requested = true;
                        cancellable.cancel();
                    }
                    return true;
                default:
                    return false;
            }
        }

        // PackageKit's authorisation prompt takes the focus while a question or a change is pending, and
        // taking the keyboard back after the change can move the focus too
        public bool keeps_open() {
            return activity != Activity.IDLE;
        }

        private bool filter_func(Gtk.TreeModel m, Gtk.TreeIter iter) {
            string name, summary;
            m.@get(iter, ITEM_VIEW_COLUMN_NAME, out name, ITEM_VIEW_COLUMN_SUMMARY, out summary);
            return FeatureCatalogue.matches(entry.get_text(), name ?? "", summary ?? "");
        }

        private Pk.Client get_client() {
            if (client == null) {
                client = new Pk.Client();
                // Installs and removals may ask the user for authorisation
                client.set_interactive(true);
            }
            return client;
        }

        private void refresh_catalogue() {
            uint generation = ++catalogue_generation;
            var filters = Pk.Bitfield.from_enums(Pk.Filter.ARCH, Pk.Filter.NEWEST, -1);

            get_client().get_packages_async.begin(filters, null, ignore_progress, (obj, res) => {
                FeatureCatalogue ? catalogue = null;
                try {
                    var results = client.get_packages_async.end(res);
                    if (results.get_exit_code() == Pk.Exit.SUCCESS) {
                        catalogue = new FeatureCatalogue(session);
                        foreach (var package in results.get_package_array()) {
                            bool installed = package.get_info() == Pk.Info.INSTALLED || FeatureCatalogue.is_installed_id(package.get_id());
                            catalogue.add(package.get_id(), package.get_summary() ?? "", installed);
                        }
                    } else {
                        stderr.printf("Unable to list packages: %s\n", error_details(results));
                    }
                } catch (GLib.Error e) {
                    stderr.printf("Unable to list packages: %s\n", e.message);
                }

                if (generation == catalogue_generation)
                    show_catalogue(catalogue);
            });
        }

        private void ignore_progress(Pk.Progress progress, Pk.ProgressType type) {
        }

        // Show the packages of catalogue, keeping the selected package selected; null if it could not be obtained
        private void show_catalogue(FeatureCatalogue ? catalogue) {
            string ? selected_name = get_selected_name();
            if (activity == Activity.REFRESHING) {
                activity = Activity.IDLE;
                target_name = null;
            }

            packages.clear();
            model.clear();
            available = catalogue != null;
            if (catalogue != null) {
                foreach (var package in catalogue.get_packages()) {
                    packages.set(package.name, package);
                    Gtk.TreeIter iter;
                    model.append(out iter);
                    model.set(
                        iter,
                        ITEM_VIEW_COLUMN_KIND, package.kind.to_label(),
                        ITEM_VIEW_COLUMN_NAME, package.name,
                        ITEM_VIEW_COLUMN_SUMMARY, package.summary,
                        ITEM_VIEW_COLUMN_STATE, state_of(package)
                    );
                }
            }
            update_message();

            if (selected_name == null || !select_name(selected_name))
                select_first_row(item_view, path);
        }

        private string ? get_selected_name() {
            Gtk.TreeModel selected_model;
            Gtk.TreeIter iter;
            if (!item_view.get_selection().get_selected(out selected_model, out iter))
                return null;
            string name;
            selected_model.@get(iter, ITEM_VIEW_COLUMN_NAME, out name);
            return name;
        }

        private bool select_name(string name) {
            Gtk.TreeIter iter;
            for (bool next = filter.get_iter_first(out iter); next; next = filter.iter_next(ref iter)) {
                string row_name;
                filter.@get(iter, ITEM_VIEW_COLUMN_NAME, out row_name);
                if (row_name == name) {
                    move_path_to(path, filter.get_path(iter));
                    item_view.set_cursor(path, null, false);
                    return true;
                }
            }
            return false;
        }

        // The state column: the running transaction, the last failure, or whether the package is installed
        private string state_of(FeaturePackage package) {
            if (activity == Activity.TRANSACTION && package.name == target_name)
                return FeatureCatalogue.transaction_state(target_install, percentage);
            if (package.name == failed_name)
                return "Failed: " + failed_details;
            return package.installed ? "Installed" : "";
        }

        private void update_states() {
            Gtk.TreeIter iter;
            for (bool next = model.get_iter_first(out iter); next; next = model.iter_next(ref iter)) {
                string name;
                model.@get(iter, ITEM_VIEW_COLUMN_NAME, out name);
                // Until the packages are listed afresh, the row of an ended change shows its last state, not the stale one
                if (activity == Activity.REFRESHING && name == target_name && name != failed_name)
                    continue;
                var package = packages.get(name);
                if (package != null)
                    model.set(iter, ITEM_VIEW_COLUMN_STATE, state_of(package));
            }
        }

        private void update_message() {
            string ? text = null;
            if (activity == Activity.PROMPT)
                text = prompt_text;
            else if (!available)
                text = UNAVAILABLE_TEXT;

            if (text != null) {
                message_label.set_text(text);
                message_label.show();
            } else {
                message_label.hide();
                message_label.set_text("");
            }
        }

        // Enter: start installing or removing the selected package, or confirm the question about it.
        // Only one package is acted upon at a time.
        private void activate_selection() {
            if (!available)
                return;

            string ? name = get_selected_name();
            var package = name != null ? packages.get(name) : null;
            if (package == null)
                return;

            switch (activity) {
                case Activity.IDLE:
                    start_trial(package);
                    break;
                case Activity.PROMPT:
                    if (package.name == target_name)
                        run_transaction.begin();
                    break;
                default:
                    break;
            }
        }

        private Pk.Bitfield transaction_flags(bool simulate) {
            if (simulate)
                return Pk.Bitfield.from_enums(Pk.TransactionFlag.ONLY_TRUSTED, Pk.TransactionFlag.SIMULATE, -1);
            return Pk.Bitfield.from_enums(Pk.TransactionFlag.ONLY_TRUSTED, -1);
        }

        private void begin_activity(Activity next) {
            activity = next;
            percentage = -1;
            allow_cancel = false;
            cancel_requested = false;
            waiting_for_auth = false;
            cancellable = new GLib.Cancellable();
        }

        // Ask PackageKit what installing or removing package would change, without changing anything
        private void start_trial(FeaturePackage package) {
            target_install = !package.installed;
            target_id = target_install ? package.available_id : package.installed_id;
            if (target_id == null)
                return;
            target_name = package.name;

            // A new transaction replaces the report of the last failure
            failed_name = null;
            failed_details = null;
            update_states();

            begin_activity(Activity.TRIAL);
            run_trial.begin();
        }

        private async void run_trial() {
            string[] removed = {};
            try {
                Pk.Results results;
                if (target_install)
                    results = yield get_client().install_packages_async(transaction_flags(true), { target_id }, cancellable, on_progress);
                else
                    results = yield get_client().remove_packages_async(transaction_flags(true), { target_id }, true, false, cancellable, on_progress);

                if (results.get_exit_code() != Pk.Exit.SUCCESS) {
                    end_transaction(results.get_exit_code() == Pk.Exit.CANCELLED ? null : error_details(results));
                    return;
                }

                // Packages the change would bring in are not mentioned, only those it would take away
                foreach (var package in results.get_package_array()) {
                    var info = package.get_info();
                    if ((info == Pk.Info.REMOVING || info == Pk.Info.OBSOLETING) && package.get_name() != target_name)
                        removed += package.get_name();
                }
            } catch (GLib.Error e) {
                end_transaction(is_cancellation(e) ? null : e.message);
                return;
            }

            if (cancel_requested) {
                end_transaction(null);
                return;
            }

            if (target_install && removed.length == 0) {
                yield run_transaction();
                return;
            }

            prompt_text = target_install ? FeatureCatalogue.install_prompt(target_name, removed) : FeatureCatalogue.remove_prompt(target_name, removed);
            activity = Activity.PROMPT;
            update_message();
        }

        // Install or remove the target package for real
        private async void run_transaction() {
            begin_activity(Activity.TRANSACTION);
            update_input_sharing();
            prompt_text = null;
            update_message();
            update_states();

            string ? details = null;
            try {
                Pk.Results results;
                if (target_install)
                    results = yield get_client().install_packages_async(transaction_flags(false), { target_id }, cancellable, on_progress);
                else
                    // Packages that depend on the removed one go with it, as the trial told; nothing else is removed
                    results = yield get_client().remove_packages_async(transaction_flags(false), { target_id }, true, false, cancellable, on_progress);

                if (results.get_exit_code() != Pk.Exit.SUCCESS && results.get_exit_code() != Pk.Exit.CANCELLED)
                    details = error_details(results);
            } catch (GLib.Error e) {
                if (!is_cancellation(e))
                    details = e.message;
            }
            end_transaction(details);
        }

        // A trial or transaction has ended: show a failure on its package and list the packages afresh
        private void end_transaction(string ? details) {
            if (details != null) {
                failed_name = target_name;
                failed_details = details;
            }
            end_activity(Activity.REFRESHING);
            refresh_catalogue();
        }

        private void end_activity(Activity next = Activity.IDLE) {
            activity = next;
            waiting_for_auth = false;
            update_input_sharing();
            if (next == Activity.IDLE)
                target_name = null;
            target_id = null;
            prompt_text = null;
            cancellable = null;
            update_message();
            update_states();
        }

        // PackageKit may ask the user to authorise a change, in a window of its own that needs the keyboard; the
        // trial needs no authorisation. On X11 ilia's window only gets keys through its grab, so the grab is let go
        // while PackageKit waits for authorisation, and the window manager focuses the prompt. On Wayland the prompt
        // can only take the keyboard if ilia's overlay is not exclusive when the prompt appears, and an overlay that
        // is not exclusive keeps the keyboard until then: it stops being exclusive for the whole change.
        private void update_input_sharing() {
            bool shared = activity == Activity.TRANSACTION && (is_wayland || waiting_for_auth);
            if (shared == input_shared)
                return;
            input_shared = shared;
            session_controller.share_input(shared);
        }

        private void on_progress(Pk.Progress progress, Pk.ProgressType type) {
            switch (type) {
                case Pk.ProgressType.ALLOW_CANCEL:
                    allow_cancel = progress.get_allow_cancel();
                    break;
                case Pk.ProgressType.PERCENTAGE:
                    percentage = progress.get_percentage();
                    if (activity == Activity.TRANSACTION)
                        update_states();
                    break;
                case Pk.ProgressType.STATUS:
                    waiting_for_auth = progress.get_status() == Pk.Status.WAITING_FOR_AUTH;
                    update_input_sharing();
                    break;
                default:
                    break;
            }
        }

        private bool is_cancellation(GLib.Error e) {
            return cancel_requested && e is GLib.IOError.CANCELLED ||
                   e.domain == Pk.ClientError.quark() && e.code == 0xff + Pk.ErrorEnum.TRANSACTION_CANCELLED;
        }

        private static string error_details(Pk.Results results) {
            var error = results.get_error_code();
            if (error != null && error.get_details() != null)
                return error.get_details();
            return results.get_exit_code().enum_to_string();
        }
    }
}
