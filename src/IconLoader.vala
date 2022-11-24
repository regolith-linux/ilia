using Gtk;

namespace Ilia {

    public Gdk.Pixbuf? load_icon_from_app_name(IconTheme icon_theme, string app_name, int size) {
        if (app_name != null) {
            string**[] desktopApps = GLib.DesktopAppInfo.search(app_name);

            if (desktopApps.length > 0) {
                DesktopAppInfo app_info = new DesktopAppInfo (*desktopApps[0]);

                return load_icon_from_info(icon_theme, app_info, size);
            }
        }

        return load_icon_from_name(icon_theme, app_name, size);
    }

    public Gdk.Pixbuf? load_icon_from_info(IconTheme icon_theme, DesktopAppInfo? app_info, int size) {
        if (app_info == null) return null;

        try {
            var icon = app_info.get_icon ();
            string icon_name = null;
            if (icon != null) {
                icon_name = icon.to_string ();

                var icon_info = icon_theme.lookup_icon (icon_name, size, Gtk.IconLookupFlags.FORCE_SIZE); // from icon theme
                if (icon_info != null) {
                    return icon_info.load_icon ();
                }

                if (GLib.File.new_for_path (icon_name).query_exists ()) {
                    try {
                        return new Gdk.Pixbuf.from_file_at_size (icon_name, size, size);
                    } catch (Error e) {
                        stderr.printf ("1Error loading icon: %s\n", e.message);
                    }
                }
            }
        } catch (GLib.Error err) {
            stderr.printf ("Error: load_icon failed: %s\n", err.message);
        }

        return null;
    }

    public Gdk.Pixbuf? load_icon_from_name(IconTheme icon_theme, string name, int size) {
        try {
            if (name != null && name.length > 0) {
                if (GLib.File.new_for_path (name).query_exists ()) {
                    try {
                        return new Gdk.Pixbuf.from_file_at_size (name, size, size);
                    } catch (Error e) {
                        stderr.printf ("3Error loading icon: %s\n", e.message);
                    }
                }

                var icon_info = icon_theme.lookup_icon (name, size, Gtk.IconLookupFlags.FORCE_SIZE); // from icon theme
                if (icon_info != null) {
                    return icon_info.load_icon ();
                }
            }

            var icon_info = icon_theme.lookup_icon ("emblem-generic", size, Gtk.IconLookupFlags.FORCE_SIZE);
            if (icon_info != null) {
                return icon_info.load_icon ();
            }
        } catch (GLib.Error err) {
            stderr.printf ("Error: load_icon failed: %s\n", err.message);
        }

        return null;
    }
}