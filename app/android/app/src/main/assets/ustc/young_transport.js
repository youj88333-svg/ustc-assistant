(function(expectedOrigin, capability, replyCapability) {
  'use strict';

  // Install once in the ordinary top-page world after the business document
  // loads. Same-origin school code is trusted by the approved Android boundary;
  // native session/document/operation checks still reject stale returned data.
  const win = window;
  const doc = document;
  const apply = Reflect.apply;
  const getOwn = Object.getOwnPropertyDescriptor;
  const getProto = Object.getPrototypeOf;
  const setProto = Object.setPrototypeOf;
  const define = Object.defineProperty;
  const create = Object.create;
  const freeze = Object.freeze;
  const stringSlice = String.prototype.slice;
  const stringCode = String.prototype.charCodeAt;
  const stringLower = String.prototype.toLowerCase;
  const stringTrim = String.prototype.trim;
  const jsonParse = JSON.parse;
  const jsonStringify = JSON.stringify;
  const finite = Number.isFinite;
  const safeInteger = Number.isSafeInteger;
  const NativePromise = Promise;
  const promiseProto = NativePromise.prototype;
  const nativeThen = promiseProto.then;
  const speciesSymbol = Symbol.species;
  const promiseSpecies = getOwn(NativePromise, speciesSymbol);
  const NativeURL = URL;
  const NativeWeakMap = WeakMap;
  const weakGet = NativeWeakMap.prototype.get;
  const weakSet = NativeWeakMap.prototype.set;
  const NativeSet = Set;
  const setHas = NativeSet.prototype.has;
  const setAdd = NativeSet.prototype.add;
  const NativeWeakSet = WeakSet;
  const weakHas = NativeWeakSet.prototype.has;
  const weakAdd = NativeWeakSet.prototype.add;
  const errors = new NativeWeakSet();
  const NativeTextDecoder = TextDecoder;
  const decodeText = NativeTextDecoder.prototype.decode;
  const NativeTextEncoder = TextEncoder;
  const encodeText = NativeTextEncoder.prototype.encode;
  const typedBytes = getOwn(getProto(Uint8Array.prototype), 'byteLength').get;
  const NativeMutationObserver = MutationObserver;
  const observe = NativeMutationObserver.prototype.observe;
  const takeRecords = NativeMutationObserver.prototype.takeRecords;
  const nativeAddEvent = EventTarget.prototype.addEventListener;
  const nativeRemoveEvent = EventTarget.prototype.removeEventListener;
  const nativeFetch = win.fetch;
  const NativeXHR = XMLHttpRequest;
  const xhrProto = NativeXHR.prototype;
  const xhrOpen = xhrProto.open;
  const xhrSend = xhrProto.send;
  const xhrAbort = xhrProto.abort;
  const xhrHeader = xhrProto.getResponseHeader;
  const responseClone = Response.prototype.clone;
  const headersGet = Headers.prototype.get;
  // Some Chromium versions expose readers only through native stream instances.
  const NativeReadableStream = win.ReadableStream;
  const streamProto = NativeReadableStream && NativeReadableStream.prototype;
  const streamReader = streamProto && streamProto.getReader;
  if (typeof streamReader !== 'function') throw rejection('sourceFailed', 'nativeContext');
  let readerProbe;
  try { readerProbe = apply(streamReader, new NativeReadableStream(), []); }
  catch (_) { throw rejection('sourceFailed', 'nativeContext'); }
  // Older implementations can place generic reader methods one prototype
  // higher. Read data descriptors through the same bounded lookup used below.
  const readChunk = dataValue(readerProbe, 'read');
  const cancelReader = dataValue(readerProbe, 'cancel');
  const releaseReader = dataValue(readerProbe, 'releaseLock');
  try { if (typeof releaseReader === 'function') apply(releaseReader, readerProbe, []); }
  catch (_) {}
  if (typeof readChunk !== 'function' || typeof cancelReader !== 'function' ||
      typeof releaseReader !== 'function') throw rejection('sourceFailed', 'nativeContext');
  const historyObject = win.history;
  const historyProto = History.prototype;
  const historyPush = historyProto.pushState;
  const historyReplace = historyProto.replaceState;

  const MAXIMUM = 1024 * 1024;
  const MAX_DEPTH = 48;
  const MAX_NODES = 50000;
  const PREFIX = '/login/wisdom-group-learning-bg';
  const NAMESPACE = '/login/sc-wisdom-group-learning/';
  const ACTIVITIES_ROUTE = NAMESPACE + 'myproject/SignUp';
  const CALENDAR_ROUTE = NAMESPACE + 'personalInformation/mySchedule';

  function ownValue(object, key) {
    const descriptor = getOwn(object, key);
    if (!descriptor || !getOwn(descriptor, 'value')) return undefined;
    return descriptor.value;
  }

  // Page objects are inspected only through data descriptors. Accessor
  // properties (including an own then/toJSON) are never executed as evidence.
  function dataValue(object, key) {
    let cursor = object;
    for (let depth = 0; cursor !== null && depth < 12; ++depth) {
      const descriptor = getOwn(cursor, key);
      if (descriptor) {
        if (!getOwn(descriptor, 'value')) throw rejection('sourceFailed', 'helperUnavailable');
        return descriptor.value;
      }
      cursor = getProto(cursor);
    }
    return undefined;
  }

  function nativeGetter(prototype, key) {
    const descriptor = getOwn(prototype, key);
    if (!descriptor || typeof descriptor.get !== 'function') {
      throw rejection('sourceFailed', 'nativeContext');
    }
    return descriptor.get;
  }

  // Window/Location used data descriptors for some live properties on older
  // Chromium. Their descriptor representation is not a source identity proof.
  function browserProperty(object, key) {
    const descriptor = getOwn(object, key);
    if (descriptor && typeof descriptor.get === 'function') return descriptor.get;
    if (descriptor && getOwn(descriptor, 'value')) {
      return function() {
        if (this !== object) throw rejection('sourceFailed', 'nativeContext');
        return object[key];
      };
    }
    throw rejection('sourceFailed', 'nativeContext');
  }

  function put(object, key, value) {
    define(object, key, { value: value, writable: true, enumerable: true, configurable: true });
    return value;
  }

  function dto() { return create(null); }
  function array() { return setProto([], null); }
  function rejection(code, reason) {
    const result = dto();
    put(result, 'code', code);
    put(result, 'reason', reason);
    apply(weakAdd, errors, [result]);
    return freeze(result);
  }
  function malformed() { throw rejection('invalidSnapshot', 'sourceFailure'); }

  const responseURL = nativeGetter(Response.prototype, 'url');
  const responseStatus = nativeGetter(Response.prototype, 'status');
  const responseRedirected = nativeGetter(Response.prototype, 'redirected');
  const responseType = nativeGetter(Response.prototype, 'type');
  const responseHeaders = nativeGetter(Response.prototype, 'headers');
  const responseBody = nativeGetter(Response.prototype, 'body');
  const requestURL = nativeGetter(Request.prototype, 'url');
  const requestMethod = nativeGetter(Request.prototype, 'method');
  const urlHref = nativeGetter(NativeURL.prototype, 'href');
  const urlOrigin = nativeGetter(NativeURL.prototype, 'origin');
  const urlPath = nativeGetter(NativeURL.prototype, 'pathname');
  const urlHash = nativeGetter(NativeURL.prototype, 'hash');
  const urlUsername = nativeGetter(NativeURL.prototype, 'username');
  const urlPassword = nativeGetter(NativeURL.prototype, 'password');
  const urlParams = nativeGetter(NativeURL.prototype, 'searchParams');
  const paramsEach = URLSearchParams.prototype.forEach;
  const xhrReady = nativeGetter(xhrProto, 'readyState');
  const xhrStatus = nativeGetter(xhrProto, 'status');
  const xhrURL = nativeGetter(xhrProto, 'responseURL');
  const xhrResponseType = nativeGetter(xhrProto, 'responseType');
  const xhrText = nativeGetter(xhrProto, 'responseText');
  const documentRoot = nativeGetter(Document.prototype, 'documentElement');
  const documentReady = nativeGetter(Document.prototype, 'readyState');
  const locationObject = win.location;
  const locationOrigin = browserProperty(locationObject, 'origin');
  const locationPath = browserProperty(locationObject, 'pathname');
  const locationHref = browserProperty(locationObject, 'href');
  const progressLoaded = nativeGetter(ProgressEvent.prototype, 'loaded');
  const winDocument = browserProperty(win, 'document');
  const winTop = browserProperty(win, 'top');
  if (typeof expectedOrigin !== 'string' || expectedOrigin.length > 512 ||
      typeof capability !== 'string' || capability.length < 16 ||
      typeof replyCapability !== 'string' || replyCapability.length < 16 ||
      capability === replyCapability || apply(winTop, win, []) !== win ||
      apply(urlOrigin, new NativeURL(expectedOrigin), []) !== expectedOrigin) {
    throw rejection('sourceFailed', 'nativeContext');
  }

  const encoder = new NativeTextEncoder();
  let currentScope = null;
  let operationState = null;
  let routeSerial = 0;
  let latestOperation = 0;
  let integrityFailure = false;
  const xhrStates = new NativeWeakMap();

  function utf8Size(text) {
    if (typeof text !== 'string' || text.length > MAXIMUM) malformed();
    return apply(typedBytes, apply(encodeText, encoder, [text]), []);
  }

  function sameDescriptor(object, key, value) {
    const descriptor = getOwn(object, key);
    return !!descriptor && !!getOwn(descriptor, 'value') && descriptor.value === value;
  }

  function intact() {
    try {
      const constructor = getOwn(promiseProto, 'constructor');
      const species = getOwn(NativePromise, speciesSymbol);
      return !integrityFailure &&
        sameDescriptor(win, 'fetch', fetchWithScope) &&
        sameDescriptor(xhrProto, 'open', openWithScope) &&
        sameDescriptor(xhrProto, 'send', sendWithScope) &&
        sameDescriptor(promiseProto, 'then', thenWithScope) &&
        sameDescriptor(historyProto, 'pushState', pushWithStamp) &&
        sameDescriptor(historyProto, 'replaceState', replaceWithStamp) &&
        dataValue(historyObject, 'pushState') === pushWithStamp &&
        dataValue(historyObject, 'replaceState') === replaceWithStamp &&
        constructor && constructor.value === NativePromise &&
        species && promiseSpecies && species.get === promiseSpecies.get &&
        !getOwn(species, 'value');
    } catch (_) { return false; }
  }

  function cancelStep(step) {
    if (!step) return;
    step.cancelled = true;
    step.projectedJson = null;
    if (step.reader) {
      const reader = step.reader;
      step.reader = null;
      try { apply(nativeThen, apply(cancelReader, reader, []), [function() {}, function() {}]); } catch (_) {}
    }
    if (step.xhr) {
      const xhr = step.xhr;
      step.xhr = null;
      try { apply(xhrAbort, xhr, []); } catch (_) {}
    }
  }

  function fail(state, code, reason) {
    if (state && !state.failure) {
      state.failure = rejection(code, reason);
      cancelStep(state.step);
    }
  }

  function changed(reason) {
    ++routeSerial;
    fail(operationState, 'staleResult', reason);
  }

  const mutationObserver = new NativeMutationObserver(function(records) {
    if (operationState && records.length !== 0) changed('contextLost');
  });

  function drainDocumentChanges() {
    const records = apply(takeRecords, mutationObserver, []);
    if (operationState && records.length !== 0) changed('contextLost');
  }

  function pageCurrent(state) {
    try {
      drainDocumentChanges();
      if (apply(winDocument, win, []) !== doc || apply(winTop, win, []) !== win ||
          apply(locationOrigin, locationObject, []) !== expectedOrigin) {
        fail(state, 'staleResult', 'nativeContext');
      } else if (routeSerial !== state.serial ||
          apply(locationHref, locationObject, []) !== state.href ||
          apply(locationPath, locationObject, []) !== state.route) {
        fail(state, 'staleResult', 'mainRoute');
      } else if (apply(documentRoot, doc, []) !== state.root ||
          apply(documentReady, doc, []) !== 'complete') {
        fail(state, 'staleResult', 'contextLost');
      } else if (!intact()) {
        integrityFailure = true;
        fail(state, 'staleResult', 'compiledScript');
      }
    } catch (_) { fail(state, 'staleResult', 'nativeContext'); }
    return !state.failure;
  }

  function stepCurrent(step) {
    const state = operationState;
    return !!state && state === step.owner && state.step === step &&
      !step.cancelled && !step.delivered && pageCurrent(state);
  }

  function demandStep(step) {
    if (!stepCurrent(step)) {
      throw (step.owner.failure || rejection('staleResult', 'stampChanged'));
    }
  }

  function withScope(step, callback, receiver, args) {
    demandStep(step);
    const previous = currentScope;
    currentScope = step;
    try { return apply(callback, receiver, args); }
    finally { currentScope = previous; }
  }

  function safePromise(promise) {
    return !!promise && (typeof promise === 'object' || typeof promise === 'function') &&
      getProto(promise) === promiseProto && !getOwn(promise, 'constructor') &&
      !getOwn(promise, 'then') && sameDescriptor(promiseProto, 'constructor', NativePromise);
  }

  function thenWithScope(onFulfilled, onRejected) {
    const step = currentScope;
    if (!step) return apply(nativeThen, this, [onFulfilled, onRejected]);
    demandStep(step);
    if (!safePromise(this)) {
      fail(step.owner, 'sourceFailed', 'helperUnavailable');
      throw step.owner.failure;
    }
    function wrap(callback) {
      if (typeof callback !== 'function') return callback;
      return function(value) {
        // A callback retained by the page cannot inherit a later operation.
        return withScope(step, callback, this, [value]);
      };
    }
    return apply(nativeThen, this, [wrap(onFulfilled), wrap(onRejected)]);
  }

  function pushWithStamp() {
    if (this === historyObject) changed('mainRoute');
    return apply(historyPush, this, arguments);
  }
  function replaceWithStamp() {
    if (this === historyObject) changed('mainRoute');
    return apply(historyReplace, this, arguments);
  }
  function onHistory() { changed('mainRoute'); }
  function onPageGone() { changed('contextLost'); }

  function fixedPath(endpoint) {
    if (endpoint === 'profile') return '/paramdesign/scMyInfo/info';
    if (endpoint === 'activities') return '/mobile/item/enrolmentList';
    if (endpoint === 'schedule') return '/personal/scCalendar/getPageUserList';
    throw rejection('invalidSnapshot', 'sourceFailure');
  }

  function inputURL(input) {
    if (typeof input === 'string') return input;
    if (!input || (typeof input !== 'object' && typeof input !== 'function')) malformed();
    try { return apply(requestURL, input, []); } catch (_) {}
    try { return apply(urlHref, input, []); } catch (_) {}
    malformed();
  }

  function targetURL(raw, step) {
    if (typeof raw !== 'string' || raw.length > 4096) malformed();
    const parsed = new NativeURL(raw, step.owner.href);
    if (apply(urlOrigin, parsed, []) !== expectedOrigin ||
        apply(urlPath, parsed, []) !== PREFIX + fixedPath(step.endpoint) ||
        apply(urlHash, parsed, []) !== '' || apply(urlUsername, parsed, []) !== '' ||
        apply(urlPassword, parsed, []) !== '') malformed();
    let count = 0;
    const keys = new NativeSet();
    apply(paramsEach, apply(urlParams, parsed, []), [function(value, key) {
      if (apply(setHas, keys, [key])) malformed();
      apply(setAdd, keys, [key]);
      ++count;
      if (step.endpoint === 'profile') malformed();
      if (key === 'pageNo') { if (value !== '' + step.page) malformed(); }
      else if (key === 'pageSize') { if (value !== '10') malformed(); }
      else if (key === 'field') {
        const field = step.endpoint === 'activities' ? 'id,,action' :
          'id,,number,title,place,startTime,endTime';
        if (value !== field) malformed();
      } else if (key === 'now' && step.endpoint === 'schedule') {
        if (value !== step.day) malformed();
      } else malformed();
    }]);
    const expected = step.endpoint === 'profile' ? 0 : (step.endpoint === 'schedule' ? 4 : 3);
    if (count !== expected) malformed();
    return apply(urlHref, parsed, []);
  }

  function checkMethod(input, init) {
    let method = 'GET';
    if (input && typeof input === 'object') {
      try { method = apply(requestMethod, input, []); } catch (_) {}
    }
    if (init !== undefined && init !== null) {
      if (typeof init !== 'object') malformed();
      const override = dataValue(init, 'method');
      if (override !== undefined) method = override;
    }
    if (typeof method !== 'string' || apply(stringLower, method, []) !== 'get') malformed();
  }

  function claimTransport(step, kind, url) {
    demandStep(step);
    if (step.transport !== null) {
      fail(step.owner, 'invalidSnapshot', 'sourceFailure');
      throw step.owner.failure;
    }
    step.transport = kind;
    step.requestURL = url;
  }

  function checkHeaders(mime, length) {
    if (typeof mime !== 'string') malformed();
    let end = mime.length;
    for (let index = 0; index < mime.length; ++index) {
      if (apply(stringCode, mime, [index]) === 59) { end = index; break; }
    }
    const type = apply(stringLower, apply(stringTrim, apply(stringSlice, mime, [0, end]), []), []);
    if (type !== 'application/json') malformed();
    if (length !== null) {
      if (typeof length !== 'string' || length.length === 0 || length.length > 16) malformed();
      let size = 0;
      for (let index = 0; index < length.length; ++index) {
        const digit = apply(stringCode, length, [index]) - 48;
        if (digit < 0 || digit > 9) malformed();
        size = size * 10 + digit;
        if (size > MAXIMUM) malformed();
      }
    }
  }

  function transportFailed(step, code, reason) {
    if (operationState === step.owner && step.owner.step === step && !step.delivered && !step.cancelled) {
      fail(step.owner, code || 'invalidSnapshot', reason || 'sourceFailure');
    }
  }

  function projected(step, raw) {
    demandStep(step);
    if (step.projectedJson !== null || typeof raw !== 'string' || utf8Size(raw) > MAXIMUM) malformed();
    const projection = strictProjection(raw, step.endpoint);
    const encoded = jsonStringify(projection);
    if (typeof encoded !== 'string' || utf8Size(encoded) > MAXIMUM) malformed();
    demandStep(step);
    step.projectedJson = encoded;
  }

  function observeFetchResponse(step, response) {
    try {
      demandStep(step);
      const status = apply(responseStatus, response, []);
      const type = apply(responseType, response, []);
      const finalURL = apply(responseURL, response, []);
      if (!safeInteger(status) || status < 200 || status > 299 ||
          (type !== 'basic' && type !== 'default') ||
          apply(responseRedirected, response, []) !== false ||
          finalURL !== step.requestURL || targetURL(finalURL, step) !== step.requestURL) malformed();
      const headers = apply(responseHeaders, response, []);
      checkHeaders(apply(headersGet, headers, ['content-type']),
        apply(headersGet, headers, ['content-length']));
      // Captured clone and body getters operate on the actual native fetch
      // result. No page Response.json/text/clone method or helper value is read.
      const clone = apply(responseClone, response, []);
      const body = apply(responseBody, clone, []);
      if (!body) malformed();
      const reader = apply(streamReader, body, []);
      step.reader = reader;
      const decoderOptions = dto();
      put(decoderOptions, 'fatal', true);
      const decoder = new NativeTextDecoder('utf-8', decoderOptions);
      const streamOptions = dto();
      put(streamOptions, 'stream', true);
      let bytes = 0;
      let text = '';
      function read() {
        if (!stepCurrent(step)) { cancelStep(step); return; }
        let next;
        try { next = apply(readChunk, reader, []); }
        catch (_) { transportFailed(step); return; }
        apply(nativeThen, next, [function(result) {
          try {
            demandStep(step);
            const done = ownValue(result, 'done');
            if (typeof done !== 'boolean') malformed();
            if (done) {
              text += apply(decodeText, decoder, []);
              step.reader = null;
              apply(releaseReader, reader, []);
              projected(step, text);
              text = '';
              return;
            }
            const chunk = ownValue(result, 'value');
            bytes += apply(typedBytes, chunk, []);
            if (bytes > MAXIMUM) malformed();
            text += apply(decodeText, decoder, [chunk, streamOptions]);
            if (text.length > MAXIMUM) malformed();
            read();
          } catch (_) { text = ''; transportFailed(step); }
        }, function() { text = ''; transportFailed(step); }]);
      }
      read();
    } catch (_) { transportFailed(step); }
  }

  function fetchWithScope(input, init) {
    const step = currentScope;
    if (!step) return apply(nativeFetch, this, arguments);
    try {
      demandStep(step);
      checkMethod(input, init);
      const url = targetURL(inputURL(input), step);
      claimTransport(step, 'fetch', url);
      const promise = apply(nativeFetch, this, arguments);
      // Register before returning the native promise to page code, so a page
      // consumer cannot drain or replace the response before our clone exists.
      apply(nativeThen, promise, [function(response) { observeFetchResponse(step, response); },
        function() { transportFailed(step); }]);
      return promise;
    } catch (error) {
      transportFailed(step);
      throw (step.owner.failure || rejection('invalidSnapshot', 'sourceFailure'));
    }
  }

  function openWithScope(method, url, asynchronous) {
    const step = currentScope;
    if (step) {
      try {
        demandStep(step);
        if (typeof method !== 'string' || apply(stringLower, method, []) !== 'get' ||
            (asynchronous !== undefined && asynchronous !== true) || arguments.length > 3) malformed();
        const target = targetURL(inputURL(url), step);
        const result = apply(xhrOpen, this, arguments);
        apply(weakSet, xhrStates, [this, { step: step, url: target, sent: false }]);
        return result;
      } catch (_) {
        transportFailed(step);
        throw (step.owner.failure || rejection('invalidSnapshot', 'sourceFailure'));
      }
    }
    apply(weakSet, xhrStates, [this, null]);
    return apply(xhrOpen, this, arguments);
  }

  function trustedEvent(event) {
    // Browser-created completion events are trusted; dispatchEvent-created
    // events are false. The reader does not gate on function source text.
    return !!event && event.isTrusted === true;
  }

  function sendWithScope(body) {
    const step = currentScope;
    if (!step) return apply(xhrSend, this, arguments);
    const xhr = this;
    try {
      demandStep(step);
      const opened = apply(weakGet, xhrStates, [xhr]);
      if (!opened || opened.step !== step || opened.sent ||
          (body !== null && body !== undefined)) malformed();
      const type = apply(xhrResponseType, xhr, []);
      // responseType=json has already discarded duplicate JSON keys.
      if (type !== '' && type !== 'text') malformed();
      claimTransport(step, 'xhr', opened.url);
      opened.sent = true;
      step.xhr = xhr;
      let completed = false;
      function remove() {
        apply(nativeRemoveEvent, xhr, ['load', loaded]);
        apply(nativeRemoveEvent, xhr, ['progress', progress]);
        apply(nativeRemoveEvent, xhr, ['error', failed]);
        apply(nativeRemoveEvent, xhr, ['timeout', failed]);
        apply(nativeRemoveEvent, xhr, ['abort', failed]);
      }
      function failed(event) {
        if (!stepCurrent(step)) { remove(); return; }
        if (!trustedEvent(event)) { transportFailed(step); remove(); return; }
        transportFailed(step);
        remove();
      }
      function progress(event) {
        try {
          demandStep(step);
          if (!trustedEvent(event) || apply(progressLoaded, event, []) > MAXIMUM) malformed();
        } catch (_) { transportFailed(step); remove(); }
      }
      function loaded(event) {
        try {
          demandStep(step);
          if (completed || !trustedEvent(event) || apply(xhrReady, xhr, []) !== 4) malformed();
          completed = true;
          const status = apply(xhrStatus, xhr, []);
          const finalURL = apply(xhrURL, xhr, []);
          const type = apply(xhrResponseType, xhr, []);
          // XHR exposes only the final responseURL. This proves the actual
          // native instance ended at the exact fixed request URL; it cannot
          // prove an invisible intermediate redirect chain stayed same-origin
          // or contained no redirects. Fetch separately exposes redirected.
          if (!safeInteger(status) || status < 200 || status > 299 ||
              (type !== '' && type !== 'text') || finalURL !== step.requestURL ||
              targetURL(finalURL, step) !== step.requestURL) malformed();
          checkHeaders(apply(xhrHeader, xhr, ['content-type']),
            apply(xhrHeader, xhr, ['content-length']));
          projected(step, apply(xhrText, xhr, []));
          step.xhr = null;
          remove();
        } catch (_) { transportFailed(step); remove(); }
      }
      apply(nativeAddEvent, xhr, ['load', loaded]);
      apply(nativeAddEvent, xhr, ['progress', progress]);
      apply(nativeAddEvent, xhr, ['error', failed]);
      apply(nativeAddEvent, xhr, ['timeout', failed]);
      apply(nativeAddEvent, xhr, ['abort', failed]);
      return apply(xhrSend, xhr, arguments);
    } catch (_) {
      transportFailed(step);
      throw (step.owner.failure || rejection('invalidSnapshot', 'sourceFailure'));
    }
  }

  // A bounded parser validates the complete raw JSON (including skipped
  // members), rejects duplicate decoded keys, and allocates only white-listed
  // DTOs/scalars. Unknown value strings are skipped in the input buffer.
  function strictProjection(raw, endpoint) {
    let index = 0;
    let nodes = 0;
    function code(at) { return apply(stringCode, raw, [at]); }
    function white() {
      while (index < raw.length) {
        const ch = code(index);
        if (ch !== 32 && ch !== 9 && ch !== 10 && ch !== 13) break;
        ++index;
      }
    }
    function text(decode) {
      const begin = index;
      if (code(index++) !== 34) malformed();
      while (index < raw.length) {
        const ch = code(index++);
        if (ch === 34) {
          return decode ? jsonParse(apply(stringSlice, raw, [begin, index])) : undefined;
        }
        if (ch < 32) malformed();
        if (ch === 92) {
          const escaped = code(index++);
          if (escaped === 117) {
            for (let digit = 0; digit < 4; ++digit) {
              const hex = code(index++);
              if (!((hex >= 48 && hex <= 57) || (hex >= 65 && hex <= 70) || (hex >= 97 && hex <= 102))) malformed();
            }
          } else if (escaped !== 34 && escaped !== 92 && escaped !== 47 &&
              escaped !== 98 && escaped !== 102 && escaped !== 110 && escaped !== 114 && escaped !== 116) malformed();
        }
      }
      malformed();
    }
    function child(mode, key) {
      if (mode === 'envelope') {
        if (key === 'success' || key === 'code') return 'scalar';
        if (key === 'result') return endpoint === 'profile' ? 'profile' : 'page';
      } else if (mode === 'profile') {
        if (key === 'username') return 'scalar';
      } else if (mode === 'page') {
        if (key === 'records') return 'records';
        if (key === 'total' || key === 'current' || key === 'pages' || key === 'size') return 'scalar';
      } else if (mode === 'record') {
        if (key === 'id') return 'scalar';
        if (endpoint === 'activities') {
          if (key === 'itemName' || key === 'st' || key === 'et' || key === 'applySt' ||
              key === 'applyEt' || key === 'placeInfo') return 'scalar';
        } else if (key === 'title' || key === 'place' || key === 'startTime' ||
            key === 'endTime' || key === 'itemId') return 'scalar';
      }
      return 'skip';
    }
    function value(depth, mode) {
      if (depth > MAX_DEPTH || ++nodes > MAX_NODES) malformed();
      white();
      const begin = index;
      const ch = code(index);
      if (ch === 123) {
        if (mode === 'scalar' || mode === 'records') malformed();
        ++index;
        white();
        const result = mode === 'skip' ? null : dto();
        const keys = new NativeSet();
        if (code(index) === 125) { ++index; return result; }
        while (index < raw.length) {
          if (++nodes > MAX_NODES) malformed();
          const key = text(true);
          if (apply(setHas, keys, [key])) malformed();
          apply(setAdd, keys, [key]);
          white();
          if (code(index++) !== 58) malformed();
          const nextMode = child(mode, key);
          const item = value(depth + 1, nextMode);
          if (nextMode !== 'skip') put(result, key, item);
          white();
          const delimiter = code(index++);
          if (delimiter === 125) return result;
          if (delimiter !== 44) malformed();
          white();
        }
        malformed();
      }
      if (ch === 91) {
        if (mode !== 'skip' && mode !== 'records') malformed();
        ++index;
        white();
        const result = mode === 'skip' ? null : array();
        let count = 0;
        if (code(index) === 93) { ++index; return result; }
        while (index < raw.length) {
          if (mode === 'records' && count >= 10) malformed();
          const item = value(depth + 1, mode === 'records' ? 'record' : 'skip');
          if (result) put(result, '' + count, item);
          ++count;
          white();
          const delimiter = code(index++);
          if (delimiter === 93) return result;
          if (delimiter !== 44) malformed();
          white();
        }
        malformed();
      }
      if (mode !== 'skip' && mode !== 'scalar') malformed();
      if (ch === 34) return text(mode !== 'skip');
      if (ch === 116 || ch === 102 || ch === 110) {
        const literal = ch === 116 ? 'true' : (ch === 102 ? 'false' : 'null');
        const end = index + literal.length;
        if (apply(stringSlice, raw, [index, end]) !== literal) malformed();
        index = end;
        return mode === 'skip' ? undefined : (ch === 116 ? true : (ch === 102 ? false : null));
      }
      if (ch === 45) ++index;
      let digit = code(index);
      if (digit === 48) ++index;
      else {
        if (digit < 49 || digit > 57) malformed();
        do { ++index; digit = code(index); } while (digit >= 48 && digit <= 57);
      }
      if (code(index) === 46) {
        ++index;
        digit = code(index);
        if (digit < 48 || digit > 57) malformed();
        do { ++index; digit = code(index); } while (digit >= 48 && digit <= 57);
      }
      if (code(index) === 69 || code(index) === 101) {
        ++index;
        if (code(index) === 43 || code(index) === 45) ++index;
        digit = code(index);
        if (digit < 48 || digit > 57) malformed();
        do { ++index; digit = code(index); } while (digit >= 48 && digit <= 57);
      }
      if (index === begin) malformed();
      if (mode === 'skip') return undefined;
      const number = +apply(stringSlice, raw, [begin, index]);
      if (!finite(number)) malformed();
      return number;
    }
    const result = value(0, 'envelope');
    white();
    if (index !== raw.length || !result || result.success !== true || result.code !== 200 ||
        !result.result) malformed();
    return result;
  }

  function helper() {
    const webpack = dataValue(win, 'webpackJsonp');
    if (!webpack || (typeof webpack !== 'object' && typeof webpack !== 'function')) return null;
    const push = dataValue(webpack, 'push');
    if (typeof push !== 'function') return null;
    const exported = apply(push, webpack, [[[], {}, [['0fea']]]]);
    if (!exported || (typeof exported !== 'object' && typeof exported !== 'function')) return null;
    const candidate = dataValue(exported, 'e');
    return typeof candidate === 'function' ? candidate : null;
  }

  function validDay(day) {
    if (typeof day !== 'string' || day.length !== 10 || day[4] !== '-' || day[7] !== '-') return false;
    for (let index = 0; index < 10; ++index) {
      if (index === 4 || index === 7) continue;
      const digit = apply(stringCode, day, [index]);
      if (digit < 48 || digit > 57) return false;
    }
    const year = +apply(stringSlice, day, [0, 4]);
    const month = +apply(stringSlice, day, [5, 7]);
    const date = +apply(stringSlice, day, [8, 10]);
    if (year < 1 || month < 1 || month > 12 || date < 1) return false;
    const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    return date <= lengths[month - 1] + (month === 2 && leap ? 1 : 0);
  }

  function stateFor(operation) {
    const state = operationState;
    if (!state || state.operation !== operation) throw rejection('staleResult', 'stampChanged');
    pageCurrent(state);
    if (state.failure) throw state.failure;
    return state;
  }

  function prepare(page) {
    if (page !== 'activities' && page !== 'calendar') throw rejection('invalidSnapshot', 'mainRoute');
    if (operationState) throw rejection('busy', 'stampChanged');
    try {
      drainDocumentChanges();
      const route = page === 'activities' ? ACTIVITIES_ROUTE : CALENDAR_ROUTE;
      return intact() && apply(winDocument, win, []) === doc && apply(winTop, win, []) === win &&
        apply(locationOrigin, locationObject, []) === expectedOrigin &&
        apply(locationPath, locationObject, []) === route &&
        apply(documentReady, doc, []) === 'complete' && !!apply(documentRoot, doc, []) && !!helper();
    } catch (_) { return false; }
  }

  function start(operation) {
    if (!safeInteger(operation) || operation <= 0) throw rejection('invalidSnapshot', 'stampChanged');
    if (operationState) throw rejection('busy', 'stampChanged');
    if (operation <= latestOperation) throw rejection('staleResult', 'stampChanged');
    drainDocumentChanges();
    const route = apply(locationPath, locationObject, []);
    if (route !== ACTIVITIES_ROUTE && route !== CALENDAR_ROUTE) throw rejection('staleResult', 'mainRoute');
    const state = { operation: operation, serial: routeSerial,
      href: apply(locationHref, locationObject, []), route: route,
      root: apply(documentRoot, doc, []), stepNumber: 0, step: null, failure: null };
    operationState = state;
    latestOperation = operation;
    pageCurrent(state);
    if (state.failure) throw state.failure;
    if (!helper()) {
      fail(state, 'sourceFailed', 'helperUnavailable');
      throw state.failure;
    }
    if (!pageCurrent(state)) throw state.failure;
    return null;
  }

  function dispatch(operation, number, endpoint, page, day) {
    const state = stateFor(operation);
    if (!safeInteger(number) || number <= 0 || number !== state.stepNumber + 1) {
      throw rejection('staleResult', 'stampChanged');
    }
    if (state.step && !state.step.delivered) throw rejection('busy', 'stampChanged');
    fixedPath(endpoint);
    if ((endpoint === 'profile' && (page !== 0 || (day !== null && day !== undefined && day !== ''))) ||
        (endpoint !== 'profile' && (!safeInteger(page) || page < 1 || page > 1000)) ||
        (endpoint === 'schedule' ? !validDay(day) : (day !== null && day !== undefined && day !== '')) ||
        (endpoint === 'activities' && state.route !== ACTIVITIES_ROUTE) ||
        (endpoint === 'schedule' && state.route !== CALENDAR_ROUTE)) {
      throw rejection('invalidSnapshot', 'sourceFailure');
    }
    const selected = helper();
    if (!selected) {
      fail(state, 'sourceFailed', 'helperUnavailable');
      throw state.failure;
    }
    const parameters = dto();
    if (endpoint !== 'profile') {
      put(parameters, 'field', endpoint === 'activities' ? 'id,,action' : 'id,,number,title,place,startTime,endTime');
      put(parameters, 'pageNo', page);
      put(parameters, 'pageSize', 10);
      if (endpoint === 'schedule') put(parameters, 'now', day);
    }
    freeze(parameters);
    const step = { owner: state, number: number, endpoint: endpoint, page: page, day: day,
      cancelled: false, delivered: false, helperComplete: false, transport: null,
      requestURL: null, projectedJson: null, reader: null, xhr: null };
    state.stepNumber = number;
    state.step = step;
    let promise;
    try {
      promise = withScope(step, selected, undefined, [fixedPath(endpoint), parameters]);
      if (!safePromise(promise)) throw rejection('sourceFailed', 'helperUnavailable');
      apply(nativeThen, promise, [function() {
        if (!stepCurrent(step)) return;
        step.helperComplete = true;
        if (step.transport === null) fail(state, 'sourceFailed', 'helperUnavailable');
      }, function() { transportFailed(step); }]);
    } catch (_) {
      fail(state, 'sourceFailed', 'helperUnavailable');
      throw state.failure;
    }
    if (!pageCurrent(state)) throw state.failure;
    return null;
  }

  function poll(operation, number) {
    const state = stateFor(operation);
    const step = state.step;
    if (!step || step.number !== number || step.delivered || step.cancelled) {
      throw rejection('staleResult', 'stampChanged');
    }
    const result = dto();
    if (!step.helperComplete || step.projectedJson === null) {
      put(result, 'complete', false);
      return freeze(result);
    }
    demandStep(step);
    put(result, 'complete', true);
    put(result, 'projectedJson', step.projectedJson);
    step.projectedJson = null;
    step.delivered = true;
    return freeze(result);
  }

  function finish(operation) {
    if (!operationState || operationState.operation !== operation) throw rejection('staleResult', 'stampChanged');
    const previous = operationState;
    operationState = null;
    cancelStep(previous.step);
    return null;
  }

  try {
    define(win, 'fetch', { value: fetchWithScope, writable: true, enumerable: true, configurable: true });
    define(xhrProto, 'open', { value: openWithScope, writable: true, enumerable: true, configurable: true });
    define(xhrProto, 'send', { value: sendWithScope, writable: true, enumerable: true, configurable: true });
    define(promiseProto, 'then', { value: thenWithScope, writable: true, enumerable: false, configurable: true });
    define(historyProto, 'pushState', { value: pushWithStamp, writable: true, enumerable: true, configurable: true });
    define(historyProto, 'replaceState', { value: replaceWithStamp, writable: true, enumerable: true, configurable: true });
    const options = dto();
    put(options, 'childList', true);
    apply(observe, mutationObserver, [doc, options]);
    apply(nativeAddEvent, win, ['popstate', onHistory]);
    apply(nativeAddEvent, win, ['hashchange', onHistory]);
    apply(nativeAddEvent, win, ['pagehide', onPageGone]);
    apply(nativeAddEvent, win, ['beforeunload', onPageGone]);
  } catch (_) { integrityFailure = true; }

  const api = dto();
  function closed(method) {
    return function() {
      try { return apply(method, undefined, arguments); }
      catch (error) {
        if (apply(weakHas, errors, [error])) throw error;
        fail(operationState, 'sourceFailed', 'sourceFailure');
        throw rejection('sourceFailed', 'sourceFailure');
      }
    };
  }
  put(api, 'prepare', closed(prepare));
  // Navigation must not depend on the destination's lazy-loaded GET module or
  // intact transport wrappers on the landing page. A fixed full navigation
  // creates a new document, where prepare/start still enforce those checks.
  // The namespace callback (including its ticket) must finish naturally first.
  put(api, 'navigationReady', closed(function() {
    try {
      const path = apply(locationPath, locationObject, []);
      return apply(winDocument, win, []) === doc && apply(winTop, win, []) === win &&
        apply(locationOrigin, locationObject, []) === expectedOrigin &&
        path.indexOf(NAMESPACE) === 0 && path.length > NAMESPACE.length &&
        apply(locationHref, locationObject, []).indexOf('?') === -1 &&
        apply(documentReady, doc, []) === 'complete';
    } catch (_) { return false; }
  }));
  put(api, 'start', closed(start));
  put(api, 'dispatch', closed(dispatch));
  put(api, 'poll', closed(poll));
  put(api, 'finish', closed(finish));
  return freeze(api);
})
