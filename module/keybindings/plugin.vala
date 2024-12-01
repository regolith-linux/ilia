class MyPlugin : Object, TestPlugin {
    public string hello () {
        return "Hello world!";
    }
}

public Type register_test_plugin (Module module) {
    // types are registered automatically
    return typeof (MyPlugin);
}