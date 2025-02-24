{ source # source must be given explicitly when calling callPackage

  # callPackage automatically populates all of these arguments from nixpkgs
, atk
, cairo
, gtk3
, gtk-layer-shell
, json-glib
, lib
, libgee
, meson
, ninja
, pkg-config
, stdenv
, tinysparql
, uncrustify
, vala
, wrapGAppsHook3
}:

stdenv.mkDerivation {
  name = "ilia";
  src = source;
  postPatch = ''
    patchShebangs meson_scripts
  '';
  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    uncrustify
    vala
    wrapGAppsHook3 # wraps the executable to register gsettings-schemas files
  ];
  buildInputs = [
    atk
    cairo
    gtk3
    gtk-layer-shell
    json-glib
    libgee
    tinysparql
  ];
  meta = {
    homepage = "https://github.com/regolith-linux/ilia?tab=readme-ov-file";
    license = [ lib.licenses.asl20 ];
  };
}

