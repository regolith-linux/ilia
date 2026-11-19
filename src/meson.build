cfg_ilia = configuration_data()
cfg_ilia.set('DATADIR', join_paths(get_option('prefix'),get_option('datadir')))
cfg_ilia.set('PKGDATADIR', join_paths(get_option('prefix'),get_option('datadir'),'ilia'))
pkglibdir = join_paths(get_option('prefix'),get_option('libdir'),'ilia')
cfg_ilia.set('PKGLIBDIR', pkglibdir)
cfg_ilia.set('GETTEXT_PACKAGE', 'ilia')
cfg_ilia.set('RELEASE_NAME', 'ilia')
cfg_ilia.set('PREFIX', get_option('prefix'))
cfg_ilia.set('VERSION', '0.19')
cfg_ilia.set('TESTSRCDIR', meson.project_source_root())
cfg_ilia.set('SPARQL_LIBDIR', sparql_libdir)

cfgfile_1 = configure_file(
	input: 'Config.vala.base',
	output: 'Config.vala',
	configuration: cfg_ilia)

ilia_deps = [gio_unix_2_0_dep]
ilia_deps += [json_glib_1_0_dep]
ilia_deps += [gmodule_2_0_dep]
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
ilia_deps += [gdk_x11_dep]
ilia_deps += [xtst_dep]
ilia_deps += [gtk_layer_shell_dep]
ilia_sources = [cfgfile_1]
ilia_sources += files([
    'ModuleApi.vala',
    'DialogWindow.vala',
    'Application.vala',
    'CallerEnvironment.vala',
    'CommandLine.vala',
    'KeyListenerGuard.vala',
    'atk-util-class.vapi',
    'IconLoader.vala',
    'InputSourceSwitcher.vala',
    'ResidentCall.vala',
    'ResidentServer.vala',
    'UiMain.vala',
    'Util.vala',
    'WmKeys.vala',
    'apps/DesktopAppPage.vala',
    'help/HelpPage.vala',
    'commands/CommandPage.vala',
    'keybindings/ConfigParser.vala',
    'keybindings/I3Ipc.vala',
    'keybindings/KeybindingsPage.vala',
    'keybindings/WmBindings.vala',
    'notifications/RoficationClient.vala',
    'notifications/RoficationPage.vala',
    'textlist/TextFilter.vala',
    'textlist/TextListPage.vala',
    'tracker/FileSearch.vala',
    'tracker/SparqlLibrary.vala',
    'tracker/TrackerPage.vala',
    'windows/WindowPage.vala',
    ])
    
ilia_link_args = ['-rdynamic']

# Everything that needs GTK, loaded by the program when it shows a window itself or
# becomes the background copy
ilia_ui = shared_module('ilia-ui', ilia_sources,
    dependencies: ilia_deps,
    vala_args: ilia_vala_args,
    link_args: ilia_link_args,
    name_prefix: '',
    install: true,
    install_dir: pkglibdir)

# The program: the command line and the calls to the background copy, without the toolkit,
# so that a call answered by the background copy starts quickly
executable('ilia', [cfgfile_1] + files(['Main.vala', 'CommandLine.vala', 'ResidentCall.vala']),
    dependencies: [gio_unix_2_0_dep, gmodule_2_0_dep],
    link_depends: ilia_ui,
    install: true)

