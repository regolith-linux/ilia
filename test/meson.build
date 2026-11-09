unit_test_files = [
    'InputSource',
    'Util',
    'I3Ipc',
    'ConfigReply',
    'Launch',
    'Rofication',
    'TextFilter',
    'FileSearch',
    'WindowPage',
    'ConfigParser',
    'KeybindingsPage',
    'WmBindings'
]

foreach name : unit_test_files
    test(name, executable(name, name + 'Test.vala', ilia_sources, dependencies: ilia_deps))
endforeach

# Also evaluates expressions with the helper program
if with_calculator
    test('Calculator', executable('Calculator', 'CalculatorTest.vala', ilia_sources, dependencies: ilia_deps),
        args: [calculator_helper.full_path()])
endif
