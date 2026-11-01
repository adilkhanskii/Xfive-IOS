from pathlib import Path
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RegistrationAndTaskLocationTests(unittest.TestCase):
    def test_onboarding_offers_only_two_roles_and_requires_location(self):
        source = (ROOT / "X5/Views/OnboardingView.swift").read_text(encoding="utf-8")
        self.assertIn("case specialist", source)
        self.assertIn("case entrepreneur", source)
        self.assertNotIn("case creator", source)
        self.assertIn("case location", source)
        self.assertIn("CISCityPickerButton(city: $city, countryCode: countryCode)", source)
        self.assertIn('"country_code": countryCode', source)
        self.assertIn('"city": cityTrimmed', source)
        self.assertIn('p.userRole == "creator"', source)

    def test_onboarding_location_step_can_return_to_role(self):
        source = (ROOT / "X5/Views/OnboardingView.swift").read_text(encoding="utf-8")
        self.assertIn("if step != .role", source)
        self.assertIn("Button(action: goBack)", source)
        self.assertIn('Label(loc.t("btn_back"), systemImage: "chevron.left")', source)
        self.assertIn('.accessibilityIdentifier("onboarding_back_button")', source)
        self.assertRegex(source, r"case \.location:\s+step = \.role")

    def test_cis_dataset_has_all_supported_countries(self):
        rows = json.loads((ROOT / "X5/Resources/cis-cities.json").read_text(encoding="utf-8"))
        countries = {row["country"] for row in rows}
        self.assertEqual(countries, {"AM", "AZ", "BY", "GE", "KG", "KZ", "MD", "RU", "TJ", "TM", "UA", "UZ"})
        self.assertTrue(all(row.get("regionCode") and row.get("region") for row in rows))
        kazakhstan_regions = {row["regionCode"] for row in rows if row["country"] == "KZ"}
        self.assertGreaterEqual(len(kazakhstan_regions), 20)
        kazakhstan = [row for row in rows if row["country"] == "KZ"]
        self.assertEqual(kazakhstan[0]["city"], "Almaty")

    def test_create_task_requires_and_stores_location(self):
        view = (ROOT / "X5/Views/Hub/CreateTaskView.swift").read_text(encoding="utf-8")
        service = (ROOT / "X5/Services/HubService.swift").read_text(encoding="utf-8")
        detail = (ROOT / "X5/Views/Hub/TaskDetailView.swift").read_text(encoding="utf-8")
        picker = (ROOT / "X5/Views/CISCityPicker.swift").read_text(encoding="utf-8")
        # Несколько стран/городов/категорий (Адильхан 30.10); «все» = пустой массив.
        self.assertIn("TaskCountriesPickerButton(countryCodes: $countryCodes)", view)
        self.assertIn("CISMultiCityPickerButton(cities: $cities, countryCodes: countryCodes)", view)
        self.assertIn("TaskCategoriesPickerButton(categories: $categories)", view)
        self.assertIn("countryCodes: countryCodes", view)
        self.assertIn("CISLocations.keptCities(cities, in: newCountries)", view)
        self.assertIn("CISLocations.countries.map", picker)
        self.assertIn('"country_codes": countryCodes', service)
        self.assertIn('"country_code": countryCodes.first', service)
        self.assertIn('"cities": cities', service)
        self.assertIn('"city": cities.first', service)
        self.assertIn('"category": categories.first', service)
        self.assertIn("task.locationLabel(", detail)

    def test_edit_task_can_change_and_persist_location(self):
        view = (ROOT / "X5/Views/Hub/MyTasksView.swift").read_text(encoding="utf-8")
        service = (ROOT / "X5/Services/HubService.swift").read_text(encoding="utf-8")
        self.assertIn("_countryCodes = State(initialValue: task.countryCodes)", view)
        self.assertIn("_cities = State(initialValue: task.cities)", view)
        self.assertIn("TaskCountriesPickerButton(countryCodes: $countryCodes)", view)
        self.assertIn("CISMultiCityPickerButton(cities: $cities, countryCodes: countryCodes)", view)
        self.assertIn("countryCodes: countryCodes", view)
        self.assertIn("cities: cities", view)
        self.assertIn('"country_codes": countryCodes', service)
        self.assertIn('"cities": cities', service)


if __name__ == "__main__":
    unittest.main()
