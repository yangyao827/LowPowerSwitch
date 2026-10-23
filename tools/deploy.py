"""Sign on the jailbroken phone, package a deb, install, and respring."""
import hashlib
import getpass
import io
import os
from pathlib import Path
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]
if os.environ.get('IOS_SSH_PYTHON'):
    sys.path.insert(0, str(Path(os.environ['IOS_SSH_PYTHON']).expanduser()))
import paramiko


def connect():
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    known_hosts = Path('~/.ssh/known_hosts').expanduser()
    if known_hosts.exists():
        client.load_host_keys(str(known_hosts))
    host = os.environ.get('IPHONE_HOST') or input('iPhone SSH host: ').strip()
    password = os.environ.get('IPHONE_PASSWORD') or getpass.getpass('iPhone root SSH password: ')
    port = int(os.environ.get('IPHONE_PORT', '2222'))
    client.connect(host, port=port,
                   username='root', password=password,
                   look_for_keys=False, allow_agent=False, timeout=10)
    return client


def command(client, text):
    _, stdout, stderr = client.exec_command(text, timeout=45)
    result, error = stdout.read(), stderr.read()
    if stdout.channel.recv_exit_status():
        raise RuntimeError(error.decode(errors='replace') + result.decode(errors='replace'))
    return result


def upload(client, path, data):
    channel = client.get_transport().open_session()
    channel.exec_command('cat > ' + path)
    channel.sendall(data)
    channel.shutdown_write()
    if channel.recv_exit_status():
        raise RuntimeError('Upload failed: ' + path)


def archive(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz', format=tarfile.USTAR_FORMAT) as tar:
        for name, (data, mode) in entries.items():
            info = tarfile.TarInfo('./' + name)
            info.uid = info.gid = 0
            info.uname, info.gname = 'root', 'wheel'
            info.size, info.mode = len(data), mode
            info.mtime = int(time.time())
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def ar(entries):
    result = bytearray(b'!<arch>\n')
    for name, data in entries:
        header = f'{name + "/":<16}{int(time.time()):<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'
        assert len(header) == 60
        result.extend(header.encode() + data)
        if len(data) % 2:
            result.extend(b'\n')
    return result


def main():
    client = connect()
    try:
        for filename in ['LowPowerCC.dylib']:
            source = ROOT / 'build' / filename
            remote = '/var/tmp/lowpowercc-' + filename
            upload(client, remote, source.read_bytes())
            command(client, f'chmod 755 {remote} && ldid -S {remote}')
            source.write_bytes(command(client, 'cat ' + remote))
            command(client, 'rm -f ' + remote)
        entries = {
            'Library/MobileSubstrate/DynamicLibraries/LowPowerCC.dylib': ((ROOT / 'build/LowPowerCC.dylib').read_bytes(), 0o755),
            'Library/MobileSubstrate/DynamicLibraries/LowPowerCC.plist': ((ROOT / 'LowPowerCC.plist').read_bytes(), 0o644),
        }
        control = b'''Package: local.lowpowercc
Name: Low Power Mode for Control Center (iOS 10.3)
Version: 0.1.4
Architecture: iphoneos-arm
Depends: mobilesubstrate, firmware (>= 10.3), firmware (<< 10.4)
Description: Native Low Power Mode toggle in the top Control Center row, with a battery glyph and six buttons per page.
Author: Local development
Maintainer: Local development
Section: Tweaks
'''
        package = ar([('debian-binary', b'2.0\n'),
                      ('control.tar.gz', archive({'control': (control, 0o644)})),
                      ('data.tar.gz', archive(entries))])
        output = ROOT / 'dist/local.lowpowercc_0.1.4_iphoneos-arm.deb'
        output.parent.mkdir(exist_ok=True)
        output.write_bytes(package)
        print('Package:', output, 'SHA256:', hashlib.sha256(package).hexdigest(), flush=True)
        upload(client, '/var/tmp/lowpowercc.deb', package)
        print(command(client, 'dpkg -i /var/tmp/lowpowercc.deb').decode(errors='replace'), flush=True)
        # Restart only SpringBoard so Substrate loads this SpringBoard-only tweak.
        client.exec_command('killall SpringBoard')
        print('SpringBoard restart requested.', flush=True)
    finally:
        client.close()


if __name__ == '__main__':
    main()
