import Foundation
import XCTest
import MtProtoKit
@testable import ImpulseTransport
@testable import ImpulseNetworkEngine

final class ImpulseDeclarationFromEnvironmentTests: XCTestCase {
    private let deviceModel: String = "ImpulseM test device"
    private let appVersion: String = "1.2.3"


    func testDeclarationCarriesTheApiIdOfTheEnvironment() {
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: self.makeEnvironment())
        XCTAssertEqual(declaration.apiId, 2)
    }

    func testDeclarationCarriesTheLangPackOfTheEnvironment() {
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: self.makeEnvironment())
        XCTAssertEqual(declaration.langPack, "ios")
    }

    func testDeclarationCarriesTheDeviceModelOfTheEnvironment() {
        let environment: MTApiEnvironment = self.makeEnvironment()
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: environment)
        XCTAssertEqual(declaration.deviceModel, environment.deviceModel ?? "")
        XCTAssertEqual(declaration.deviceModel, self.deviceModel)
    }

    func testDeclarationCarriesTheAppVersionOfTheEnvironment() {
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: self.makeEnvironment())
        XCTAssertEqual(declaration.appVersion, self.appVersion)
    }

    func testDeclarationCarriesTheSystemVersionOfTheEnvironment() {
        let environment: MTApiEnvironment = self.makeEnvironment()
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: environment)
        XCTAssertEqual(declaration.systemVersion, environment.systemVersion ?? "")
    }

    func testDeclarationWithoutEnvironmentLangPackHasEmptyLangPack() {
        let environment: MTApiEnvironment = self.makeEnvironment()
        environment.langPack = nil
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: environment)
        XCTAssertEqual(declaration.langPack, "")
    }

    func testDeclarationLanguagesComeFromTheCurrentLocale() {
        let declaration: ImpulseDeclaration = ImpulseNetworkEngineFactory.makeDeclaration(environment: self.makeEnvironment())
        let language: String = Locale.current.languageCode ?? "en"
        XCTAssertEqual(declaration.systemLangCode, language)
        XCTAssertEqual(declaration.langCode, language)
    }

    private func makeEnvironment() -> MTApiEnvironment {
        let environment: MTApiEnvironment = MTApiEnvironment(deviceModelName: self.deviceModel)
        environment.apiId = 2
        environment.appVersion = self.appVersion
        environment.langPack = "ios"
        return environment
    }
}
