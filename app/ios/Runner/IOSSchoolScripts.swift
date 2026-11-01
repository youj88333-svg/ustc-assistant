import Foundation
import CoreFoundation

/// Loads the two fixed read-only source scripts and binds each call to the
/// currently installed main-document generation. This class never accepts or
/// forwards a credential, arbitrary URL, or arbitrary script.
final class IOSSchoolScripts {
  private static let maximumScriptBytes = 512 * 1024
  private static let maximumReplyBytes = 2 * 1024 * 1024
  private static let maximumSafeInteger = 9_007_199_254_740_991
  private static let guardKey = "__ustcIOSDocumentGuardV1"

  private let policy: IOSSchoolPolicy
  private let jwProbeSource: String
  private let youngTransportSource: String
  private let capability: String
  private let replyCapability: String
  private let holderKey: String
  private var installedDocument: Int?

  init(policy: IOSSchoolPolicy, resourceDirectory: URL? = nil) throws {
    if resourceDirectory != nil && !policy.isFixture {
      throw IOSSchoolFailure.unsupportedPlatform
    }
    self.policy = policy
    let resources = try Self.loadResources(resourceDirectory: resourceDirectory)
    jwProbeSource = resources.jwProbe
    youngTransportSource = resources.youngTransport
    capability = Self.randomHex(bytes: 24)
    replyCapability = Self.randomHex(bytes: 24)
    holderKey = "__ustcIOSSchoolCatalog_\(Self.randomHex(bytes: 16))"
  }

  /// Install once per document. Repeated calls in the same JavaScript world
  /// bind the existing fixed API to the new native document generation.
  func install(document: Int) throws -> String {
    guard document >= 0, document <= Self.maximumSafeInteger else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    if let installedDocument, document < installedDocument {
      throw IOSSchoolFailure.staleResult
    }
    installedDocument = document
    switch policy.source {
    case "jw": return try installJW(document: document)
    case "young": return try installYoung(document: document)
    default: throw IOSSchoolFailure.invalidSnapshot
    }
  }

