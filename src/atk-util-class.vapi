/* The class structure of AtkUtil, whose key listener functions GTK sets; see KeyListenerGuard.vala */
[CCode (cheader_filename = "atk/atk.h")]
namespace AtkUtilClassBinding {
    [CCode (has_target = false, has_typedef = false)]
    public delegate void RemoveKeyListenerFunc (uint listener_id);

    [CCode (cname = "AtkUtilClass", has_type_id = false, destroy_function = "")]
    public struct UtilClass {
        public RemoveKeyListenerFunc remove_key_event_listener;
    }
}
