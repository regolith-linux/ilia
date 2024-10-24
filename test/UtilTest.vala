using GLib;


public void test_systemd_escape () {
    assert (Ilia.systemd_escape("asdf") == "asdf");

     // Taken from https://github.com/mk-pmb/systemd-escape-pmb-js/blob/master/test/01_basics.json
     assert (Ilia.systemd_escape("/dev/sda1") == "-dev-sda1");

     assert (Ilia.systemd_escape(
        "/dev/disk/by-uuid/c26af46b-d6dd-4614-b2d5-c7f4bf6291b9") == 
        "-dev-disk-by\\x2duuid-c26af46b\\x2dd6dd\\x2d4614\\x2db2d5\\x2dc7f4bf6291b9"
    );
     assert (Ilia.systemd_escape("/dev/disk/by-label/ab.cd-ef_gh=ij") == "-dev-disk-by\\x2dlabel-ab.cd\\x2def_gh\\x3dij");
     assert (Ilia.systemd_escape(".@/foo$bAR§qux/ab.çd-êf_gh=ij") == "\\x2e\\x40-foo\\x24bAR\\xc2\\xa7qux-ab.\\xc3\\xa7d\\x2d\\xc3\\xaaf_gh\\x3dij");
}

// correct
// -dev-disk-by\\x2dlabel-ab.cd\\x2def_gh\\x3dij
// -dev-disk-by\\x2dlabel-ab.cd\\x2def\x5fgh\x3dij
// actual

public int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/test_systemd_escape", test_systemd_escape);
    return Test.run ();
}