import Foundation
import Testing
@testable import SandboxHelper

@Suite struct CountryPlacesTests {
    @Test func readsZoneTab() {
        let places = CountryPlaces.read("# comment\nDE\t+5230+01322\tEurope/Berlin\nDE\t+4742+00841\tEurope/Busingen\nGB\t+513030-0000731\tEurope/London\nXX\tbad\tNowhere\n")
        #expect(places.count == 2)
        #expect(abs(places["DE"]!.latitude - 52.5) < 0.001 && abs(places["DE"]!.longitude - 13.3667) < 0.001)
        #expect(abs(places["GB"]!.latitude - 51.5083) < 0.001 && abs(places["GB"]!.longitude + 0.1253) < 0.001)
    }

    @Test func systemFileCoversCountries() throws {
        let text = try String(contentsOf: CountryPlaces.systemFile, encoding: .utf8)
        let places = CountryPlaces.read(text)
        #expect(places.count > 200 && places["JP"] != nil && places["IR"] != nil)
    }
}
