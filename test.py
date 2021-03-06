#!/usr/bin/env python3

from argparse import ArgumentParser
import os
from subprocess import check_output
import atexit
from tempfile import TemporaryDirectory
import time


def cleanup():
    os.system('killall flashairsim.py')


atexit.register(cleanup)


def as_flashair(ssh_user, cmd):
    ret = check_output(['ssh', '-q', '-o', 'StrictHostKeyChecking=no', ssh_user + '@localhost', cmd])
    return ret


config_template = """
SDCARD_HOST='{SDCARD_HOST}'
SDCARD_PORT={SDCARD_PORT}
SSH_USER='{SSH_USER}'
TARGET_PATH='{TARGET_PATH}'
DEBUG={DEBUG}
"""


def create_config(root_dir, debug, ssh_user):
    filename = os.path.join(root_dir, 'config.lua')
    SDCARD_HOST = 'localhost'
    SDCARD_PORT = 8000
    SSH_USER = ssh_user
    SSH_HOST = '127.0.0.1'
    TARGET_PATH = '/home/' + ssh_user + '/test'
    DEBUG='true' if debug else 'false'
    as_flashair(ssh_user, 'rm -Rf {TARGET_PATH}'.format(**locals()))
    as_flashair(ssh_user, 'mkdir -p {TARGET_PATH}'.format(**locals()))
    with open(filename, 'w+') as fd:
        fd.write(config_template.format(**locals()))
    return filename, TARGET_PATH


def banner(txt):
    print(txt)
    print('=' * len(txt))


def is_same(base1, base2):
    for (root1, dirs1, files1), (root2, dirs2, files2) in zip(os.walk(base1), os.walk(base2)):
        if len(files1) != len(files2):
            return False
        if set(files1) != set(files2):
            return False
        if set(dirs1) != set(dirs2):
            return False
        for f1, f2 in zip(files1, files2):
            if f1 != f2:
                return False
            if os.stat(os.path.join(root1, f1)).st_size != os.stat(os.path.join(root2, f2)).st_size:
                return False
    return True


def run_flashairsim_syncroot(syncroot, ssh_user, debug):
    # assemble
    config_filename, target_path = create_config(syncroot, debug=debug, ssh_user=ssh_user)
    source_dir = os.path.join(syncroot, 'sd')
    csv_dir = os.path.join(source_dir, 'CSVFILES', 'LOG')
    os.makedirs(csv_dir)
    os.system('./simulator/flashairsim.py --dir {source_dir} &'.format(**locals()))
    filenames = ['a.csv', 'b.csv', 'c.csv']
    for fname in filenames:
        with open(os.path.join(csv_dir, fname), 'w+') as fd:
            fd.write('1,2,3\n')
    time.sleep(0.5)

    # action
    os.system('./sync_sd_to_remote {config_filename}'.format(**locals()))

    # assert directories contain same files
    local_path = os.path.join(syncroot, 'result')
    os.makedirs(local_path)
    os.system('rsync -rva {ssh_user}@localhost:{target_path}/ {local_path}/'.format(**locals()))
    assert is_same(csv_dir, local_path)

    #import pdb; pdb.set_trace()

    # second assemble
    banner("SECOND TEST: No mtime change after second sync where SD didn't change")

    # make sure none of the files is updated the second time around -
    #  i.e. that syncing works
    mtimes = [os.stat(os.path.join(local_path, fname)).st_mtime for fname in filenames]

    # second action
    os.system('./sync_sd_to_remote {config_filename}'.format(**locals()))

    # second assert
    os.system('rsync -rva {ssh_user}@localhost:{target_path}/ {local_path}/'.format(**locals()))
    assert is_same(csv_dir, local_path)
    new_mtimes = [os.stat(os.path.join(local_path, fname)).st_mtime for fname in filenames]
    assert new_mtimes == mtimes


def run_flashairsim(ssh_user, debug):
    os.system('killall flashairsim.py')

    with TemporaryDirectory() as syncroot:
        run_flashairsim_syncroot(syncroot, ssh_user, debug)

def main():
    parser = ArgumentParser()
    parser.add_argument('--ssh-user', default='flashair')
    parser.add_argument('--debug', default=False, action='store_true')
    args = parser.parse_args()
    run_flashairsim(ssh_user=args.ssh_user, debug=args.debug)


if __name__ == '__main__':
    main()
