from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class HubLocationSourceTests(unittest.TestCase):
    def test_specialists_and_tasks_are_filtered_by_country_and_city(self):
        hub = (ROOT / "X5/Views/Hub/HubView.swift").read_text(encoding="utf-8")
        service = (ROOT / "X5/Services/HubService.swift").read_text(encoding="utf-8")

        self.assertIn("selectedCountryCode", hub)
        self.assertIn("selectedCity", hub)
        self.assertGreaterEqual(hub.count("locationMatches(countryCode:"), 4)
        self.assertIn("country_code,city", service)
        self.assertIn('case countryCode = "country_code"', service)

    def test_profile_editor_requires_and_persists_location(self):
        source = (ROOT / "X5/Views/EditProfileView.swift").read_text(encoding="utf-8")

        self.assertIn("CISLocations.countries", source)
        self.assertIn("CISCityPickerButton(city: $city, countryCode: countryCode)", source)
        self.assertIn('"country_code": AnyEncodable(countryCode)', source)
        self.assertIn('"city": AnyEncodable(city.trimmingCharacters', source)
        self.assertIn("cleanCity.count >= 2", source)

    def test_hub_uses_all_cities_region_picker_instead_of_city_chips(self):
        hub = (ROOT / "X5/Views/Hub/HubView.swift").read_text(encoding="utf-8")
        picker = (ROOT / "X5/Views/CISCityPicker.swift").read_text(encoding="utf-8")

        self.assertIn("CISCityPickerButton(", hub)
        self.assertIn("allowsAllCities: true", hub)
        self.assertNotIn("let suggestions = CISLocations.search", hub)
        self.assertIn("CISLocations.popularCities", picker)
        self.assertIn("CISLocations.regions", picker)
        self.assertIn("CISRegionCitiesView", picker)
        self.assertIn(".searchable(text: $query", picker)


if __name__ == "__main__":
    unittest.main()