  /// Builds a call only from the source-specific fixed operation vocabulary.
  /// The input map is deliberately closed; `credentialBytes` is never valid.
  func call(_ args: [String: Any]) throws -> String {
    guard let installedDocument,
          let rawDocument = args["document"],
          let document = Self.integer(rawDocument),
          document == installedDocument,
          let method = args["method"] as? String else {
      throw IOSSchoolFailure.staleResult
    }

    let clean: [String: Any]
    if policy.source == "jw" {
      clean = try jwCallArguments(args, document: document, method: method)
    } else if policy.source == "young" {
      clean = try youngCallArguments(args, document: document, method: method)
    } else {
      throw IOSSchoolFailure.invalidSnapshot
    }

    let argsLiteral = try Self.javascriptLiteral(clean)
    let markerLiteral = try Self.javascriptLiteral(replyCapability)
    let holderLiteral = try Self.javascriptLiteral(holderKey)
    let guardLiteral = try Self.javascriptLiteral(Self.guardKey)
    let expectedOriginLiteral = try Self.javascriptLiteral(policy.businessOrigin)
    let worldGuard: String
    let currentCheck: String
    if policy.source == "jw" {
      worldGuard = """
        const guardObject = window[\(guardLiteral)];
        """
      currentCheck = """
        const validGuard = (state) => !!state && state.ready === true &&
          typeof state.nonce === 'string' && state.nonce.length >= 16 &&
          Number.isSafeInteger(state.revision) && state.revision >= 0 &&
          typeof state.href === 'string' && location.href === state.href &&
          location.origin === expectedOrigin && window === window.top &&
          document === holder.documentObject && request.document === holder.document;
        const current = () => {
          try {
            const now = guardObject && typeof guardObject.read === 'function' ? guardObject.read() : null;
            return validGuard(now) && now.nonce === holder.nonce &&
              now.revision === holder.revision && now.href === holder.href &&
              request.document === holder.document;
          } catch (_) { return false; }
        };
        """
    } else {
      // The defaultClient document guard is intentionally invisible here.
      // This is only page-local stale-call association; native checks the
      // isolated guard before and after every result.
      worldGuard = ""
      currentCheck = """
        const current = () => {
          try {
            return !!holder && request.document === holder.document &&
              document === holder.documentObject && window === window.top &&
              location.origin === expectedOrigin && location.href === holder.href;
          } catch (_) { return false; }
        };
        """
    }
    let sourceCheck = """
      const holder = window[\(holderLiteral)];
      const request = \(argsLiteral);
      const marker = \(markerLiteral);
      const expectedOrigin = \(expectedOriginLiteral);
      const fail = (code, reason) => JSON.stringify({replyCapability: marker, error: {code: code, reason: reason}});
      const success = (value) => JSON.stringify({replyCapability: marker, value: value});
      \(worldGuard)
      \(currentCheck)
      const normalizedError = (error) => {
        if (error && typeof error === 'object') {
          const keys = Object.keys(error).sort();
          if (keys.length === 2 && keys[0] === 'code' && keys[1] === 'reason' &&
              holder.validCode(error.code) && holder.validReason(error.reason)) {
            return {code: error.code, reason: error.reason};
          }
        }
        if (error === 'stale_result') return {code: 'staleResult', reason: 'contextLost'};
        if (error === 'invalid_snapshot') return {code: 'invalidSnapshot', reason: 'sourceFailure'};
        if (error === 'busy') return {code: 'busy', reason: 'stampChanged'};
        return {code: 'sourceFailed', reason: 'sourceFailure'};
      };
      """

    let dispatch: String
    switch policy.source {
    case "jw":
      dispatch = """
        if (!holder || holder.version !== 1 || !current()) return fail('staleResult', 'nativeContext');
        try {
          const value = holder.call(request);
          if (!current()) return fail('staleResult', 'contextLost');
          return success(value);
        } catch (error) {
          const normalized = normalizedError(error);
          return JSON.stringify({replyCapability: marker, error: normalized});
        }
        """
    case "young":
      dispatch = """
        if (!holder || holder.version !== 1 || !current()) return fail('staleResult', 'nativeContext');
        try {
          const value = holder.call(request);
          if (!current()) return fail('staleResult', 'contextLost');
          return success(value);
        } catch (error) {
          const normalized = normalizedError(error);
          return JSON.stringify({replyCapability: marker, error: normalized});
        }
        """
    default: throw IOSSchoolFailure.invalidSnapshot
    }

    return """
      (() => {
        'use strict';
        \(sourceCheck)
        \(dispatch)
      })()
      """
  }

  /// Validates the native bridge envelope. Its marker is a correlation value,
  /// never an authentication fact or authority supplied by the page.
  func decode(_ raw: Any) throws -> [String: Any] {
    guard let text = raw as? String,
          text.lengthOfBytes(using: .utf8) <= Self.maximumReplyBytes,
          let bytes = text.data(using: .utf8),
          let decoded = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
          let envelope = decoded as? [String: Any],
          envelope["replyCapability"] as? String == replyCapability else {
      throw IOSSchoolFailure.invalidSnapshot
    }

    if Set(envelope.keys) == Set(["replyCapability", "value"]) {
      guard let value = envelope["value"], Self.isJSONValue(value) else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      if policy.source == "jw" {
        guard let tuple = value as? [Any], tuple.count == 3,
              Self.boolean(tuple[0]) != nil,
              tuple[1] as? String == replyCapability,
              tuple[2] is [String: Any] else {
          throw IOSSchoolFailure.invalidSnapshot
        }
      }
      return envelope
    }

    if Set(envelope.keys) == Set(["replyCapability", "error"]) {
      guard let error = envelope["error"] as? [String: Any],
            Set(error.keys) == Set(["code", "reason"]),
            let code = error["code"] as? String,
            let reason = error["reason"] as? String,
            Self.allowedErrorCodes.contains(code),
            Self.allowedErrorReasons.contains(reason) else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      return envelope
    }
    throw IOSSchoolFailure.invalidSnapshot
  }

