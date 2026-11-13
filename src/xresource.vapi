/**
 * The parts of Xlib's resource manager that x11.vapi does not cover
 */
[CCode (cheader_filename = "X11/Xlib.h,X11/Xresource.h")]
namespace Xrm {
    [CCode (cname = "XrmInitialize")]
    public static void initialize();

    [CCode (cname = "XResourceManagerString")]
    public static unowned string ? resource_manager_string(X.Display display);

    [CCode (cname = "XrmValue", has_type_id = false)]
    public struct Value {
        public uint size;
        public char * addr;
    }

    [Compact]
    [CCode (cname = "struct _XrmHashBucketRec", free_function = "XrmDestroyDatabase")]
    public class Database {
        [CCode (cname = "XrmGetStringDatabase")]
        public Database.from_string(string data);

        [CCode (cname = "XrmGetResource")]
        public bool get_resource(string name, string class_name, [CCode (type = "char**")] out unowned string ? type, out Value value);
    }
}
