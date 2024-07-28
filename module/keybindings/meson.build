cfg_ilia_keybindings = configuration_data()
cfg_ilia_keybindings.set('DATADIR', join_paths(get_option('prefix'),get_option('datadir')))
cfg_ilia_keybindings.set('PKGDATADIR', join_paths(get_option('prefix'),get_option('datadir'),'ilia-keybindings'))
cfg_ilia_keybindings.set('GETTEXT_PACKAGE', 'ilia-keybindings')
cfg_ilia_keybindings.set('RELEASE_NAME', 'ilia-keybindings')
cfg_ilia_keybindings.set('PREFIX', get_option('prefix'))
cfg_ilia_keybindings.set('VERSION', '0.12')
cfg_ilia_keybindings.set('TESTSRCDIR', meson.source_root())

cfgfile_1 = configure_file(
	input: 'Config.vala.base',
	output: 'Config.vala',
	configuration: cfg_ilia_keybindings)

ilia_keybindings_deps = [gio_unix_2_0_dep]
ilia_keybindings_deps += [json_glib_1_0_dep]
ilia_keybindings_deps += [tracker_sparql_3_0_dep]
ilia_keybindings_deps += [atk_dep]
ilia_keybindings_deps += [cairo_gobject_dep]
ilia_keybindings_deps += [gdk_3_0_dep]
ilia_keybindings_deps += [gdk_pixbuf_2_0_dep]
ilia_keybindings_deps += [gee_0_8_dep]
ilia_keybindings_deps += [gio_2_0_dep]
ilia_keybindings_deps += [glib_2_0_dep]
ilia_keybindings_deps += [gobject_2_0_dep]
ilia_keybindings_deps += [gtk_3_0_dep]
ilia_keybindings_deps += [pango_dep]
ilia_keybindings_deps += [x11_dep]
ilia_keybindings_deps += [gtk_layer_shell_dep]
ilia_keybindings_sources = [cfgfile_1]
ilia_keybindings_sources += ['../../src/DialogPage.vala']
ilia_keybindings_sources += ['../../src/SessionController.vala']
ilia_keybindings_sources += ['ConfigParser.vala']
ilia_keybindings_sources += ['I3Ipc.vala']
ilia_keybindings_sources += ['KeybindingsPage.vala']


shlib = shared_library('ilia-keybindings', ilia_keybindings_sources,
               dependencies: ilia_keybindings_deps,
               install: true,
               install_dir: [true, true, true])

# test_exe = executable('beetle_test', 'beetle_test.vala', dependencies : dependencies,
#   link_with : shlib)
# test('beetle', test_exe)

# Make this library usable as a Meson subproject.
ilia_keybindings_dep = declare_dependency(
  include_directories: include_directories('.'),
  link_with : shlib)

# ilia_keybindings_link_args = ['-rdynamic']
#
# executable('ilia-keybindings',ilia_keybindings_sources,
#     dependencies: ilia_keybindings_deps,
#     link_args: ilia_keybindings_link_args,
#     install: true)
