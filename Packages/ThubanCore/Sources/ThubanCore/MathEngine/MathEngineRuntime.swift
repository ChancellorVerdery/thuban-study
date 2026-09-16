import Foundation
import JavaScriptCore
import os

/// Owns the `JSContext` that hosts the Compute Engine and the helper script. Not thread-safe on its own: it is
/// only ever touched from inside the `MathEngine` actor.
final class MathEngineRuntime {
    private static let logger = Logger(subsystem: "com.thuban.study", category: "MathEngine")

    private let context: JSContext
    private var api: JSValue
    private var pendingException: String?

    /// Loads the Compute Engine bundle from `Bundle.module`, evaluates the helper script and constructs the single
    /// `ComputeEngine` instance. Takes roughly 0.2 s; callers should do it once.
    init() throws {
        guard let virtualMachine = JSVirtualMachine(), let context = JSContext(virtualMachine: virtualMachine) else {
            throw ThubanError.engine("Could not create a JavaScript context.")
        }
        self.context = context
        self.api = JSValue(undefinedIn: context)
        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = exception?.toString() ?? "unknown JavaScript exception"
        }
        let bundle = try Self.loadBundleSource()
        let started = Date()
        try evaluate(MathEngineScript.commonJSShim, label: "shim")
        try evaluate(bundle, label: "compute-engine bundle")
        try evaluate(MathEngineScript.source, label: "helper script")
        try evaluate(MathEngineScript.bootstrap, label: "bootstrap")
        guard let api = context.objectForKeyedSubscript(MathEngineScript.globalName), api.isObject else {
            throw ThubanError.engine("The helper script did not define \(MathEngineScript.globalName).")
        }
        self.api = api
        let elapsed = Date().timeIntervalSince(started)
        Self.logger.info("Compute Engine loaded in \(elapsed, format: .fixed(precision: 3)) s")
    }

    /// Calls `thubanMath.<function>(jsonText)` and decodes its JSON result. A JavaScript exception, a missing
    /// result or a `{ "error": … }` payload all surface as `ThubanError.engine`.
    func call<Request: Encodable, Response: Decodable>(_ function: String, _ request: Request, as: Response.Type) throws -> Response {
        let data = try callRaw(function, request)
        if let failure = try? JSONDecoder().decode(EngineFailure.self, from: data), let message = failure.error {
            throw ThubanError.engine(message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ThubanError.engine("Unexpected result from \(function): \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private struct EngineFailure: Decodable { var error: String? }

    private func callRaw<Request: Encodable>(_ function: String, _ request: Request) throws -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw ThubanError.engine("Could not encode the request for \(function).")
        }
        guard let jsonText = String(data: payload, encoding: .utf8) else {
            throw ThubanError.engine("Could not encode the request for \(function).")
        }
        pendingException = nil
        let result = api.invokeMethod(function, withArguments: [jsonText])
        if let exception = pendingException {
            pendingException = nil
            throw ThubanError.engine("\(function) failed: \(exception)")
        }
        guard let result, result.isString, let text = result.toString() else {
            throw ThubanError.engine("\(function) returned no result.")
        }
        return Data(text.utf8)
    }

    private func evaluate(_ script: String, label: String) throws {
        pendingException = nil
        context.evaluateScript(script)
        if let exception = pendingException {
            pendingException = nil
            throw ThubanError.engine("Loading the \(label) failed: \(exception)")
        }
    }

    private static func loadBundleSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "compute-engine.umd", withExtension: "cjs") else {
            throw ThubanError.engine("compute-engine.umd.cjs is missing from the package resources.")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ThubanError.engine("Could not read compute-engine.umd.cjs: \(error.localizedDescription)")
        }
    }
}
