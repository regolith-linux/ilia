/* The class structure of AtkUtil, whose key listener functions GTK sets; see KeyListenerGuard.vala */
[CCode (cheader_filename = "atk/atk.h")]
namespace AtkUtilClassBinding {
    [CCode (cname = "AtkUtilClass", has_type_id = false, destroy_function = "")]
    public struct UtilClass {
        // ATK declares no type for the function; the one in KeyListenerGuard.vala has its signature
        public Ilia.KeyListenerGuard.RemoveKeyListenerFunc remove_key_event_listener;
    }
}
