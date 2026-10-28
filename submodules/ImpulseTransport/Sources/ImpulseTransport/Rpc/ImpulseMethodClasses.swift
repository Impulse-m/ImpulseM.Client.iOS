import Foundation


public enum ImpulseMethodClasses {
    public static let loginOnlyMethods: Set<String> = [
        "auth.sendCode",
        "auth.cancelCode",
        "auth.signIn",
        "auth.signUp",
        "auth.requestFirebaseSms",
        "auth.resetLoginEmail",
        "auth.reportMissingCode",
        "auth.checkPaidAuth",
        "auth.importAuthorization",
        "auth.importBotAuthorization",
        "auth.importWebTokenAuthorization",
        "auth.exportLoginToken",
        "auth.importLoginToken",
        "auth.initPasskeyLogin",
        "auth.finishPasskeyLogin",
    ]


    public static let dualUseMethods: Set<String> = [
        "auth.resendCode",
        "account.sendVerifyEmailCode",
        "account.verifyEmail",
    ]


    public static let pendingMethods: Set<String> = [
        "auth.checkPassword",
        "auth.requestPasswordRecovery",
        "auth.recoverPassword",
        "auth.checkRecoveryPassword",
        "account.getPassword",
    ]


    public static let publicMethods: Set<String> = [
        "help.getConfig",
        "help.getAppConfig",
        "help.getNearestDc",
        "help.getCountriesList",
        "help.getDeepLinkInfo",
        "help.saveAppLog",
        "langpack.getLangPack",
        "langpack.getStrings",
        "langpack.getDifference",
        "langpack.getLanguage",
        "langpack.getLanguages",
    ]


    public static let identityControlMethods: Set<String> = [
        "initConnection",
        "connectionIdentity",
        "refreshSession",
        "account.deleteAccount",
    ]


    public static let mediaMethods: Set<String> = [
        "upload.saveFilePart",
        "upload.saveBigFilePart",
        "upload.getFile",
        "upload.getWebFile",
    ]


    public static let identitySocketMethods: Set<String> = ImpulseMethodClasses.loginOnlyMethods
        .union(ImpulseMethodClasses.dualUseMethods)
        .union(ImpulseMethodClasses.pendingMethods)
        .union(ImpulseMethodClasses.publicMethods)
        .union(ImpulseMethodClasses.identityControlMethods)


    public static func allowed(
        signedIn: Bool,
        method: String
    ) -> Bool {
        if signedIn {
            return !ImpulseMethodClasses.loginOnlyMethods.contains(method)
        }

        return ImpulseMethodClasses.identitySocketMethods.contains(method)
    }
}
