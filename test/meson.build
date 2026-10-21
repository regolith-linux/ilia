unit_test_files = [
    'InputSource',
    'Util',
    'I3Ipc',
    'Launch',
    'Rofication',
    'TextFilter',
    'FileSearch'
]

foreach name : unit_test_files
    test(name, executable(name, name + 'Test.vala', ilia_sources, dependencies: ilia_deps))
endforeach