cfg_ilia = configuration_data()
cfg_ilia.set('DATADIR', join_paths(get_option('prefix'),get_option('datadir')))
cfg_ilia.set('PKGDATADIR', join_paths(get_option('prefix'),get_option('datadir'),'ilia'))
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
    'KeyListenerGuard.vala',
    'atk-util-class.vapi',
    'ClipboardKeeper.vala',
    'IconLoader.vala',
    'InputSourceSwitcher.vala',
    'PathWatcher.vala',
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
    
ilia_vala_args = []

# The clipboard keeper serves Wayland clipboards with the ext-data-control protocol (in
# wayland-protocols from 1.39); without it, copied text is kept on Wayland only by the desktop
wayland_client_dep = dependency('wayland-client', required: false)
wayland_protocols_dep = dependency('wayland-protocols', version: '>= 1.39', required: false)
wayland_scanner_dep = dependency('wayland-scanner', native: true, required: false)
if wayland_client_dep.found() and wayland_protocols_dep.found() and wayland_scanner_dep.found()
    wayland_scanner = find_program(wayland_scanner_dep.get_variable(pkgconfig: 'wayland_scanner'))
    data_control_xml = join_paths(wayland_protocols_dep.get_variable(pkgconfig: 'pkgdatadir'),
        'staging', 'ext-data-control', 'ext-data-control-v1.xml')
    ilia_sources += custom_target('ext-data-control-v1-client-protocol.h',
        input: data_control_xml,
        output: 'ext-data-control-v1-client-protocol.h',
        command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'])
    ilia_sources += custom_target('ext-data-control-v1-protocol.c',
        input: data_control_xml,
        output: 'ext-data-control-v1-protocol.c',
        command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'])
    ilia_sources += files(['WaylandClipboard.c'])
    ilia_deps += [wayland_client_dep]
    ilia_vala_args += ['--define=WAYLAND_CLIPBOARD']
endif

ilia_link_args = ['-rdynamic']

executable('ilia',ilia_sources + files(['Main.vala']),
    dependencies: ilia_deps,
    vala_args: ilia_vala_args,
    link_args: ilia_link_args,
    install: true)

