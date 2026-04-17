import Foundation

enum AppConfiguration {
    #if DEBUG
    static let developmentDatabaseURL: String? = "mysql://portsql_app:PortsqlApp2026!@nozomi.proxy.rlwy.net:59317/railway"
    static let developmentDatabaseName: String? = "Railway Dev"
    #else
    static let developmentDatabaseURL: String? = nil
    static let developmentDatabaseName: String? = nil
    #endif
}
