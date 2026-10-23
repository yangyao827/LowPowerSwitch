"""Build the iOS 10.3/arm64 Low Power Mode Control Center tweak on Windows. No Apple account required."""
import os
import json
from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parent
TOOLCHAIN = Path(os.environ.get('IOS_CC_TOOLCHAIN') or ROOT / '.toolchain').expanduser().resolve()
local_tools = TOOLCHAIN / 'local-tools.json'
settings = json.loads(local_tools.read_text(encoding='utf-8')) if local_tools.exists() else {}


def project_path(value):
    path = Path(value).expanduser()
    return path if path.is_absolute() else ROOT / path


ZIG = project_path(os.environ.get('LOWPOWER_ZIG') or settings.get('zig') or TOOLCHAIN / 'zig/zig.exe')
LINKER = project_path(os.environ.get('LOWPOWER_LINKER') or settings.get('linker') or TOOLCHAIN / 'llvm/ld.lld.exe')
SDK = project_path(os.environ.get('LOWPOWER_SDK') or settings.get('sdk') or TOOLCHAIN / 'sdks/iPhoneOS10.3.sdk')
for label, path in [('Zig compiler', ZIG), ('LLVM linker', LINKER), ('iOS SDK', SDK)]:
    if not path.exists():
        raise SystemExit(f'{label} not found: {path}. See README.md for toolchain setup.')
OUT = ROOT / 'build'
OUT.mkdir(exist_ok=True)


def run(command):
    result = subprocess.run([str(x) for x in command], cwd=ROOT,
                            capture_output=True, encoding='utf-8', errors='replace')
    if result.returncode:
        print(result.stdout)
        print(result.stderr[-10000:])
        raise SystemExit(result.returncode)


common = [ZIG, 'cc', '-target', 'aarch64-ios',
          '-Xclang', '-triple', '-Xclang', 'arm64-apple-ios10.3.0',
          '-isysroot', SDK, '-iframework', SDK / 'System/Library/Frameworks',
          '-isystem', SDK / 'usr/include', '-fblocks', '-O2',
          '-Wno-nullability-completeness', '-Wno-nullability-completeness-on-arrays',
          '-Wno-expansion-to-defined', '-Wno-availability', '-Wno-macro-redefined']
run([*common, '-fobjc-arc', '-c', 'src/LowPowerCC.m', '-o', OUT / 'LowPowerCC.o'])
def symbols(path):
    path = path.resolve()
    text = path.read_text()
    if not text.startswith('---'):
        return symbols(path.parent / text.strip())
    text = text.replace('!tapi-tbd-v2', '').replace('!tapi-tbd-v3', '')
    result = set()
    for document in yaml.safe_load_all(text):
        for export in document.get('exports', []):
            if 'arm64' not in export.get('archs', []):
                continue
            result.update(export.get('symbols', []))
            result.update(export.get('weak-def-symbols', []))
            result.update(export.get('thread-local-symbols', []))
            for name in export.get('objc-classes', []):
                name = name[1:] if name.startswith('_') else name
                result.update(['_OBJC_CLASS_$_' + name, '_OBJC_METACLASS_$_' + name])
            for name in export.get('objc-ivars', []):
                name = name[1:] if name.startswith('_') else name
                result.add('_OBJC_IVAR_$_' + name)
    return result


# The old SDK uses TAPI v2 and checkout contains symlink text on Windows.
# Convert only the required link interfaces to v4; runtime libraries are Apple's.
stubs = OUT / 'link-stubs'
stubs.mkdir(exist_ok=True)
def stub(name, install, exported):
    document = {'tbd-version': 4, 'targets': ['arm64-ios'], 'install-name': install,
                'exports': [{'targets': ['arm64-ios'], 'symbols': sorted(exported)}]}
    (stubs / (name + '.tbd')).write_text('--- !tapi-tbd\n' + yaml.safe_dump(document) + '...\n')

system = symbols(SDK / 'usr/lib/libSystem.B.tbd')
for path in (SDK / 'usr/lib/system').glob('*.tbd'):
    system.update(symbols(path))
stub('libSystem', '/usr/lib/libSystem.B.dylib', system)
stub('libobjc', '/usr/lib/libobjc.A.dylib', symbols(SDK / 'usr/lib/libobjc.A.tbd'))
frameworks = ['Foundation', 'UIKit', 'CoreFoundation', 'CoreGraphics']
for name in frameworks:
    stub(name, f'/System/Library/Frameworks/{name}.framework/{name}',
         symbols(SDK / f'System/Library/Frameworks/{name}.framework/{name}.tbd'))

link = [LINKER, '-flavor', 'darwin', '-arch', 'arm64', '-platform_version',
        'ios', '10.3', '10.3', '-syslibroot', SDK,
        '-L' + str(stubs)]
run([*link, '-dylib', '-install_name', '/Library/MobileSubstrate/DynamicLibraries/LowPowerCC.dylib',
     OUT / 'LowPowerCC.o', '-lSystem', '-lobjc',
     *[stubs / (name + '.tbd') for name in frameworks],
     '-o', OUT / 'LowPowerCC.dylib'])
print('Built LowPowerCC.dylib (arm64, iOS 10.3, no diagnostics).')
