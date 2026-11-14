using Gtk;

namespace Ilia {
    /**
     * The form that adds an application: a new desktop entry in the user's applications directory
     *
     * It is shown inside ilia's window, over the application list, rather than as a
     * dialog window of its own: ilia's window takes the keyboard (a grab on X11, an overlay
     * layer surface on Wayland), and a separate window would end up behind it. While it is
     * shown, the window hands every key to handle_key().
     */
    public class AddAppForm : Gtk.Box {
        private Gtk.Entry name_entry;
        private Gtk.Entry command_entry;
        private Gtk.Entry icon_entry;
        private Gtk.Entry comment_entry;
        private Gtk.Entry keywords_entry;
        private Gtk.CheckButton terminal_check;
        private Gtk.Button cancel_button;
        private Gtk.Button add_button;
        private Gtk.Label error_label;

        // The controls in focus order, for Tab and Shift+Tab
        private Gtk.Widget[] focus_order;

        // The form was closed without adding anything
        public signal void cancelled();

        // A new desktop entry was written to path
        public signal void added(string path);

        public AddAppForm() {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6);
            get_style_context().add_class("add_app_form");
            margin = 6;

            var grid = new Gtk.Grid();
            grid.row_spacing = 4;
            grid.column_spacing = 8;

            name_entry = add_field(grid, 0, "Name");
            command_entry = add_field(grid, 1, "Command");
            icon_entry = add_field(grid, 2, "Icon");
            comment_entry = add_field(grid, 3, "Comment");
            keywords_entry = add_field(grid, 4, "Keywords");
            pack_start(grid, false, false, 0);

            terminal_check = new Gtk.CheckButton.with_label("Run in terminal");
            pack_start(terminal_check, false, false, 0);

            error_label = new Gtk.Label(null);
            error_label.get_style_context().add_class("error");
            error_label.get_accessible().set_name("Error");
            error_label.hexpand = true;
            error_label.xalign = 0;
            error_label.wrap = true;
            error_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            error_label.max_width_chars = 30;

            cancel_button = new Gtk.Button.with_label("Cancel");
            cancel_button.clicked.connect(cancel);
            add_button = new Gtk.Button.with_label("Add");
            add_button.get_style_context().add_class("suggested-action");
            add_button.clicked.connect(submit);

            var button_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            button_row.pack_start(error_label, true, true, 0);
            button_row.pack_end(add_button, false, false, 0);
            button_row.pack_end(cancel_button, false, false, 0);
            pack_end(button_row, false, false, 0);

            focus_order = {
                name_entry, command_entry, icon_entry, comment_entry, keywords_entry,
                terminal_check, cancel_button, add_button
            };

            // Keys the focused control does not use stop here, rather than reaching the page or the window
            key_press_event.connect(() => true);
        }

        private Gtk.Entry add_field(Gtk.Grid grid, int row, string name) {
            var label = new Gtk.Label(name);
            label.xalign = 0;
            var field = new Gtk.Entry();
            field.hexpand = true;
            field.get_accessible().set_name(name);
            label.mnemonic_widget = field;
            // Enter in any field does what Add does
            field.activate.connect(submit);
            grid.attach(label, 0, row, 1, 1);
            grid.attach(field, 1, row, 1, 1);
            return field;
        }

        /**
         * Clear the form and give the keyboard focus to Name
         */
        public void reset() {
            foreach (var field in new Gtk.Entry[] { name_entry, command_entry, icon_entry, comment_entry, keywords_entry })
                field.text = "";
            terminal_check.active = false;
            error_label.label = "";
            name_entry.grab_focus();
        }

        /**
         * Give the keyboard focus to the form, unless one of its controls has it
         */
        public void take_focus() {
            var window = get_toplevel() as Gtk.Window;
            var focus = window != null ? window.get_focus() : null;
            if (focus == null || !focus.is_ancestor(this))
                name_entry.grab_focus();
        }

        /**
         * Handle a key the window received while the form is shown
         *
         * @return true: every key belongs to the form
         */
        public bool handle_key(Gdk.EventKey key) {
            var window = get_toplevel() as Gtk.Window;
            if (window == null)
                return false;
            take_focus();

            switch (key.keyval) {
                case Gdk.Key.Escape:
                    cancel();
                    return true;
                case Gdk.Key.Tab:
                case Gdk.Key.KP_Tab:
                case Gdk.Key.ISO_Left_Tab:
                    bool backwards = key.keyval == Gdk.Key.ISO_Left_Tab || (key.state & Gdk.ModifierType.SHIFT_MASK) != 0;
                    move_focus_by(window.get_focus(), backwards ? -1 : 1);
                    return true;
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                case Gdk.Key.ISO_Enter:
                case Gdk.Key.space:
                case Gdk.Key.KP_Space:
                    // The window's key bindings would press the focused button, but the form keeps keys
                    // from them. Gtk.Button.activate() grabs the keyboard, which would take it from ilia.
                    var button = window.get_focus() as Gtk.Button;
                    if (button != null) {
                        button.clicked();
                        return true;
                    }
                    break;
                default:
                    break;
            }

            window.propagate_key_event(key);
            return true;
        }

        private void move_focus_by(Gtk.Widget ? focus, int step) {
            int index = 0;
            for (int i = 0; i < focus_order.length; ++i) {
                if (focus_order[i] == focus) {
                    index = (i + step + focus_order.length) % focus_order.length;
                    break;
                }
            }
            focus_order[index].grab_focus();
        }

        private void cancel() {
            cancelled();
        }

        private void submit() {
            var entry = new NewDesktopEntry();
            entry.name = name_entry.text;
            entry.command = command_entry.text;
            entry.icon = icon_entry.text;
            entry.comment = comment_entry.text;
            entry.keywords = keywords_entry.text;
            entry.terminal = terminal_check.active;

            try {
                var path = entry.save();
                error_label.label = "";
                added(path);
            } catch (NewDesktopEntryError e) {
                error_label.label = e.message;
                if (e is NewDesktopEntryError.NAME)
                    name_entry.grab_focus();
                else if (e is NewDesktopEntryError.COMMAND)
                    command_entry.grab_focus();
                else if (e is NewDesktopEntryError.ICON)
                    icon_entry.grab_focus();
            }
        }
    }
}
