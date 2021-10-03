using Gtk;

namespace Ilia {
    class CommandPage : DialogPage, GLib.Object {
        private const int ITEM_VIEW_COLUMNS = 1;
        private const int ITEM_VIEW_COLUMN_NAME = 0;
        
        // Max number of files to read in sequence before yeilding
        private const int FS_FILE_READ_COUNT = 64;
        // The widget to display list of available options
        private Gtk.TreeView item_view;
        // Model for selections
        private Gtk.ListStore model;
        // Access state from model
        private Gtk.TreeIter iter;
        // View on model of filtered elements
        private Gtk.TreeModelFilter filter;

        private Gtk.Entry entry;

        private SessionContoller session_controller;

        private Gtk.Widget root_widget;
        
        public string get_name () {
            return "Terminal";
        }

        public async void initialize (GLib.Settings settings, Gtk.Entry entry, SessionContoller sessionController) {
            this.entry = entry;
            this.session_controller = sessionController;

            model = new Gtk.ListStore (ITEM_VIEW_COLUMNS, typeof (string), typeof (string));

            filter = new Gtk.TreeModelFilter (model, null);
            filter.set_visible_func (filter_func);

            create_item_view ();

            load_apps.begin ((obj, res) => {
                load_apps.end (res);
                
                model.set_sort_column_id (1, SortType.ASCENDING);
                model.set_sort_func (1, app_sort_func);
            });

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.add (item_view);
            scrolled.expand = true;

            root_widget = scrolled;        
        }

        public Gtk.Widget get_root () {
            return root_widget;
        }

        // Initialize the view displaying selections
        private void create_item_view () {
            item_view = new Gtk.TreeView.with_model (filter);

            // Do not show column headers
            item_view.headers_visible = false;

            // Optimization
            item_view.fixed_height_mode = true;

            // Do not enable Gtk seearch
            item_view.enable_search = false;

            // Create columns
            item_view.insert_column_with_attributes (-1, "Name", new CellRendererText (), "text", ITEM_VIEW_COLUMN_NAME);

            // Launch app on one click
            item_view.set_activate_on_single_click (true);

            // Launch app on row selection
            item_view.row_activated.connect (on_row_activated);
        }

        public void grab_focus () {
            item_view.grab_focus ();
        }

        // called on enter from TreeView
        private void on_row_activated (Gtk.TreeView treeview, Gtk.TreePath path, Gtk.TreeViewColumn column) {
            filter.get_iter (out iter, path);
            execute_app (iter);
        }

        // filter selection based on contents of Entry
        void on_entry_changed () {
            filter.refilter ();
            set_selection ();
        }

        // called on enter when in text box
        void on_entry_activated () {
            filter.get_iter_first (out iter);
            execute_app (iter);
        }

        private int app_sort_func (TreeModel model, TreeIter a, TreeIter b) {
            string app_a;
            model.@get (a, ITEM_VIEW_COLUMN_NAME, out app_a);
            string app_b;
            model.@get (b, ITEM_VIEW_COLUMN_NAME, out app_b);

            return app_a.ascii_casecmp (app_b);
        }

        // traverse the model and show items with metadata that matches entry filter string
        private bool filter_func (Gtk.TreeModel m, Gtk.TreeIter iter) {
            string queryString = entry.get_text ().down ().strip ();

            if (queryString.length > 0) {
                GLib.Value app_info;
                string strval;
                model.get_value (iter, ITEM_VIEW_COLUMN_NAME, out app_info);
                strval = app_info.get_string ();

                return (strval != null && strval.down ().contains (queryString));
            } else {
                return true;
            }
        }

        private async void load_apps () {
            var paths = Environment.get_variable("PATH");

            foreach (unowned string path in paths.split (":")) {
                var path_dir = File.new_for_path (path);
                if (path_dir.query_exists ()) {
                    yield load_apps_from_dir (path_dir);
                }
            }

            set_selection ();
        }
        
        private async void load_apps_from_dir (File app_dir) {
            try {
                var enumerator = yield app_dir.enumerate_children_async (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, Priority.DEFAULT);

                while (true) {
                    var app_files = yield enumerator.next_files_async (FS_FILE_READ_COUNT, Priority.DEFAULT);

                    if (app_files == null) {
                        break;
                    }

                    foreach (var info in app_files) {
                        string file_path = app_dir.get_child (info.get_name ()).get_path ();
                        
                        model.append (out iter);
                        model.set (
                            iter,
                            ITEM_VIEW_COLUMN_NAME, file_path
                        );                        
                    }
                }
            } catch (Error err) {
                stderr.printf ("Error: list_files failed: %s\n", err.message);
            }
        }

        // Automatically set the first item in the list as selected.
        private void set_selection () {
            Gtk.TreePath path = new Gtk.TreePath.first ();
            Gtk.TreeSelection selection = item_view.get_selection ();

            selection.set_mode (SelectionMode.SINGLE);
            selection.select_path (path);
        }

        // launch a desktop app
        public void execute_app (Gtk.TreeIter selection) {            
            session_controller.launched ();       
            
            string cmd_path;
            filter.@get (selection, ITEM_VIEW_COLUMN_NAME, out cmd_path);
            
            string commandline = "/usr/bin/x-terminal-emulator -e \"bash -c '" + cmd_path + "; exec bash'\"";            

            try {
                var app_info = AppInfo.create_from_commandline (commandline, cmd_path, AppInfoCreateFlags.NEEDS_TERMINAL);
                
                if (!app_info.launch (null, null)) {
                    stderr.printf ("Error: execute_app failed\n");    
                }            
            } catch (GLib.Error err) {
                stderr.printf ("Error: execute_app failed: %s\n", err.message);
            }
        }
    }
}