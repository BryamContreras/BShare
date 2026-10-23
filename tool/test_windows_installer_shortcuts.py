import re
import unittest
from pathlib import Path


class WindowsInstallerShortcutsTest(unittest.TestCase):
    def test_start_menu_shortcut_is_default_and_desktop_is_optional(self):
        installer = (Path(__file__).resolve().parents[1] / 'installer/windows/BShare.iss').read_text()
        tasks = re.search(r'(?ms)^\[Tasks\]\s*(.*?)^\[', installer).group(1)
        icons = re.search(r'(?ms)^\[Icons\]\s*(.*?)^\[', installer).group(1)

        self.assertRegex(tasks, r'(?m)^Name: "desktopicon";.*Flags: unchecked$')
        self.assertRegex(icons, r'(?m)^Name: "\{autoprograms\}\\BShare";.*$')
        self.assertRegex(icons, r'(?m)^Name: "\{autodesktop\}\\BShare";.*Tasks: desktopicon$')
        self.assertNotRegex(icons, r'(?m)^Name: "\{autoprograms\}\\BShare";.*Tasks:')


if __name__ == '__main__':
    unittest.main()
