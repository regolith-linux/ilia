cfg_ilia = configuration_data()
cfg_ilia.set('DATADIR', join_paths(get_option('prefix'),get_option('datadir')))
cfg_ilia.set('PKGDATADIR', join_paths(get_option('prefix'),get_option('datadir'),'ilia'))
cfg_ilia.set('GETTEXT_PACKAGE', 'ilia')
cfg_ilia.set('RELEASE_NAME', 'ilia')
cfg_ilia.set('PREFIX', get_option('prefix'))
cfg_ilia.set('VERSION', '0.1.0')
cfg_ilia.set('TESTSRCDIR', meson.source_root())

cfgfile_1 = configure_file(
	input: 'Config.vala.base',
	output: 'Config.vala',
	configuration: cfg_ilia)

ilia_deps = [gio_unix_2_0_dep]
ilia_deps += [atk_dep]
ilia_deps += [cairo_gobject_dep]
ilia_deps += [gdk_3_0_dep]
ilia_deps += [gdk_pixbuf_2_0_dep]
ilia_deps += [gio_2_0_dep]
ilia_deps += [glib_2_0_dep]
ilia_deps += [gobject_2_0_dep]
ilia_deps += [gtk_3_0_dep]
ilia_deps += [pango_dep]
ilia_deps += [x11_dep]
ilia_sources = [cfgfile_1]
ilia_sources += ['DialogWindow.vala']
ilia_sources += ['Ilia.vala']
ilia_link_args = ['-rdynamic']

executable('ilia',ilia_sources,
    dependencies: ilia_deps,
    link_args: ilia_link_args,
    install: true)

ilia_tests_vala_args = ['-D','UNITEST']
ilia_tests_c_args = ['-DUNITEST']

ilia_test1_exec = executable('ilia_test1',ilia_sources + ['unitests/ExampleTest.vala'],dependencies: ilia_deps,vala_args: ilia_tests_vala_args,c_args: ilia_tests_c_args,link_args: ilia_link_args,install: false)
test('ilia_test1', ilia_test1_exec)


