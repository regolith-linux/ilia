namespace Ilia {
    // Represents actions and state that DialogPage types may access from the active session.
    public interface SessionContoller : GLib.Object {
        public abstract void launched ();        
    }
}