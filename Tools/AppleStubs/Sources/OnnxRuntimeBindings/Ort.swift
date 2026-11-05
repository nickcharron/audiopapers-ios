import Foundation

public enum ORTLoggingLevel { case verbose, info, warning, error, fatal }
public enum ORTTensorElementDataType { case float, int64 }

public final class ORTEnv: @unchecked Sendable {
    public init(loggingLevel: ORTLoggingLevel) throws {}
}

public final class ORTSessionOptions {
    public init() throws {}
    public func setIntraOpNumThreads(_ threads: Int32) throws {}
}

public final class ORTRunOptions {}

public final class ORTValue {
    public init(tensorData: NSMutableData, elementType: ORTTensorElementDataType, shape: [NSNumber]) throws {}
    public func tensorData() throws -> NSMutableData { NSMutableData() }
}

public final class ORTSession {
    public init(env: ORTEnv, modelPath: String, sessionOptions: ORTSessionOptions?) throws {}
    public func inputNames() throws -> [String] { [] }
    public func outputNames() throws -> [String] { [] }
    public func run(withInputs inputs: [String: ORTValue], outputNames: Set<String>, runOptions: ORTRunOptions?) throws -> [String: ORTValue] { [:] }
}