  /// Extracts the private JW projection only after checking both reply markers.
  /// Callers must keep the returned JSON inside the controlled C1 handoff.
  func jwPayload(_ envelope: [String: Any]) throws -> String {
    guard Set(envelope.keys) == Set(["replyCapability", "value"]),
          envelope["replyCapability"] as? String == replyCapability,
          let tuple = envelope["value"] as? [Any], tuple.count == 3,
          Self.boolean(tuple[0]) != nil,
          tuple[1] as? String == replyCapability,
          let projection = tuple[2] as? [String: Any],
          JSONSerialization.isValidJSONObject(projection),
          let bytes = try? JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]),
          bytes.count <= Self.maximumReplyBytes,
          let result = String(data: bytes, encoding: .utf8) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    return result
  }

  static var guardBootstrap: String {
    #"""
      (() => {
        'use strict';
        const key = '__ustcIOSDocumentGuardV1';
        if (Object.prototype.hasOwnProperty.call(window, key)) return;
        const root = window;
        const doc = document;
        const bytes = new Uint8Array(24);
        try {
          crypto.getRandomValues(bytes);
        } catch (_) { return; }
        let nonce = '';
        for (let i = 0; i < bytes.length; ++i) nonce += bytes[i].toString(16).padStart(2, '0');
        let revision = 0;
        let retired = false;
        const bump = () => { ++revision; };
        root.addEventListener('popstate', bump, true);
        root.addEventListener('hashchange', bump, true);
        root.addEventListener('pagehide', () => { retired = true; bump(); }, true);
        const read = () => {
          try {
            if (retired || root !== root.top || root.document !== doc) return null;
            return Object.freeze({
              nonce: nonce,
              revision: revision,
              href: String(root.location.href),
              ready: doc.readyState === 'complete'
            });
          } catch (_) {
            return null;
          }
        };
        Object.defineProperty(root, key, {
          value: Object.freeze({read: read}),
          writable: false,
          configurable: false,
          enumerable: false
        });
      })();
      """#
  }

  static var readGuard: String {
    #"""
      (() => {
        try {
          const guard = window['__ustcIOSDocumentGuardV1'];
          if (!guard || typeof guard.read !== 'function') return null;
          const value = guard.read();
          return value === null ? null : JSON.stringify(value);
        } catch (_) {
          return null;
        }
      })()
      """#
  }

  private func installJW(document: Int) throws -> String {
    let originLiteral = try Self.javascriptLiteral(policy.businessOrigin)
    let capLiteral = try Self.javascriptLiteral(capability)
    let replyLiteral = try Self.javascriptLiteral(replyCapability)
    let holderLiteral = try Self.javascriptLiteral(holderKey)
    let guardLiteral = try Self.javascriptLiteral(Self.guardKey)
    let probeKeyLiteral = try Self.javascriptLiteral("__ustcJwProbeV1")
    return """
      (() => {
        'use strict';
        const root = window;
        const doc = document;
        const expectedOrigin = \(originLiteral);
        const capability = \(capLiteral);
        const replyCapability = \(replyLiteral);
        const generation = \(document);
        const holderKey = \(holderLiteral);
        const guardKey = \(guardLiteral);
        const probeKey = \(probeKeyLiteral);
        const read = () => {
          const guard = root[guardKey];
          return guard && typeof guard.read === 'function' ? guard.read() : null;
        };
        const state = read();
        if (!state || state.ready !== true || root !== root.top || root.location.origin !== expectedOrigin) {
          throw {code: 'sourceFailed', reason: 'nativeContext'};
        }
        const match = /^\\/for-std\\/(?:course-table|exam-arrange|student-info)\\/info\\/([0-9]{1,12})\\/?$/.exec(root.location.pathname);
        const selfRouteId = match ? match[1] : null;
        const descriptor = Object.getOwnPropertyDescriptor(root, holderKey);
        if (descriptor) {
          const holder = descriptor.value;
          if (!holder || holder.version !== 1 || holder.documentObject !== doc ||
              typeof holder.bind !== 'function') throw {code: 'sourceFailed', reason: 'nativeContext'};
          holder.bind(generation, state, selfRouteId);
          return true;
        }
        let holder = null;
        const externalCurrent = (nativeGeneration, href) => {
          try {
            const now = read();
            return !!holder && nativeGeneration === holder.document &&
              root === root.top && root.document === doc && now !== null && now.ready === true &&
              now.nonce === holder.nonce && now.revision === holder.revision &&
              now.href === href && now.href === holder.href && root.location.origin === expectedOrigin;
          } catch (_) {
            return false;
          }
        };
        const probe = Object.getOwnPropertyDescriptor(root, probeKey);
        const factory = \(jwProbeSource);
        let api;
        if (probe && probe.value && typeof probe.value.bindGeneration === 'function') {
          api = probe.value;
        } else {
          api = Reflect.apply(factory, root, [expectedOrigin, capability, replyCapability,
            selfRouteId, externalCurrent, generation]);
        }
        holder = {
          version: 1,
          api: api,
          documentObject: doc,
          document: generation,
          nonce: state.nonce,
          revision: state.revision,
          href: state.href,
          selfRouteId: selfRouteId,
          activeOperation: null,
          validCode: (value) => ['sourceFailed', 'staleResult', 'invalidSnapshot', 'busy'].includes(value),
          validReason: (value) => ['nativeContext', 'helperUnavailable', 'contextLost', 'stampChanged', 'sourceFailure'].includes(value),
          bind: function(nextGeneration, nextState, nextRouteId) {
            if (!Number.isSafeInteger(nextGeneration) || nextGeneration < this.document ||
                root.document !== this.documentObject || root !== root.top ||
                root.location.origin !== expectedOrigin || !nextState || nextState.ready !== true) {
              throw {code: 'staleResult', reason: 'nativeContext'};
            }
            const generationChanged = nextGeneration !== this.document;
            if (generationChanged && this.activeOperation !== null) {
              try { this.api.cancel(capability, this.activeOperation); } catch (_) {}
              this.activeOperation = null;
            }
            if (nextRouteId !== this.selfRouteId) {
              throw {code: 'staleResult', reason: 'nativeContext'};
            }
            if (generationChanged) this.api.bindGeneration(capability, nextGeneration);
            this.document = nextGeneration;
            this.nonce = nextState.nonce;
            this.revision = nextState.revision;
            this.href = nextState.href;
          },
          call: function(request) {
            const action = request.action;
            const operation = request.operation;
            if (request.document !== this.document || root.document !== this.documentObject ||
                root !== root.top || root.location.origin !== expectedOrigin) {
              throw {code: 'staleResult', reason: 'nativeContext'};
            }
            if (request.selfRouteId !== undefined && request.selfRouteId !== this.selfRouteId) {
              throw {code: 'staleResult', reason: 'nativeContext'};
            }
            let result;
            if (action === 'start') {
              this.activeOperation = operation;
              result = this.api.start(capability, operation);
            } else if (action === 'data') {
              this.activeOperation = operation;
              result = this.api.data(capability, operation, request.semesterId);
            } else if (action === 'collect') {
              this.activeOperation = operation;
              result = this.api.collect(capability, operation, request.semesterId);
            } else if (action === 'poll') {
              result = this.api.poll(capability, operation);
            } else if (action === 'cancel') {
              result = this.api.cancel(capability, operation);
            } else {
              throw {code: 'invalidSnapshot', reason: 'sourceFailure'};
            }
            if (Array.isArray(result) && result.length === 3 && result[1] === replyCapability &&
                result[2] && result[2].phase !== 'running') this.activeOperation = null;
            return result;
          }
        };
        holder.bind(generation, state, selfRouteId);
        Object.defineProperty(root, holderKey, {
          value: holder,
          writable: false,
          configurable: false,
          enumerable: false
        });
        return true;
      })()
      """
  }

  private func installYoung(document: Int) throws -> String {
    let originLiteral = try Self.javascriptLiteral(policy.businessOrigin)
    let capLiteral = try Self.javascriptLiteral(capability)
    let replyLiteral = try Self.javascriptLiteral(replyCapability)
    let holderLiteral = try Self.javascriptLiteral(holderKey)
    return """
      (() => {
        'use strict';
        const root = window;
        const doc = document;
        const expectedOrigin = \(originLiteral);
        const capability = \(capLiteral);
        const replyCapability = \(replyLiteral);
        const generation = \(document);
        const holderKey = \(holderLiteral);
        const href = String(root.location.href);
        if (root.document !== doc || root !== root.top || root.location.origin !== expectedOrigin ||
            doc.readyState !== 'complete') {
          throw {code: 'sourceFailed', reason: 'nativeContext'};
        }
        const descriptor = Object.getOwnPropertyDescriptor(root, holderKey);
        if (descriptor) {
          const holder = descriptor.value;
          if (!holder || holder.version !== 1 || holder.documentObject !== doc ||
              typeof holder.bind !== 'function') throw {code: 'sourceFailed', reason: 'nativeContext'};
          holder.bind(generation, href);
          return true;
        }
        const factory = \(youngTransportSource);
        const api = Reflect.apply(factory, root, [expectedOrigin, capability, replyCapability]);
        const holder = {
          version: 1,
          api: api,
          documentObject: doc,
          document: generation,
          href: href,
          activeOperation: null,
          validCode: (value) => ['sourceFailed', 'staleResult', 'invalidSnapshot', 'busy'].includes(value),
          validReason: (value) => [
            'stampChanged', 'nativeContext', 'mainRoute', 'historyPushChanged',
            'historyReplaceChanged', 'historyTraversal', 'historyHashChanged',
            'routeAddressChanged', 'historyNativeChanged', 'contextLost',
            'compiledScript', 'helperUnavailable', 'preparationTimedOut',
            'sourceFailure', 'requestTarget', 'requestOrigin', 'requestPath',
            'requestQueryDuplicate', 'requestQueryUnexpected', 'requestQueryShape',
            'requestMethod', 'transportAmbiguous', 'responseTarget', 'responseStatus',
            'responseMime', 'responseTooLarge', 'responseFormat', 'transportFailed',
            'helperRejected', 'xhrConfiguration'
          ].includes(value),
          bind: function(nextGeneration, nextHref) {
            if (!Number.isSafeInteger(nextGeneration) || nextGeneration < this.document ||
                root.document !== this.documentObject || root !== root.top ||
                root.location.origin !== expectedOrigin || typeof nextHref !== 'string' ||
                root.location.href !== nextHref || doc.readyState !== 'complete') {
              throw {code: 'staleResult', reason: 'nativeContext'};
            }
            const generationChanged = nextGeneration !== this.document;
            if (generationChanged && this.activeOperation !== null) {
              try { this.api.finish(this.activeOperation); } catch (_) {}
              this.activeOperation = null;
            }
            this.document = nextGeneration;
            this.href = nextHref;
          },
          call: function(request) {
            if (request.document !== this.document || root.document !== this.documentObject ||
                root !== root.top || root.location.origin !== expectedOrigin) {
              throw {code: 'staleResult', reason: 'nativeContext'};
            }
            if (request.method === 'prepare') return this.api.prepare(request.page);
            if (request.method === 'navigationReady') return this.api.navigationReady();
            if (request.method === 'start') {
              this.activeOperation = request.operation;
              return this.api.start(request.operation);
            }
            if (request.method === 'dispatch') {
              if (this.activeOperation !== request.operation) throw {code: 'staleResult', reason: 'stampChanged'};
              return this.api.dispatch(request.operation, request.step, request.endpoint, request.page, request.day);
            }
            if (request.method === 'poll') {
              if (this.activeOperation !== request.operation) throw {code: 'staleResult', reason: 'stampChanged'};
              return this.api.poll(request.operation, request.step);
            }
            if (request.method === 'finish') {
              if (this.activeOperation !== request.operation) throw {code: 'staleResult', reason: 'stampChanged'};
              try { return this.api.finish(request.operation); }
              finally { this.activeOperation = null; }
            }
            throw {code: 'invalidSnapshot', reason: 'sourceFailure'};
          }
        };
        holder.bind(generation, href);
        Object.defineProperty(root, holderKey, {
          value: holder,
          writable: false,
          configurable: false,
          enumerable: false
        });
        return true;
      })()
      """
  }

  private func jwCallArguments(
    _ args: [String: Any], document: Int, method: String
  ) throws -> [String: Any] {
    guard method == "probe", let action = args["action"] as? String else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    let allowed: Set<String>
    switch action {
    case "start", "poll", "cancel":
      allowed = ["method", "document", "action", "operation", "selfRouteId"]
    case "data", "collect":
      allowed = ["method", "document", "action", "operation", "semesterId", "selfRouteId"]
    default: throw IOSSchoolFailure.invalidSnapshot
    }
    guard Set(args.keys).isSubset(of: allowed),
          args.keys.contains("method"), args.keys.contains("document"),
          args.keys.contains("action"), args.keys.contains("operation"),
          let operation = Self.integer(args["operation"]),
          operation > 0, operation <= Self.maximumSafeInteger else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    var result: [String: Any] = [
      "method": method,
      "document": document,
      "action": action,
      "operation": operation,
    ]
    if action == "data" || action == "collect" {
      guard let semesterId = Self.integer(args["semesterId"]),
            semesterId > 0, semesterId <= Int(Int32.max) else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      result["semesterId"] = semesterId
    }
    if let selfRouteId = args["selfRouteId"], !(selfRouteId is NSNull) {
      guard let value = selfRouteId as? String,
            value.utf8.count <= 12,
            value.range(of: "^[0-9]{1,12}$", options: .regularExpression) != nil else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      result["selfRouteId"] = value
    }
    return result
  }

  private func youngCallArguments(
    _ args: [String: Any], document: Int, method: String
  ) throws -> [String: Any] {
    let allowed: Set<String>
    switch method {
    case "prepare": allowed = ["method", "document", "page"]
    case "navigationReady": allowed = ["method", "document"]
    case "start": allowed = ["method", "document", "operation"]
    case "dispatch": allowed = ["method", "document", "operation", "step", "endpoint", "page", "day"]
    case "poll": allowed = ["method", "document", "operation", "step"]
    case "finish": allowed = ["method", "document", "operation"]
    default: throw IOSSchoolFailure.invalidSnapshot
    }
    guard Set(args.keys).isSubset(of: allowed),
          args.keys.contains("method"), args.keys.contains("document") else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    var result: [String: Any] = ["method": method, "document": document]
    if method == "prepare" {
      guard let page = args["page"] as? String,
            page == "activities" || page == "calendar" else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      result["page"] = page
    } else if method == "start" || method == "finish" {
      guard let operation = Self.integer(args["operation"]),
            operation > 0, operation <= Self.maximumSafeInteger else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      result["operation"] = operation
    } else if method == "poll" {
      guard let operation = Self.integer(args["operation"]),
            operation > 0, operation <= Self.maximumSafeInteger,
            let step = Self.integer(args["step"]), step > 0, step <= 64_000 else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      result["operation"] = operation
      result["step"] = step
    } else if method == "dispatch" {
      guard let operation = Self.integer(args["operation"]),
            operation > 0, operation <= Self.maximumSafeInteger,
            let step = Self.integer(args["step"]), step > 0, step <= 64_000,
            let endpoint = args["endpoint"] as? String,
            ["profile", "schedule", "activities"].contains(endpoint),
            let page = Self.integer(args["page"]), page >= 0, page <= 1_000 else {
        throw IOSSchoolFailure.invalidSnapshot
      }
      let day = args["day"] as? String
      if (endpoint == "profile" && (page != 0 || day != nil)) ||
          (endpoint != "profile" && page == 0) ||
          (endpoint == "schedule" ? !(day.map(Self.validDay) ?? false) : day != nil) {
        throw IOSSchoolFailure.invalidSnapshot
      }
      result["operation"] = operation
      result["step"] = step
      result["endpoint"] = endpoint
      result["page"] = page
      if let day { result["day"] = day }
    }
    return result
  }

  private static func loadResources(resourceDirectory: URL?) throws -> (jwProbe: String, youngTransport: String) {
    let candidates: [URL]
    if let resourceDirectory {
      candidates = [resourceDirectory]
    } else if let root = Bundle.main.resourceURL {
      candidates = [root, root.appendingPathComponent("ustc", isDirectory: true)]
    } else {
      throw IOSSchoolFailure.sourceFailed
    }
    for directory in candidates {
      let jwURL = directory.appendingPathComponent("jw_probe.js", isDirectory: false)
      let youngURL = directory.appendingPathComponent("young_transport.js", isDirectory: false)
      guard FileManager.default.fileExists(atPath: jwURL.path),
            FileManager.default.fileExists(atPath: youngURL.path) else { continue }
      let jwData = try Data(contentsOf: jwURL, options: [.mappedIfSafe])
      let youngData = try Data(contentsOf: youngURL, options: [.mappedIfSafe])
      guard !jwData.isEmpty, !youngData.isEmpty,
            jwData.count <= maximumScriptBytes, youngData.count <= maximumScriptBytes,
            let jw = String(data: jwData, encoding: .utf8),
            let young = String(data: youngData, encoding: .utf8),
            jw.hasPrefix("(function"), young.hasPrefix("(function"),
            jw.contains("api.bindGeneration") && jw.contains("api.collect") && jw.contains("api.data"),
            young.contains("put(api, 'navigationReady'") && young.contains("put(api, 'dispatch'") &&
              young.contains("put(api, 'finish'") else {
        throw IOSSchoolFailure.sourceFailed
      }
      return (jw, young)
    }
    throw IOSSchoolFailure.sourceFailed
  }

  private static func javascriptLiteral(_ value: Any) throws -> String {
    guard JSONSerialization.isValidJSONObject(["value": value]),
          let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
          let text = String(data: bytes, encoding: .utf8) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    return text
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int.min), double <= Double(Int.max) else { return nil }
    return number.intValue
  }

  private static func boolean(_ value: Any) -> Bool? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  private static func isJSONValue(_ value: Any) -> Bool {
    if value is NSNull || value is String { return true }
    if let number = value as? NSNumber { return number.doubleValue.isFinite }
    if let array = value as? [Any] { return array.allSatisfy(isJSONValue) }
    if let dictionary = value as? [String: Any] {
      return dictionary.values.allSatisfy(isJSONValue)
    }
    return false
  }

  private static func validDay(_ text: String) -> Bool {
    guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
      return false
    }
    let pieces = text.split(separator: "-").compactMap { Int($0) }
    guard pieces.count == 3, pieces[0] >= 1 else { return false }
    var calendar = Calendar(identifier: .gregorian)
    guard let timeZone = TimeZone(secondsFromGMT: 0) else { return false }
    calendar.timeZone = timeZone
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = pieces[0]
    components.month = pieces[1]
    components.day = pieces[2]
    guard let date = calendar.date(from: components) else { return false }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    return actual.year == components.year && actual.month == components.month && actual.day == components.day
  }

  private static func randomHex(bytes count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }

  private static let allowedErrorCodes: Set<String> = [
    "sourceFailed", "staleResult", "invalidSnapshot", "busy"
  ]

  private static let allowedErrorReasons: Set<String> = [
    "stampChanged", "nativeContext", "mainRoute", "historyPushChanged",
    "historyReplaceChanged", "historyTraversal", "historyHashChanged",
    "routeAddressChanged", "historyNativeChanged", "contextLost",
    "compiledScript", "helperUnavailable", "preparationTimedOut",
    "sourceFailure", "requestTarget", "requestOrigin", "requestPath",
    "requestQueryDuplicate", "requestQueryUnexpected", "requestQueryShape",
    "requestMethod", "transportAmbiguous", "responseTarget", "responseStatus",
    "responseMime", "responseTooLarge", "responseFormat", "transportFailed",
    "helperRejected", "xhrConfiguration"
  ]
}
