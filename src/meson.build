cfg_ilia = configuration_data()
cfg_ilia.set('DATADIR', join_paths(get_option('prefix'),get_option('datadir')))
cfg_ilia.set('PKGDATADIR', join_paths(get_option('prefix'),get_option('datadir'),'ilia'))
cfg_ilia.set('GETTEXT_PACKAGE', 'ilia')
cfg_ilia.set('RELEASE_NAME', 'ilia')
cfg_ilia.set('PREFIX', get_option('prefix'))
cfg_ilia.set('VERSION', '0.12')
cfg_ilia.set('TESTSRCDIR', meson.project_source_root())

cfgfile_1 = configure_file(
	input: 'Config.vala.base',
	output: 'Config.vala',
	configuration: cfg_ilia)

ilia_deps = [gio_unix_2_0_dep]
ilia_deps += [json_glib_1_0_dep]
ilia_deps += [tracker_sparql_3_0_dep]
ilia_deps += [atk_dep]
ilia_deps += [cairo_gobject_dep]
ilia_deps += [gdk_3_0_dep]
ilia_deps += [gdk_pixbuf_2_0_dep]
ilia_deps += [gee_0_8_dep]
ilia_deps += [gio_2_0_dep]
ilia_deps += [glib_2_0_dep]
ilia_deps += [gobject_2_0_dep]
ilia_deps += [gtk_3_0_dep]
ilia_deps += [pango_dep]
ilia_deps += [x11_dep]
ilia_deps += [gtk_layer_shell_dep]
ilia_sources = [cfgfile_1]
ilia_sources += files([
    'ModuleApi.vala',
    'DialogWindow.vala',
    'Application.vala',
    'IconLoader.vala',
    'Util.vala',
    'apps/DesktopAppPage.vala',
    'clipboard/ClipboardPage.vala',
    'commands/CommandPage.vala',
    'keybindings/ConfigParser.vala',
    'keybindings/I3Ipc.vala',
    'keybindings/KeybindingsPage.vala',
    'notifications/RoficationClient.vala',
    'notifications/RoficationPage.vala',
    'textlist/TextListPage.vala',
    'tracker/TrackerPage.vala',
    'windows/WindowPage.vala',
    ])
    
ilia_link_args = ['-rdynamic']

executable('ilia',ilia_sources + files(['Main.vala']),
    dependencies: ilia_deps,
    link_args: ilia_link_args,
    install: true)

