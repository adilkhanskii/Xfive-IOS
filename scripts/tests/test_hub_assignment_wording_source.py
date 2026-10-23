from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION = ROOT / "X5" / "Services" / "LocalizationService.swift"
HOME = ROOT / "X5" / "Views" / "Home" / "HomeView.swift"
HUB = ROOT / "X5" / "Views" / "Hub" / "HubView.swift"
CREATE = ROOT / "X5" / "Views" / "Hub" / "CreateTaskView.swift"


class HubAssignmentWordingSourceTests(unittest.TestCase):
    def test_russian_hub_uses_assignment_wording_consistently(self):
        localization = LOCALIZATION.read_text(encoding="utf-8")
        home = HOME.read_text(encoding="utf-8")
        hub = HUB.read_text(encoding="utf-8")
        create = CREATE.read_text(encoding="utf-8")

        expected = (
            '"task_section": "Задание"',
            '"hub_tasks": "Задания"',
            '"hub_create_task": "Создать задание"',
            '"hub_no_tasks": "Нет открытых заданий"',
            '"chats_task": "Задание:"',
        )
        for text in expected:
            self.assertIn(text, localization)

        self.assertIn('subtitle: "Специалисты и задания"', home)
        self.assertIn('.navigationTitle("Новое задание")', create)
        self.assertIn('.alert("Задание не открылось"', hub)

        for obsolete in (
            '"hub_tasks": "Задачи"',
            '"hub_create_task": "Создать задачу"',
            '"hub_no_tasks": "Нет открытых задач"',
            'subtitle: "Специалисты и задачи"',
            '.navigationTitle("Новая задача")',
        ):
            self.assertNotIn(obsolete, localization + home + hub + create)


if __name__ == "__main__":
    unittest.main()
