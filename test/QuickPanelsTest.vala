using GLib;

Bytes bytes_of(uint8[] data) {
    return new Bytes(data);
}

// Open, Enterprise and Secured come from the privacy flag and the WPA and RSN flags of the access point
void test_security_state() {
    assert (Ilia.WifiPage.security_state(0, 0, 0) == "Open");
    assert (Ilia.WifiPage.security_state(1, 0, 0) == "Secured");
    assert (Ilia.WifiPage.security_state(0, 0x100, 0) == "Secured");
    assert (Ilia.WifiPage.security_state(0, 0, 0x200) == "Enterprise");
    assert (Ilia.WifiPage.security_state(0, 0x200, 0) == "Enterprise");
    assert (Ilia.WifiPage.security_state(1, 0x200, 0x400) == "Secured");
    assert (Ilia.WifiPage.security_state(1, 0x300, 0) == "Secured");
}

// SAE only when RSN offers it and neither WPA nor RSN offers PSK
void test_key_management() {
    assert (Ilia.WifiPage.key_management(0, 0x400) == "sae");
    assert (Ilia.WifiPage.key_management(0x400, 0) == "wpa-psk");
    assert (Ilia.WifiPage.key_management(0x100, 0x400) == "wpa-psk");
    assert (Ilia.WifiPage.key_management(0, 0x500) == "wpa-psk");
    assert (Ilia.WifiPage.key_management(0x100, 0x100) == "wpa-psk");
}

// 8 to 63 characters, counted as characters, or exactly 64 hexadecimal digits
void test_password() {
    assert (!Ilia.WifiPage.is_valid_password(""));
    assert (!Ilia.WifiPage.is_valid_password("1234567"));
    assert (Ilia.WifiPage.is_valid_password("12345678"));
    assert (Ilia.WifiPage.is_valid_password(string.nfill(63, 'z')));
    assert (!Ilia.WifiPage.is_valid_password(string.nfill(64, 'z')));
    assert (Ilia.WifiPage.is_valid_password(string.nfill(64, 'a')));
    assert (Ilia.WifiPage.is_valid_password("Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09Ab09"));
    assert (!Ilia.WifiPage.is_valid_password(string.nfill(65, 'a')));
    var accented = new StringBuilder();
    for (int i = 0; i < 63; ++i)
        accented.append("é");
    assert (Ilia.WifiPage.is_valid_password(accented.str));
    assert (!Ilia.WifiPage.is_valid_password("ééééééé"));
}

// Invalid UTF-8 in an SSID shows as U+FFFD
void test_ssid_name() {
    assert (Ilia.WifiPage.ssid_name(bytes_of("Café".data)) == "Café");
    assert (Ilia.WifiPage.ssid_name(bytes_of({ 0xff, 0xfe, 0xfd })) == "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd");
    assert (Ilia.WifiPage.ssid_name(bytes_of({})) == "");
}

Ilia.BluetoothPage.Device device(string alias, string address, bool paired, bool connected) {
    var result = new Ilia.BluetoothPage.Device();
    result.alias = alias;
    result.address = address;
    result.paired = paired;
    result.connected = connected;
    return result;
}

// Connected, then paired, then the rest; by case-folded name, then address
void test_device_order() {
    var devices = new GenericArray<Ilia.BluetoothPage.Device>();
    devices.add(device("Phone", "AA:04", false, false));
    devices.add(device("STRASSE", "AA:02", true, false));
    devices.add(device("Straße", "AA:01", true, false));
    devices.add(device("zebra", "AA:05", true, true));
    devices.add(device("strasse", "AA:03", false, true));
    devices.sort(Ilia.BluetoothPage.compare_devices);
    string[] order = {};
    foreach (var item in devices.data)
        order += item.alias;
    assert (string.joinv(",", order) == "strasse,zebra,Straße,STRASSE,Phone");
}

// A failed StartDiscovery takes its adapter off the list that StopDiscovery is sent to
void test_remove_path() {
    var discovering = new GenericArray<string>();
    discovering.add("/org/bluez/hci0");
    discovering.add("/org/bluez/hci1");
    string failed = "/org/bluez/" + "hci0"; // equal text, another string
    assert (Ilia.BluetoothPage.remove_path(discovering, failed));
    assert (discovering.length == 1 && discovering[0] == "/org/bluez/hci1");
    assert (!Ilia.BluetoothPage.remove_path(discovering, "/org/bluez/hci2"));
    assert (discovering.length == 1);
}

void test_profile_label() {
    assert (Ilia.PowerPage.profile_label("power-saver") == "Power Saver");
    assert (Ilia.PowerPage.profile_label("balanced") == "Balanced");
    assert (Ilia.PowerPage.profile_label("performance") == "Performance");
    assert (Ilia.PowerPage.profile_label("custom") == "custom");
}

void test_name_filter() {
    assert (Ilia.panel_name_matches("Home Net", ""));
    assert (Ilia.panel_name_matches("Home Net", "NET"));
    assert (Ilia.panel_name_matches("Balanced", "ANCED"));
    assert (!Ilia.panel_name_matches("Lab", "net"));
    // Accents and case are ignored, as on the other pages
    assert (Ilia.panel_name_matches("Café Wi-Fi", "cafe"));
    assert (Ilia.panel_name_matches("Power Saver", "SAVER power"));
    assert (!Ilia.panel_name_matches("Power Saver", "saver balanced"));
}

void test_error_message() {
    assert (Ilia.panel_error_message(new IOError.TIMED_OUT("Timeout was reached")) == "no reply");
    var remote = new DBusError.FAILED("GDBus.Error:org.freedesktop.DBus.Error.Failed: service rejected action");
    assert (Ilia.panel_error_message(remote) == "service rejected action");
}

public static int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/quickpanels/security_state", test_security_state);
    Test.add_func("/quickpanels/key_management", test_key_management);
    Test.add_func("/quickpanels/password", test_password);
    Test.add_func("/quickpanels/ssid_name", test_ssid_name);
    Test.add_func("/quickpanels/device_order", test_device_order);
    Test.add_func("/quickpanels/remove_path", test_remove_path);
    Test.add_func("/quickpanels/profile_label", test_profile_label);
    Test.add_func("/quickpanels/name_filter", test_name_filter);
    Test.add_func("/quickpanels/error_message", test_error_message);
    return Test.run();
}
