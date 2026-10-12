#ifndef RUNNER_JW_PROBE_SCRIPT_H_
#define RUNNER_JW_PROBE_SCRIPT_H_

// Candidate contract probe only. No response text or browser authentication
// assets cross this helper's fixed projection boundary. It is installed only
// in a fresh native-created isolated world, never the page's shared JS world.
inline constexpr wchar_t kJwProbeInstaller[] = LR"JWPROBE(
(function(expectedOrigin, capability, replyCapability, selfRouteId) {
  'use strict';
  if (this !== this.top || this.location.origin !== expectedOrigin) return;
  const root = this;
  const define = Object.defineProperty;
  const freeze = Object.freeze;
  const create = Object.create;
  const setPrototype = Object.setPrototypeOf;
  const ownDescriptor = Object.getOwnPropertyDescriptor;
  const isArray = Array.isArray;
  const apply = Reflect.apply;
  const fetchOriginal = root.fetch.bind(root);
  const parseJson = JSON.parse.bind(JSON);
  const stringifyJson = JSON.stringify.bind(JSON);
  const parseHtml = DOMParser.prototype.parseFromString;
  const parser = new DOMParser();
  const Abort = AbortController;
  const abort = AbortController.prototype.abort;
  const signal = Object.getOwnPropertyDescriptor(AbortController.prototype, 'signal').get;
  const responseStatus = Object.getOwnPropertyDescriptor(Response.prototype, 'status').get;
  const responseUrl = Object.getOwnPropertyDescriptor(Response.prototype, 'url').get;
  const responseBody = Object.getOwnPropertyDescriptor(Response.prototype, 'body').get;
  const responseHeaders = Object.getOwnPropertyDescriptor(Response.prototype, 'headers').get;
  const headerGet = Headers.prototype.get;
  const getReader = ReadableStream.prototype.getReader;
  const read = ReadableStreamDefaultReader.prototype.read;
  const cancelReader = ReadableStreamDefaultReader.prototype.cancel;
  const Decoder = TextDecoder;
  const decode = TextDecoder.prototype.decode;
  const queryDocument = Document.prototype.querySelectorAll;
  const queryElement = Element.prototype.querySelectorAll;
  const closestElement = Element.prototype.closest;
  const nodeListLength = Object.getOwnPropertyDescriptor(NodeList.prototype, 'length').get;
  const nodeListItem = NodeList.prototype.item;
  const getAttribute = Element.prototype.getAttribute;
  const textContent = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent').get;
  const nextElement = Object.getOwnPropertyDescriptor(Element.prototype, 'nextElementSibling').get;
  const nextNode = Object.getOwnPropertyDescriptor(Node.prototype, 'nextSibling').get;
  const nodeType = Object.getOwnPropertyDescriptor(Node.prototype, 'nodeType').get;
  const tagName = Object.getOwnPropertyDescriptor(Element.prototype, 'tagName').get;
  const byteLength = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), 'byteLength').get;
  const optionSelected = Object.getOwnPropertyDescriptor(HTMLOptionElement.prototype, 'selected').get;
  const charCodeAt = String.prototype.charCodeAt;
  const stringSlice = String.prototype.slice;
  const regexExec = RegExp.prototype.exec;
  const number = Number;
  const safeInteger = Number.isSafeInteger;
  const timer = root.setTimeout.bind(root);
  const clearTimer = root.clearTimeout.bind(root);
  const worker = root.navigator.serviceWorker;
  const workerController = worker ?
      Object.getOwnPropertyDescriptor(ServiceWorkerContainer.prototype, 'controller').get : null;
  const addListener = EventTarget.prototype.addEventListener;
  const workerControlled = () => worker !== undefined && worker !== null &&
      call(workerController, worker, []) !== null;
  // Capture rather than consulting page-replaced JSON or DOM methods later.
  void stringifyJson;
  let slot = null;
  let lastOperation = 0;
  const call = (fn, receiver, args) => apply(fn, receiver, args);
  const record = () => create(null);
  const array = () => setPrototype([], null);
  const slice = (value, start, end) => call(stringSlice, value, [start, end]);
  // RegExp.prototype.test consults the page-visible expression.exec method.
  // Invoke the original exec directly instead, including for validation.
  const test = (expression, value) => call(regexExec, expression, [value]) !== null;
  const exec = (expression, value) => call(regexExec, expression, [value]);
  const clean = value => {
    // Avoid String.replace -> RegExp@@replace -> mutable exec hooks. This is
    // the ECMAScript whitespace set, normalized without page callbacks.
    let result = '';
    let separated = false;
    for (let i = 0; i < value.length; ++i) {
      const character = call(charCodeAt, value, [i]);
      const whitespace = (character >= 9 && character <= 13) || character === 32 ||
          character === 160 || character === 5760 || (character >= 8192 && character <= 8202) ||
          character === 8232 || character === 8233 || character === 8239 ||
          character === 8287 || character === 12288 || character === 65279;
      if (whitespace) {
        if (result.length > 0) separated = true;
      } else {
        if (separated) result += ' ';
        result += value[i];
        separated = false;
      }
    }
    return result;
  };
  const text = node => node ? clean(call(textContent, node, [])) : '';
  const attr = (node, name) => call(getAttribute, node, [name]);
  const nodes = (node, selector, documentNode = false) => {
    const found = call(documentNode ? queryDocument : queryElement, node, [selector]);
    const length = call(nodeListLength, found, []);
    const result = array();
    for (let i = 0; i < length; ++i) result[i] = call(nodeListItem, found, [i]);
    return result;
  };
  const sibling = node => call(nextElement, node, []);
  const labelPattern = /^(?:\u5b66\u751f)?\u5b66\u53f7\s*[:\uff1a]?$/;
  const codePattern = /^[A-Z0-9]{5,24}$/;
  const methods = ['none', 'table', 'definitionList', 'listGroup', 'label', 'mixed'];
  const phases = ['running', 'done', 'cancelled', 'failed'];
  const codes = ['pending', 'ok', 'cancelled', 'student_context_missing',
    'identity_http', 'identity_mime', 'identity_too_large', 'identity_schema',
    'course_http', 'course_mime', 'course_too_large', 'course_schema',
    'exams_http', 'exams_mime', 'exams_too_large', 'exams_schema',
    'network_failed', 'timed_out', 'helper_unavailable', 'stale_result', 'service_worker_controlled',
    'index_http', 'index_mime', 'index_too_large', 'index_schema',
    'datum_http', 'datum_mime', 'datum_too_large', 'datum_schema', 'semester_unknown', 'identity_changed'];
  const stages = ['identity', 'course', 'exams'];
  const maxSemesterOptions = 256;
  const courseReasons = ['none', 'select_missing', 'select_conflict', 'options_empty',
    'options_limit', 'option_value', 'option_duplicate', 'option_name', 'selected_conflict',
    'literal_missing', 'literal_duplicate', 'literal_unsupported', 'literal_invalid',
    'literal_limit', 'literal_key_conflict', 'catalog_empty', 'catalog_limit',
    'catalog_id', 'catalog_duplicate', 'catalog_name', 'selection_missing',
    'selection_invalid', 'selection_unknown'];
  const courseSources = ['none', 'serverSelect', 'serverJson'];
  const contains = (values, value) => {
    for (let i = 0; i < values.length; ++i) if (values[i] === value) return true;
    return false;
  };
  const emptySummary = () => {
    const summary = record();
    summary.identityLabels = 0;
    summary.semesterOptions = 0;
    summary.semesterSelect = false;
    summary.semesterVariables = record();
    summary.semesterVariables.allSemesters = false;
    summary.semesterVariables.semesters = false;
    summary.semesterVariables.semesterId = false;
    summary.semesterVariables.bizTypeId = false;
    summary.courseDiagnostics = record();
    summary.courseDiagnostics.reason = 'none';
    summary.courseDiagnostics.source = 'none';
    summary.courseDiagnostics.serverOptions = 0;
    summary.courseDiagnostics.liveOptions = 0;
    summary.courseDiagnostics.literalAssignments = 0;
    summary.courseDiagnostics.literalItems = 0;
    summary.courseDiagnostics.literalParsed = false;
    summary.stageResults = record();
    summary.stageResults.identity = 'pending';
    summary.stageResults.course = 'pending';
    summary.stageResults.exams = 'pending';
    summary.examTables = 0;
    summary.examHeader = false;
    summary.examRows = 0;
    summary.pagination = false;
    return summary;
  };
  const bounded = (value, maximum) => safeInteger(value) && value >= 0 && value <= maximum;
  const invalidateWorker = state => {
    state.blockedByWorker = true;
    state.identity = null; state.semesters = null; state.summary = null; state.diagnostics = null;
    if (!state.cancelled) {
      state.phase = state.settled ? 'failed' : 'running';
      state.code = 'service_worker_controlled';
    }
    if (state.controller) call(abort, state.controller, []);
  };
  // All exported objects have null prototypes and freshly copied primitives;
  // page mutations of prototypes/toJSON cannot replace or extend the result.
  const project = state => {
    if (state === slot && (state.blockedByWorker || workerControlled())) invalidateWorker(state);
    if (state.dataProbe) return projectData(state);
    const out = record();
    out.operation = state.operation;
    out.phase = contains(phases, state.phase) ? state.phase : 'failed';
    out.code = contains(codes, state.code) ? state.code : 'helper_unavailable';
    if (contains(stages, state.stage)) out.stage = state.stage;
    if (!state.cancelled && state.identity) {
      const identity = record();
      identity.candidateCount = bounded(state.identity.candidateCount, 32)
          ? state.identity.candidateCount : 0;
      identity.method = contains(methods, state.identity.method) ? state.identity.method : 'none';
      if (identity.candidateCount === 1 && typeof state.identity.accountCode === 'string' &&
          test(codePattern, state.identity.accountCode)) identity.accountCode = state.identity.accountCode;
      out.identity = identity;
    }
    if (!state.cancelled && state.summary) {
      const summary = emptySummary();
      const counts = ['identityLabels', 'semesterOptions', 'examTables', 'examRows'];
      for (let i = 0; i < counts.length; ++i) {
        const key = counts[i];
        const maximum = key === 'semesterOptions' ? maxSemesterOptions : key === 'examTables' ? 10 : 10000;
        summary[key] = bounded(state.summary[key], maximum)
            ? state.summary[key] : 0;
      }
      const flags = ['semesterSelect', 'examHeader', 'pagination'];
      for (let i = 0; i < flags.length; ++i) {
        const key = flags[i];
        summary[key] = state.summary[key] === true;
      }
      const variables = ['allSemesters', 'semesters', 'semesterId', 'bizTypeId'];
      for (let i = 0; i < variables.length; ++i) {
        const key = variables[i];
        summary.semesterVariables[key] = state.summary.semesterVariables[key] === true;
      }
      for (let i = 0; i < stages.length; ++i) {
        const stage = stages[i];
        const result = state.summary.stageResults[stage];
        summary.stageResults[stage] = contains(codes, result) ? result : 'helper_unavailable';
      }
      const diagnostic = state.summary.courseDiagnostics;
      summary.courseDiagnostics.reason = contains(courseReasons, diagnostic.reason)
          ? diagnostic.reason : 'literal_invalid';
      summary.courseDiagnostics.source = contains(courseSources, diagnostic.source)
          ? diagnostic.source : 'none';
      const diagnosticCounts = ['serverOptions', 'liveOptions', 'literalAssignments', 'literalItems'];
      for (let i = 0; i < diagnosticCounts.length; ++i) {
        const key = diagnosticCounts[i];
        summary.courseDiagnostics[key] = bounded(diagnostic[key], 10000) ? diagnostic[key] : 0;
      }
      summary.courseDiagnostics.literalParsed = diagnostic.literalParsed === true;
      out.summary = summary;
    }
    if (!state.cancelled && state.semesters) {
      const semesters = array();
      const seen = record();
      let selected = 0;
      let valid = state.semesters.length <= maxSemesterOptions;
      for (let i = 0; valid && i < state.semesters.length; ++i) {
        const candidate = state.semesters[i];
        valid = safeInteger(candidate.id) && candidate.id > 0 && candidate.id <= 2147483647 && !seen[candidate.id] &&
            typeof candidate.name === 'string' && candidate.name.length > 0 && candidate.name.length <= 120 &&
            !test(/[\u0000-\u001f\u007f-\u009f<>]/, candidate.name);
        if (!valid) break;
        seen[candidate.id] = true;
        const semester = record();
        semester.id = candidate.id;
        semester.name = candidate.name;
        semester.selected = candidate.selected === true;
        if (semester.selected) ++selected;
        semesters[semesters.length] = semester;
      }
      if (valid && selected <= 1) out.semesters = semesters;
    }
    return out;
  };
  const reply = state => {
    const out = array();
    out[0] = state.settled === true;
    out[1] = replyCapability;
    out[2] = project(state);
    return out;
  };
  const failure = (operation, code, trusted = true) => {
    const state = record();
    state.operation = safeInteger(operation) && operation > 0 ? operation : 0;
    state.phase = 'failed';
    state.code = trusted ? code : 'helper_unavailable';
    state.settled = true;
    if (!trusted) {
      const out = array();
      out[0] = true; out[1] = null; out[2] = project(state);
      return out;
    }
    return reply(state);
  };
  const current = state => root.location.origin === expectedOrigin &&
      root.location.pathname === state.pathname && root.location.search === state.search &&
      root.location.hash === state.hash;
  const requireCurrent = state => {
    if (state.cancelled || !current(state)) throw 'stale_result';
    if (state.blockedByWorker || workerControlled()) {
      invalidateWorker(state);
      throw 'service_worker_controlled';
    }
  };
  const readHtml = async (state, stage, path) => {
    requireCurrent(state);
    state.stage = state.dataProbe && stage === 'identity'
        ? (state.diagnostics.identityReads === 0 ? 'identityBefore' : 'identityAfter') : stage;
    state.timedOut = false;
    const controller = new Abort();
    const decoder = new Decoder('utf-8', {fatal: true});
    state.controller = controller;
    let reader = null;
    const timeout = timer(() => {
      state.timedOut = true;
      call(abort, controller, []);
    }, 30000);
    try {
      const options = record();
      options.method = 'GET';
      options.credentials = 'same-origin';
      options.redirect = 'error';
      options.cache = 'no-store';
      options.signal = call(signal, controller, []);
      const response = await fetchOriginal(expectedOrigin + path, options);
      requireCurrent(state);
      if (call(responseStatus, response, []) !== 200 ||
          call(responseUrl, response, []) !== expectedOrigin + path) throw stage + '_http';
      const headers = call(responseHeaders, response, []);
      const mime = call(headerGet, headers, ['content-type']);
      if (typeof mime !== 'string' || !test(/^text\/html\s*(?:;[^\r\n]*)?$/i, mime)) throw stage + '_mime';
      const length = call(headerGet, headers, ['content-length']);
      if (length !== null && test(/^[0-9]+$/, length) && number(length) > 2097152) throw stage + '_too_large';
      const body = call(responseBody, response, []);
      if (!body) throw stage + '_schema';
      reader = call(getReader, body, []);
      let bytes = 0;
      let html = '';
      while (true) {
        const part = await call(read, reader, []);
        requireCurrent(state);
        if (part.done) break;
        bytes += call(byteLength, part.value, []);
        if (bytes > 2097152) throw stage + '_too_large';
        html += call(decode, decoder, [part.value, {stream: true}]);
      }
      html += call(decode, decoder, []);
      requireCurrent(state);
      return call(parseHtml, parser, [html, 'text/html']);
    } catch (error) {
      call(abort, controller, []);
      if (reader) {
        try { await call(cancelReader, reader, []); } catch (_) {}
      }
      if (state.cancelled) throw 'cancelled';
      if (state.blockedByWorker || workerControlled()) throw 'service_worker_controlled';
      if (state.timedOut) throw 'timed_out';
      if (!current(state)) throw 'stale_result';
      if (typeof error === 'string' && contains(codes, error)) throw error;
      throw 'network_failed';
    } finally {
      clearTimer(timeout);
      state.controller = null;
    }
  };
  const identityProjection = (html, summary) => {
    const candidates = record();
    let candidateCount = 0;
    let accountCode = null;
    let method = 'none';
    let malformed = false;
    const accept = (label, value, extraction) => {
      if (!test(labelPattern, label)) return;
      if (!test(codePattern, value)) { malformed = true; return; }
      if (!candidates[value]) {
        candidates[value] = true;
        ++candidateCount;
        accountCode = value;
      }
      if (method === 'none') method = extraction;
      else if (method !== extraction) method = 'mixed';
    };
    const rows = nodes(html, 'table tr', true);
    for (let i = 0; i < rows.length; ++i) {
      const cells = nodes(rows[i], ':scope > th, :scope > td');
      for (let j = 0; j + 1 < cells.length; ++j) accept(text(cells[j]), text(cells[j + 1]), 'table');
    }
    const terms = nodes(html, 'dt', true);
    for (let i = 0; i < terms.length; ++i) {
      const next = sibling(terms[i]);
      if (next && call(tagName, next, []) === 'DD')
        accept(text(terms[i]), text(next), 'definitionList');
    }
    const groups = nodes(html, '.list-group-item', true);
    for (let i = 0; i < groups.length; ++i) {
      const parts = nodes(groups[i], 'label, span');
      for (let j = 0; j < parts.length; ++j) {
        const valueNode = sibling(parts[j]);
        if (valueNode) accept(text(parts[j]), text(valueNode), 'listGroup');
        const combined = exec(/^(\u5b66\u53f7|\u5b66\u751f\u5b66\u53f7)\s*[:\uff1a]\s*([A-Z0-9]{5,24})$/, text(parts[j]));
        if (combined) accept(combined[1], combined[2], 'listGroup');
      }
    }
    const labelNodes = nodes(html, 'label', true);
    for (let i = 0; i < labelNodes.length; ++i) {
      // Structured heading/list extraction owns these labels. Reinterpreting
      // their formatting whitespace or punctuation as a value would invent a
      // second malformed identity field.
      if (call(closestElement, labelNodes[i], ['th, dt, .list-group-item'])) continue;
      let valueNode = sibling(labelNodes[i]);
      if (!valueNode) {
        const next = call(nextNode, labelNodes[i], []);
        if (next && call(nodeType, next, []) === 3 && text(next).length > 0) valueNode = next;
      }
      // A label nested inside an already recognized table heading has no
      // sibling in that heading. It is not a second empty identity field.
      if (valueNode) accept(text(labelNodes[i]), text(valueNode), 'label');
    }
    // This diagnostic counts unique valid candidates, not repeated labels.
    summary.identityLabels = candidateCount <= 32 ? candidateCount : 0;
    const identity = record();
    identity.candidateCount = candidateCount <= 32 ? candidateCount : 0;
    identity.method = candidateCount <= 32 ? method : 'none';
    identity.malformed = malformed;
    if (candidateCount === 1) identity.accountCode = accountCode;
    return identity;
  };
  // This recognizes data declarations, not a JavaScript program. Unsupported
  // lexical constructs in a candidate script reject it; nothing is evaluated.
  const literalTokens = source => {
    if (source.length > 262144) throw 'literal_limit';
    const tokens = array();
    const stack = array();
    let depth = 0;
    let i = 0;
    const identifierStart = code => (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) || code === 36 || code === 95;
    const identifierPart = code => identifierStart(code) || (code >= 48 && code <= 57);
    while (i < source.length) {
      const character = source[i];
      if (test(/^\s$/, character)) { ++i; continue; }
      if (character === '/' && source[i + 1] === '/') {
        i += 2;
        while (i < source.length && source[i] !== '\n' && source[i] !== '\r' &&
            source[i] !== '\u2028' && source[i] !== '\u2029') ++i;
        continue;
      }
      if (character === '/' && source[i + 1] === '*') {
        i += 2;
        while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) ++i;
        if (i >= source.length) throw 'literal_unsupported';
        i += 2;
        continue;
      }
      // Do not guess whether slash is division or a regex. Template literals
      // and escaped identifiers need a JS parser and are outside this grammar.
      if (character === '/' || character === '\\' ||
          call(charCodeAt, source, [i]) === 96 || character === '#' ||
          slice(source, i, i + 4) === '<!--' || slice(source, i, i + 3) === '-->')
        throw 'literal_unsupported';
      const token = record();
      token.start = i;
      token.depth = depth;
      token.value = character;
      if (character === '"' || character === "'") {
        const quote = character;
        token.value = '';
        ++i;
        let closed = false;
        while (i < source.length) {
          const part = source[i++];
          if (part === quote) { closed = true; break; }
          if (part === '\\') {
            if (i >= source.length) throw 'literal_unsupported';
            if (source[i] === '\r' && source[i + 1] === '\n') ++i;
            ++i;
          } else if (part === '\n' || part === '\r' || part === '\u2028' || part === '\u2029') {
            throw 'literal_unsupported';
          }
        }
        if (!closed) throw 'literal_unsupported';
      } else if (identifierStart(call(charCodeAt, source, [i]))) {
        ++i;
        while (i < source.length && identifierPart(call(charCodeAt, source, [i]))) ++i;
        token.value = slice(source, token.start, i);
      } else {
        ++i;
        if (character === '(' || character === '[' || character === '{') {
          if (depth >= 64) throw 'literal_limit';
          stack[depth++] = character;
        } else if (character === ')' || character === ']' || character === '}') {
          const expected = character === ')' ? '(' : character === ']' ? '[' : '{';
          if (depth === 0 || stack[depth - 1] !== expected) throw 'literal_unsupported';
          --depth;
        } else if (call(charCodeAt, character, [0]) > 127) {
          throw 'literal_unsupported';
        }
      }
      token.end = i;
      if (tokens.length >= 20000) throw 'literal_limit';
      tokens[tokens.length] = token;
    }
    if (depth !== 0) throw 'literal_unsupported';
    return tokens;
  };
  // Check strict JSON with bounded nesting and reject duplicate object keys
  // before JSON.parse, whose normal behavior would silently keep the last key.
  const strictJson = (source, maximum = 65536, maximumDepth = 12) => {
    if (source.length > maximum) throw 'literal_limit';
    let i = 0;
    const space = () => {
      while (i < source.length && (source[i] === ' ' || source[i] === '\t' ||
          source[i] === '\n' || source[i] === '\r')) ++i;
    };
    const string = () => {
      if (source[i] !== '"') throw 'literal_invalid';
      const start = i++;
      let closed = false;
      while (i < source.length) {
        const character = source[i++];
        if (character === '"') { closed = true; break; }
        if (call(charCodeAt, character, [0]) < 32) throw 'literal_invalid';
        if (character === '\\') {
          if (i >= source.length) throw 'literal_invalid';
          const escape = source[i++];
          if (escape === 'u') {
            for (let j = 0; j < 4; ++j)
              if (i >= source.length || !test(/^[0-9a-fA-F]$/, source[i++])) throw 'literal_invalid';
          } else if (!contains(['"', '\\', '/', 'b', 'f', 'n', 'r', 't'], escape)) {
            throw 'literal_invalid';
          }
        }
      }
      if (!closed) throw 'literal_invalid';
      try { return parseJson(slice(source, start, i)); } catch (_) { throw 'literal_invalid'; }
    };
    const value = depth => {
      if (depth > maximumDepth) throw 'literal_limit';
      space();
      if (source[i] === '"') { string(); return; }
      if (source[i] === '{') {
        ++i; space();
        const seen = record();
        if (source[i] === '}') { ++i; return; }
        while (true) {
          const key = string();
          if (seen[key]) throw 'literal_key_conflict';
          seen[key] = true;
          space();
          if (source[i++] !== ':') throw 'literal_invalid';
          value(depth + 1); space();
          const delimiter = source[i++];
          if (delimiter === '}') return;
          if (delimiter !== ',') throw 'literal_invalid';
          space();
        }
      }
      if (source[i] === '[') {
        ++i; space();
        if (source[i] === ']') { ++i; return; }
        while (true) {
          value(depth + 1); space();
          const delimiter = source[i++];
          if (delimiter === ']') return;
          if (delimiter !== ',') throw 'literal_invalid';
        }
      }
      for (let j = 0; j < 3; ++j) {
        const word = ['true', 'false', 'null'][j];
        if (slice(source, i, i + word.length) === word) { i += word.length; return; }
      }
      const match = exec(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/, slice(source, i));
      if (!match) throw 'literal_invalid';
      i += match[0].length;
    };
    value(0); space();
    if (i !== source.length) throw 'literal_unsupported';
    try { return parseJson(source); } catch (_) { throw 'literal_invalid'; }
  };
  const ownValue = (object, key) => {
    const descriptor = ownDescriptor(object, key);
    return descriptor ? descriptor.value : undefined;
  };
  const serverJsonSemesters = (scripts, diagnostic) => {
    const declarations = record();
    declarations.semesters = array();
    declarations.semesterId = array();
    let unsupported = null;
    let ambiguousBinding = false;
    for (let i = 0; i < scripts.length; ++i) {
      const type = clean(attr(scripts[i], 'type') || '');
      if (type !== '' && type !== 'text/javascript' && type !== 'application/javascript') continue;
      const source = call(textContent, scripts[i], []);
      let tokens;
      try { tokens = literalTokens(source); } catch (error) {
        // Even a commented/quoted name only causes conservative rejection;
        // it can never create evidence. This covers comments between a
        // declaration keyword and name when the script cannot be tokenized.
        if (test(/\b(?:semesters|semesterId)\b/, source)) unsupported = error;
        continue;
      }
      for (let j = 0; j < tokens.length; ++j) {
        const token = tokens[j];
        const boundary = j === 0 || (tokens[j - 1].depth === 0 && tokens[j - 1].value === ';');
        if (contains(['var', 'let', 'const'], token.value) && j + 1 < tokens.length &&
            contains(['semesters', 'semesterId'], tokens[j + 1].value)) {
          if (token.depth !== 0) { ambiguousBinding = true; continue; }
          if (!boundary) ambiguousBinding = true;
          const key = tokens[j + 1].value;
          let end = j + 2;
          while (end < tokens.length && !(tokens[end].depth === 0 && tokens[end].value === ';')) ++end;
          const equal = tokens[j + 2];
          const first = tokens[j + 3];
          const literal = equal && equal.value === '=' && first && j + 3 < end
              ? slice(source, first.start, tokens[end - 1].end) : '';
          declarations[key][declarations[key].length] = literal;
          diagnostic.literalAssignments = diagnostic.literalAssignments < 10000
              ? diagnostic.literalAssignments + 1 : 10000;
        } else if (contains(['semesters', 'semesterId'], token.value)) {
          const previous = j > 0 ? tokens[j - 1] : null;
          // The binding name immediately after a declaration keyword was
          // checked above. Reject obvious writes elsewhere, including nested
          // statements, property writes, compound assignments and increments.
          if (previous && contains(['var', 'let', 'const'], previous.value)) continue;
          const next = tokens[j + 1];
          const after = tokens[j + 2];
          if (next && ((next.value === '=' && (!after || (after.value !== '=' && after.value !== '>'))) ||
              (contains(['+', '-', '*', '%', '&', '|', '^'], next.value) && after &&
               (after.value === '=' || after.value === next.value)))) ambiguousBinding = true;
        }
      }
    }
    if (declarations.semesters.length > 1 || declarations.semesterId.length > 1) throw 'literal_duplicate';
    if (unsupported) throw unsupported;
    if (declarations.semesters.length === 0) throw 'literal_missing';
    if (ambiguousBinding) throw 'literal_unsupported';
    const catalogLiteral = declarations.semesters[0];
    if (catalogLiteral[0] !== '[') throw 'literal_unsupported';
    const catalog = strictJson(catalogLiteral);
    if (!isArray(catalog)) throw 'literal_invalid';
    diagnostic.literalParsed = true;
    diagnostic.literalItems = catalog.length < 10000 ? catalog.length : 10000;
    if (catalog.length === 0) throw 'catalog_empty';
    if (catalog.length > maxSemesterOptions) throw 'catalog_limit';
    const semesters = array();
    const seen = record();
    for (let i = 0; i < catalog.length; ++i) {
      const row = catalog[i];
      if (row === null || typeof row !== 'object' || isArray(row)) throw 'catalog_id';
      const id = ownValue(row, 'id');
      if (!safeInteger(id) || id <= 0 || id > 2147483647) throw 'catalog_id';
      if (seen[id]) throw 'catalog_duplicate';
      seen[id] = true;
      let name = null;
      const nameKeys = ['nameZh', 'nameEn', 'name', 'code'];
      for (let j = 0; j < nameKeys.length; ++j) {
        const candidate = ownValue(row, nameKeys[j]);
        if (candidate === undefined) continue;
        // An invalid explicit label is not hidden by a lower-priority fallback.
        if (typeof candidate !== 'string') throw 'catalog_name';
        const label = clean(candidate);
        if (label.length === 0 || label.length > 120 ||
            test(/[\u0000-\u001f\u007f-\u009f<>]/, label)) throw 'catalog_name';
        if (name === null) name = label;
      }
      if (name === null) throw 'catalog_name';
      const semester = record();
      semester.id = id; semester.name = name; semester.selected = false;
      semesters[semesters.length] = semester;
    }
    if (declarations.semesterId.length === 0) throw 'selection_missing';
    const selectedLiteral = declarations.semesterId[0];
    if (!test(/^(?:null|[1-9][0-9]*)$/, selectedLiteral)) throw 'selection_invalid';
    const selectedId = strictJson(selectedLiteral);
    if (selectedId !== null && (!safeInteger(selectedId) || selectedId <= 0 || selectedId > 2147483647))
      throw 'selection_invalid';
    if (selectedId !== null && !seen[selectedId]) throw 'selection_unknown';
    for (let i = 0; i < semesters.length; ++i) semesters[i].selected = semesters[i].id === selectedId;
    return semesters;
  };
  const courseProjection = (html, summary) => {
    const selectors = 'select#allSemesters, select[name="allSemesters"], select#semester, select#semesterId, select[name="semester"], select[name="semesterId"]';
    const selects = nodes(html, selectors, true);
    summary.semesterSelect = selects.length === 1;
    const diagnostic = summary.courseDiagnostics;
    const reject = reason => {
      diagnostic.reason = contains(courseReasons, reason) ? reason : 'literal_invalid';
      diagnostic.source = 'none';
      throw 'course_schema';
    };
    // Live DOM counts help explain delayed client rendering, but no values or
    // selection from it can supply this response's accepted catalog.
    const liveSelects = nodes(root.document, selectors, true);
    for (let i = 0; i < liveSelects.length; ++i) {
      diagnostic.liveOptions += nodes(liveSelects[i], 'option').length;
      if (diagnostic.liveOptions > 10000) { diagnostic.liveOptions = 10000; break; }
    }
    const scripts = nodes(html, 'script:not([src])', true);
    const expressions = [/(?:^|[;\s])(?:var\s+|let\s+|const\s+|window\.)?allSemesters\s*=/,
      /(?:^|[;\s])(?:var\s+|let\s+|const\s+|window\.)?semesters\s*=/,
      /(?:^|[;\s])(?:var\s+|let\s+|const\s+|window\.)?semesterId\s*=/,
      /(?:^|[;\s])(?:var\s+|let\s+|const\s+|window\.)?bizTypeId\s*=/];
    const keys = ['allSemesters', 'semesters', 'semesterId', 'bizTypeId'];
    for (let i = 0; i < scripts.length; ++i) {
      const source = call(textContent, scripts[i], []);
      for (let j = 0; j < keys.length; ++j)
        if (test(expressions[j], source)) summary.semesterVariables[keys[j]] = true;
    }
    if (selects.length === 0) reject('select_missing');
    if (selects.length !== 1) reject('select_conflict');
    const options = nodes(selects[0], 'option');
    diagnostic.serverOptions = options.length < 10000 ? options.length : 10000;
    if (options.length === 0) {
      let semesters;
      try { semesters = serverJsonSemesters(scripts, diagnostic); }
      catch (error) { reject(error); }
      diagnostic.source = 'serverJson';
      summary.semesterOptions = semesters.length;
      return semesters;
    }
    // A nonempty invalid server select must not be bypassed with a JSON catalog.
    if (options.length > maxSemesterOptions) reject('options_limit');
    const semesters = array();
    const seen = record();
    let selected = 0;
    for (let i = 0; i < options.length; ++i) {
      const rawId = attr(options[i], 'value');
      const id = number(rawId);
      const name = text(options[i]);
      if (typeof rawId !== 'string' || !test(/^[1-9][0-9]{0,14}$/, rawId) ||
          !safeInteger(id) || id <= 0 || id > 2147483647) reject('option_value');
      if (seen[id]) reject('option_duplicate');
      if (name.length === 0 || name.length > 120 ||
          test(/[\u0000-\u001f\u007f-\u009f<>]/, name)) reject('option_name');
      seen[id] = true;
      const semester = record();
      semester.id = id;
      semester.name = name;
      semester.selected = call(optionSelected, options[i], []) === true;
      if (semester.selected) ++selected;
      semesters[semesters.length] = semester;
    }
    if (selected > 1) reject('selected_conflict');
    diagnostic.source = 'serverSelect';
    summary.semesterOptions = semesters.length;
    return semesters;
  };
  const examProjection = (html, summary) => {
    const tables = nodes(html, 'table#exams', true);
    summary.examTables = tables.length <= 10 ? tables.length : 0;
    summary.pagination = nodes(html, '.pagination, .pager, [data-pagination], nav[aria-label="pagination"], nav[aria-label="Pagination"]', true).length > 0;
    if (tables.length !== 1) throw 'exams_schema';
    if (nodes(tables[0], ':scope > thead').length !== 1 ||
        nodes(tables[0], ':scope > tbody').length !== 1 ||
        nodes(tables[0], 'table').length !== 0) throw 'exams_schema';
    const heads = nodes(tables[0], ':scope > thead > tr');
    if (heads.length !== 1) throw 'exams_schema';
    const cells = nodes(heads[0], ':scope > th, :scope > td');
    const expected = ['\u8bfe\u7a0b\u53f7', '\u8003\u8bd5\u7c7b\u578b', '\u8bfe\u7a0b\u540d\u79f0', '\u65e5\u671f\u65f6\u95f4', '\u8003\u573a', '\u6559\u5b66\u697c', '\u8003\u573a\u6240\u5728\u6821\u533a', '\u8003\u8bd5\u8bf4\u660e'];
    let recognized = cells.length === 8;
    for (let i = 0; recognized && i < cells.length; ++i) {
      const name = text(cells[i]);
      recognized = i === 0 ? (name === '\u8bfe\u7a0b\u53f7' || name === '\u8bfe\u5802\u53f7') : name === expected[i];
      if (attr(cells[i], 'rowspan') !== null || attr(cells[i], 'colspan') !== null) recognized = false;
    }
    summary.examHeader = recognized;
    const rows = nodes(tables[0], ':scope > tbody > tr');
    if (rows.length > 10000) throw 'exams_schema';
    summary.examRows = rows.length;
    if (!recognized) throw 'exams_schema';
    for (let i = 0; i < rows.length; ++i) {
      const dataCells = nodes(rows[i], ':scope > td');
      if (dataCells.length !== 8 || nodes(rows[i], ':scope > th, :scope > td').length !== 8)
        throw 'exams_schema';
      for (let j = 0; j < dataCells.length; ++j)
        if (attr(dataCells[j], 'rowspan') !== null || attr(dataCells[j], 'colspan') !== null)
          throw 'exams_schema';
    }
  };
  const dataStages = ['identityBefore', 'course', 'index', 'datum', 'exams', 'identityAfter'];
  const dataReasons = ['none', 'semester_unknown', 'identity_missing', 'identity_changed',
    'index_shape', 'index_ids', 'index_limit', 'json_invalid', 'json_duplicate', 'json_depth',
    'datum_shape', 'datum_limit', 'lesson_id', 'lesson_set', 'lesson_title', 'group_id',
    'group_lesson', 'schedule_link', 'schedule_date', 'schedule_time', 'exam_structure',
    'exam_pagination', 'exam_date', 'exam_time', 'field_conflict'];
  const dataCounts = ['identityReads', 'lessonIds', 'lessons', 'groups', 'schedules',
    'datedSchedules', 'timedSchedules', 'linkedSchedules', 'examRows', 'datedExams'];
  const dataFlags = ['semesterAccepted', 'selfRouteBound', 'identityStable',
    'emptyCourse', 'emptyExams', 'pagination'];
  const dataTypeKeys = ['lessonIds', 'lessonList', 'scheduleGroupList', 'scheduleList',
    'date', 'startTime', 'endTime'];
  const dataTypes = ['missing', 'null', 'object', 'array', 'string', 'number', 'boolean', 'mixed'];
  const emptyDataDiagnostics = () => {
    const diagnostic = record();
    diagnostic.checks = record();
    for (let i = 0; i < dataStages.length; ++i) diagnostic.checks[dataStages[i]] = 'pending';
    diagnostic.reason = 'none';
    for (let i = 0; i < dataCounts.length; ++i) diagnostic[dataCounts[i]] = 0;
    for (let i = 0; i < dataFlags.length; ++i) diagnostic[dataFlags[i]] = false;
    diagnostic.types = record();
    for (let i = 0; i < dataTypeKeys.length; ++i) diagnostic.types[dataTypeKeys[i]] = 'missing';
    return diagnostic;
  };
  const projectData = state => {
    const out = record();
    out.operation = state.operation;
    out.phase = contains(phases, state.phase) ? state.phase : 'failed';
    out.code = contains(codes, state.code) ? state.code : 'helper_unavailable';
    if (contains(dataStages, state.stage)) out.stage = state.stage;
    if (state.cancelled || state.blockedByWorker || !current(state) || !state.diagnostics) return out;
    const diagnostic = emptyDataDiagnostics();
    diagnostic.reason = contains(dataReasons, state.diagnostics.reason)
        ? state.diagnostics.reason : 'field_conflict';
    for (let i = 0; i < dataStages.length; ++i) {
      const key = dataStages[i];
      const value = state.diagnostics.checks[key];
      diagnostic.checks[key] = contains(['pending', 'ok', 'skipped', 'error'], value) ? value : 'error';
    }
    for (let i = 0; i < dataCounts.length; ++i) {
      const key = dataCounts[i];
      diagnostic[key] = bounded(state.diagnostics[key], 10000) ? state.diagnostics[key] : 0;
    }
    for (let i = 0; i < dataFlags.length; ++i) {
      const key = dataFlags[i];
      diagnostic[key] = state.diagnostics[key] === true;
    }
    for (let i = 0; i < dataTypeKeys.length; ++i) {
      const key = dataTypeKeys[i];
      const value = state.diagnostics.types[key];
      diagnostic.types[key] = contains(dataTypes, value) ? value : 'mixed';
    }
    out.diagnostics = diagnostic;
    // Only release a candidate after both server identity reads agree. It is
    // still a candidate; neither this probe nor its route witness claims data.
    if (diagnostic.identityStable && state.identity) {
      const identity = record();
      identity.candidateCount = 1;
      identity.method = contains(methods, state.identity.method) ? state.identity.method : 'none';
      if (typeof state.identity.accountCode === 'string' && test(codePattern, state.identity.accountCode)) {
        identity.accountCode = state.identity.accountCode;
        out.identity = identity;
      }
    }
    if (state.collecting && state.phase === 'done' && state.code === 'ok' &&
        diagnostic.selfRouteBound && diagnostic.identityStable) {
      const snapshot = record();
      snapshot.semesterId = state.semesterId;
      snapshot.courses = state.courses;
      snapshot.exams = state.exams;
      out.snapshot = snapshot;
    }
    return out;
  };
  const shape = value => value === undefined ? 'missing' : value === null ? 'null' :
      isArray(value) ? 'array' : contains(['object', 'string', 'number', 'boolean'], typeof value)
      ? typeof value : 'mixed';
  const object = value => value !== null && typeof value === 'object' && !isArray(value);
  const positiveId = value => safeInteger(value) && value > 0 && value <= 2147483647;
  const dataReject = (state, code, reason) => {
    if (state.diagnostics.reason === 'none') state.diagnostics.reason = reason;
    throw code;
  };
  const readJson = async (state, stage, path, payload = null) => {
    requireCurrent(state);
    state.stage = stage;
    const maximum = stage === 'datum' ? 8388608 : 2097152;
    const controller = new Abort();
    const decoder = new Decoder('utf-8', {fatal: true});
    state.controller = controller;
    state.timedOut = false;
    let reader = null;
    const timeout = timer(() => { state.timedOut = true; call(abort, controller, []); }, 30000);
    try {
      const options = record();
      options.method = payload === null ? 'GET' : 'POST';
      options.credentials = 'same-origin';
      options.redirect = 'error';
      options.cache = 'no-store';
      options.signal = call(signal, controller, []);
      options.headers = record();
      options.headers.Accept = 'application/json';
      if (payload !== null) {
        options.headers['Content-Type'] = 'application/json';
        options.body = stringifyJson(payload);
      }
      const response = await fetchOriginal(expectedOrigin + path, options);
      requireCurrent(state);
      if (call(responseStatus, response, []) !== 200 ||
          call(responseUrl, response, []) !== expectedOrigin + path) throw stage + '_http';
      const headers = call(responseHeaders, response, []);
      const mime = call(headerGet, headers, ['content-type']);
      if (typeof mime !== 'string' || !test(/^application\/json\s*(?:;[^\r\n]*)?$/i, mime))
        throw stage + '_mime';
      const length = call(headerGet, headers, ['content-length']);
      if (length !== null && test(/^[0-9]+$/, length) && number(length) > maximum)
        throw stage + '_too_large';
      const body = call(responseBody, response, []);
      if (!body) throw stage + '_schema';
      reader = call(getReader, body, []);
      let bytes = 0;
      let source = '';
      while (true) {
        const part = await call(read, reader, []);
        requireCurrent(state);
        if (part.done) break;
        bytes += call(byteLength, part.value, []);
        if (bytes > maximum) throw stage + '_too_large';
        source += call(decode, decoder, [part.value, {stream: true}]);
      }
      source += call(decode, decoder, []);
      requireCurrent(state);
      try { return strictJson(source, maximum, 24); }
      catch (error) {
        dataReject(state, stage + '_schema', error === 'literal_key_conflict' ? 'json_duplicate' :
            error === 'literal_limit' ? 'json_depth' : 'json_invalid');
      }
    } catch (error) {
      call(abort, controller, []);
      if (reader) {
        try { await call(cancelReader, reader, []); } catch (_) {}
      }
      if (state.cancelled) throw 'cancelled';
      if (state.blockedByWorker || workerControlled()) throw 'service_worker_controlled';
      if (state.timedOut) throw 'timed_out';
      if (!current(state)) throw 'stale_result';
      if (typeof error === 'string' && contains(codes, error)) throw error;
      throw 'network_failed';
    } finally {
      clearTimer(timeout);
      state.controller = null;
    }
  };
  const indexProjection = (state, input) => {
    const diagnostic = state.diagnostics;
    const ids = object(input) ? ownValue(input, 'lessonIds') : undefined;
    diagnostic.types.lessonIds = shape(ids);
    if (!isArray(ids)) dataReject(state, 'index_schema', 'index_shape');
    diagnostic.lessonIds = ids.length <= 10000 ? ids.length : 10000;
    if (ids.length > 10000) dataReject(state, 'index_schema', 'index_limit');
    const seen = record();
    const result = array();
    for (let i = 0; i < ids.length; ++i) {
      const id = ids[i];
      if (!positiveId(id) || seen[id]) dataReject(state, 'index_schema', 'index_ids');
      seen[id] = true;
      result[result.length] = id;
    }
    diagnostic.emptyCourse = ids.length === 0;
    return result;
  };
  const validDate = value => {
    if (typeof value !== 'string') return false;
    const match = exec(/^([1-9][0-9]{3})-([0-9]{2})-([0-9]{2})$/, value);
    if (!match) return false;
    const year = number(match[1]), month = number(match[2]), day = number(match[3]);
    if (month < 1 || month > 12 || day < 1) return false;
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    return day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
  };
  const timeMinutes = value => {
    let hour, minute;
    if (safeInteger(value) && value >= 0 && value <= 2359) {
      hour = (value - value % 100) / 100; minute = value % 100;
    } else if (typeof value === 'string') {
      const match = exec(/^([0-9]{1,2}):([0-9]{2})$/, value);
      if (match) { hour = number(match[1]); minute = number(match[2]); }
      else if (test(/^[0-9]{1,4}$/, value)) {
        const numeric = number(value); hour = (numeric - numeric % 100) / 100; minute = numeric % 100;
      } else return -1;
    } else return -1;
    return hour <= 23 && minute <= 59 ? hour * 60 + minute : -1;
  };
  const datumProjection = (state, input, requestedIds) => {
    const diagnostic = state.diagnostics;
    const result = object(input) ? ownValue(input, 'result') : undefined;
    const lessons = object(result) ? ownValue(result, 'lessonList') : undefined;
    const groups = object(result) ? ownValue(result, 'scheduleGroupList') : undefined;
    const schedules = object(result) ? ownValue(result, 'scheduleList') : undefined;
    diagnostic.types.lessonList = shape(lessons);
    diagnostic.types.scheduleGroupList = shape(groups);
    diagnostic.types.scheduleList = shape(schedules);
    if (!isArray(lessons) || !isArray(groups) || !isArray(schedules))
      dataReject(state, 'datum_schema', 'datum_shape');
    diagnostic.lessons = lessons.length <= 10000 ? lessons.length : 10000;
    diagnostic.groups = groups.length <= 10000 ? groups.length : 10000;
    diagnostic.schedules = schedules.length <= 10000 ? schedules.length : 10000;
    if (lessons.length > 10000 || groups.length > 10000 || schedules.length > 10000)
      dataReject(state, 'datum_schema', 'datum_limit');
    const requested = record(), lessonSet = record(), groupSet = record(), lessonNames = record();
    for (let i = 0; i < requestedIds.length; ++i) requested[requestedIds[i]] = true;
    for (let i = 0; i < lessons.length; ++i) {
      const row = lessons[i];
      const id = object(row) ? ownValue(row, 'id') : undefined;
      if (!positiveId(id) || lessonSet[id]) dataReject(state, 'datum_schema', 'lesson_id');
      if (!requested[id]) dataReject(state, 'datum_schema', 'lesson_set');
      const name = ownValue(row, 'courseName');
      if (typeof name !== 'string' || clean(name).length === 0 || name.length > 300 ||
          test(/[\u0000-\u0008\u000e-\u001f\u007f-\u009f]/, name))
        dataReject(state, 'datum_schema', 'lesson_title');
      lessonSet[id] = true;
      lessonNames[id] = name;
    }
    if (lessons.length !== requestedIds.length) dataReject(state, 'datum_schema', 'lesson_set');
    for (let i = 0; i < groups.length; ++i) {
      const row = groups[i];
      const id = object(row) ? ownValue(row, 'id') : undefined;
      if (!positiveId(id) || groupSet[id]) dataReject(state, 'datum_schema', 'group_id');
      const lessonId = ownValue(row, 'lessonId');
      if (!positiveId(lessonId) || !lessonSet[lessonId])
        dataReject(state, 'datum_schema', 'group_lesson');
      groupSet[id] = lessonId;
    }
    for (let i = 0; i < schedules.length; ++i) {
      const row = schedules[i];
      if (!object(row)) dataReject(state, 'datum_schema', 'schedule_link');
      const lessonId = ownValue(row, 'lessonId'), groupId = ownValue(row, 'scheduleGroupId');
      if (!positiveId(lessonId) || !positiveId(groupId) || !lessonSet[lessonId] ||
          groupSet[groupId] !== lessonId) dataReject(state, 'datum_schema', 'schedule_link');
      ++diagnostic.linkedSchedules;
      const date = ownValue(row, 'date'), start = ownValue(row, 'startTime'), end = ownValue(row, 'endTime');
      const fields = ['date', 'startTime', 'endTime'], values = [date, start, end];
      for (let j = 0; j < fields.length; ++j) {
        const type = shape(values[j]), key = fields[j];
        diagnostic.types[key] = i === 0 ? type : diagnostic.types[key] === type ? type : 'mixed';
      }
      if (!validDate(date)) dataReject(state, 'datum_schema', 'schedule_date');
      ++diagnostic.datedSchedules;
      const starts = timeMinutes(start), ends = timeMinutes(end);
      if (starts < 0 || ends <= starts) dataReject(state, 'datum_schema', 'schedule_time');
      ++diagnostic.timedSchedules;
      if (state.collecting) {
        const event = record();
        event.lessonId = lessonId; event.groupId = groupId;
        event.date = date; event.startMinute = starts; event.endMinute = ends;
        event.title = lessonNames[lessonId];
        state.courses[state.courses.length] = event;
      }
    }
  };
  const examDataProjection = (state, html) => {
    const diagnostic = state.diagnostics, summary = emptySummary();
    try { examProjection(html, summary); }
    catch (_) { dataReject(state, 'exams_schema', 'exam_structure'); }
    diagnostic.pagination = summary.pagination;
    diagnostic.examRows = summary.examRows;
    diagnostic.emptyExams = summary.examRows === 0;
    if (summary.pagination) dataReject(state, 'exams_schema', 'exam_pagination');
    const rows = nodes(html, 'table#exams > tbody > tr', true);
    for (let i = 0; i < rows.length; ++i) {
      const cells = nodes(rows[i], ':scope > td');
      const value = text(cells[3]);
      const date = exec(/^([1-9][0-9]{3}-[0-9]{2}-[0-9]{2})(?:\s|$)/, value);
      if (!date || !validDate(date[1])) dataReject(state, 'exams_schema', 'exam_date');
      const period = exec(/^[1-9][0-9]{3}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2})~([0-9]{2}:[0-9]{2})$/, value);
      if (!period || timeMinutes(period[1]) < 0 || timeMinutes(period[2]) <= timeMinutes(period[1]))
        dataReject(state, 'exams_schema', 'exam_time');
      ++diagnostic.datedExams;
      if (state.collecting) {
        const course = text(cells[0]), type = text(cells[1]), title = text(cells[2]);
        if (course.length === 0 || course.length > 100 || type.length === 0 || type.length > 100 ||
            title.length === 0 || title.length > 300 ||
            test(/[\u0000-\u0008\u000e-\u001f\u007f-\u009f]/, course + type + title))
          dataReject(state, 'exams_schema', 'field_conflict');
        const event = record();
        event.courseCode = course; event.examType = type; event.title = title;
        event.date = date[1]; event.startMinute = timeMinutes(period[1]);
        event.endMinute = timeMinutes(period[2]);
        state.exams[state.exams.length] = event;
      }
    }
  };
  const runData = async state => {
    let firstFailure = null, firstStage = null, before = null, semesterAccepted = false, ids = null;
    const check = async (stage, action) => {
      state.stage = stage;
      try {
        await action(); requireCurrent(state);
        state.diagnostics.checks[stage] = 'ok';
      } catch (error) {
        if (state.cancelled || !current(state) || state.blockedByWorker || workerControlled()) throw error;
        const code = typeof error === 'string' && contains(codes, error) ? error : 'helper_unavailable';
        state.diagnostics.checks[stage] = 'error';
        if (!firstFailure) { firstFailure = code; firstStage = stage; }
      }
    };
    const readIdentity = async () => {
      const html = await readHtml(state, 'identity', '/for-std/student-info/info/' + state.dataId);
      const identity = identityProjection(html, emptySummary());
      if (identity.candidateCount !== 1 || identity.malformed)
        dataReject(state, 'identity_schema', 'identity_missing');
      ++state.diagnostics.identityReads;
      return identity;
    };
    try {
      await check('identityBefore', async () => { before = await readIdentity(); });
      await check('course', async () => {
        const html = await readHtml(state, 'course', '/for-std/course-table/info/' + state.dataId);
        const semesters = courseProjection(html, emptySummary());
        for (let i = 0; i < semesters.length; ++i)
          if (semesters[i].id === state.semesterId) semesterAccepted = true;
        state.diagnostics.semesterAccepted = semesterAccepted;
        if (!semesterAccepted) dataReject(state, 'semester_unknown', 'semester_unknown');
      });
      if (before && semesterAccepted) {
        await check('index', async () => {
          const input = await readJson(state, 'index', '/for-std/course-table/get-data?bizTypeId=2&semesterId=' +
              state.semesterId + '&dataId=' + state.dataId);
          ids = indexProjection(state, input);
        });
      } else state.diagnostics.checks.index = 'skipped';
      if (ids && ids.length > 0) {
        await check('datum', async () => {
          const payload = record(); payload.lessonIds = ids;
          datumProjection(state, await readJson(state, 'datum', '/for-std/course-table/datum', payload), ids);
        });
      } else state.diagnostics.checks.datum = 'skipped';
      await check('exams', async () => {
        examDataProjection(state, await readHtml(state, 'exams', '/for-std/exam-arrange/info/' + state.dataId));
      });
      if (before) {
        await check('identityAfter', async () => {
          const after = await readIdentity();
          if (before.accountCode !== after.accountCode) {
            // Identity disagreement invalidates the entire candidate. A
            // schema error in another stage cannot mask this safety result.
            state.diagnostics.reason = 'identity_changed';
            firstFailure = 'identity_changed'; firstStage = 'identityAfter';
            throw 'identity_changed';
          }
          state.diagnostics.identityStable = true;
          state.identity = after;
        });
      } else state.diagnostics.checks.identityAfter = 'skipped';
      requireCurrent(state);
      if (state.collecting && state.courses.length + state.exams.length > 10000)
        dataReject(state, 'datum_schema', 'datum_limit');
      state.phase = firstFailure ? 'failed' : 'done';
      state.code = firstFailure || 'ok';
      state.stage = firstStage;
    } catch (error) {
      state.phase = state.cancelled ? 'cancelled' : 'failed';
      state.code = state.cancelled ? 'cancelled' :
          (typeof error === 'string' && contains(codes, error) ? error : 'helper_unavailable');
    } finally {
      state.settled = true; state.controller = null;
      if (state.phase !== 'done' || state.code !== 'ok') {
        state.courses = null; state.exams = null;
      }
      if (state.cancelled || !current(state) || state.blockedByWorker || workerControlled()) {
        state.identity = null; state.diagnostics = null;
      }
    }
  };
  const run = async state => {
    let firstFailure = null;
    let firstStage = null;
    const checkStage = async (stage, action) => {
      try {
        await action();
        requireCurrent(state);
        state.summary.stageResults[stage] = 'ok';
      } catch (error) {
        // Cancellation, document changes and Worker control invalidate the
        // operation. Ordinary read/schema failures stay specific to one item.
        if (state.cancelled || !current(state) || state.blockedByWorker || workerControlled()) throw error;
        const code = typeof error === 'string' && contains(codes, error) ? error : 'helper_unavailable';
        state.summary.stageResults[stage] = code;
        if (!firstFailure) { firstFailure = code; firstStage = stage; }
      }
    };
    try {
      await checkStage('identity', async () => {
        const html = await readHtml(state, 'identity', '/for-std/student-info/info/' + state.dataId);
        state.identity = identityProjection(html, state.summary);
        if (state.identity.candidateCount !== 1) throw 'identity_schema';
      });
      await checkStage('course', async () => {
        const html = await readHtml(state, 'course', '/for-std/course-table/info/' + state.dataId);
        state.semesters = courseProjection(html, state.summary);
      });
      await checkStage('exams', async () => {
        const html = await readHtml(state, 'exams', '/for-std/exam-arrange/info/' + state.dataId);
        examProjection(html, state.summary);
      });
      requireCurrent(state);
      state.phase = firstFailure ? 'failed' : 'done';
      state.code = firstFailure || 'ok';
      state.stage = firstStage;
    } catch (error) {
      state.phase = state.cancelled ? 'cancelled' : 'failed';
      state.code = state.cancelled ? 'cancelled' :
          (typeof error === 'string' && contains(codes, error) ? error : 'helper_unavailable');
    } finally {
      state.settled = true;
      state.controller = null;
      if (state.cancelled || !current(state) || state.blockedByWorker || workerControlled()) {
        state.identity = null; state.semesters = null; state.summary = null;
      }
    }
  };
  const authorized = (key, operation) => key === capability && safeInteger(operation) && operation > 0;
  const api = record();
  api.start = function(key, operation) {
    if (!authorized(key, operation)) return failure(operation, 'helper_unavailable', false);
    if (slot && !slot.settled) return failure(operation, 'helper_unavailable');
    if (operation <= lastOperation) return failure(operation, 'stale_result');
    lastOperation = operation;
    const match = exec(/^\/for-std\/(?:course-table|exam-arrange|student-info)\/info\/([0-9]{1,12})\/?$/, root.location.pathname);
    const state = record();
    state.operation = operation;
    state.phase = 'running'; state.code = 'pending'; state.settled = false;
    state.cancelled = false; state.controller = null; state.summary = emptySummary();
    state.blockedByWorker = false;
    state.pathname = root.location.pathname; state.search = root.location.search; state.hash = root.location.hash;
    slot = state;
    if (workerControlled()) {
      state.phase = 'failed'; state.code = 'service_worker_controlled'; state.settled = true;
      state.blockedByWorker = true; state.summary = null;
    } else if (root.location.origin !== expectedOrigin || !match) {
      state.phase = 'failed'; state.code = 'student_context_missing'; state.settled = true;
    } else {
      state.dataId = match[1];
      void run(state);
    }
    return reply(state);
  };
  const startData = function(key, operation, semesterId, collecting) {
    if (!authorized(key, operation)) return failure(operation, 'helper_unavailable', false);
    if (slot && !slot.settled) return failure(operation, 'helper_unavailable');
    if (operation <= lastOperation) return failure(operation, 'stale_result');
    lastOperation = operation;
    const state = record();
    state.dataProbe = true;
    state.collecting = collecting;
    state.courses = array(); state.exams = array();
    state.operation = operation;
    state.phase = 'running'; state.code = 'pending'; state.settled = false;
    state.cancelled = false; state.blockedByWorker = false; state.controller = null;
    state.pathname = root.location.pathname; state.search = root.location.search; state.hash = root.location.hash;
    state.diagnostics = emptyDataDiagnostics();
    slot = state;
    const match = exec(/^\/for-std\/(?:course-table|exam-arrange|student-info)\/info\/([0-9]{1,12})\/?$/, state.pathname);
    if (workerControlled()) {
      state.phase = 'failed'; state.code = 'service_worker_controlled'; state.settled = true;
      state.blockedByWorker = true; state.diagnostics = null;
    } else if (root.location.origin !== expectedOrigin || !match) {
      state.phase = 'failed'; state.code = 'student_context_missing'; state.settled = true;
    } else if (!positiveId(semesterId)) {
      state.phase = 'failed'; state.code = 'semester_unknown'; state.settled = true;
      state.diagnostics.reason = 'semester_unknown';
    } else {
      state.dataId = match[1]; state.semesterId = semesterId;
      state.diagnostics.selfRouteBound = typeof selfRouteId === 'string' && selfRouteId !== '' &&
          selfRouteId === state.dataId;
      void runData(state);
    }
    return reply(state);
  };
  api.data = function(key, operation, semesterId) { return startData(key, operation, semesterId, false); };
  api.collect = function(key, operation, semesterId) { return startData(key, operation, semesterId, true); };
  api.poll = function(key, operation) {
    if (!authorized(key, operation)) return failure(operation, 'helper_unavailable', false);
    if (!slot || slot.operation !== operation)
      return failure(operation, 'stale_result');
    if (!current(slot)) {
      slot.cancelled = true; slot.identity = null; slot.semesters = null; slot.summary = null; slot.diagnostics = null;
      slot.courses = null; slot.exams = null;
      if (slot.controller) call(abort, slot.controller, []);
      const invalid = record();
      invalid.operation = operation; invalid.phase = 'failed'; invalid.code = 'stale_result';
      invalid.settled = slot.settled;
      return reply(invalid);
    }
    return reply(slot);
  };
  api.cancel = function(key, operation) {
    if (!authorized(key, operation)) return failure(operation, 'helper_unavailable', false);
    if (!slot || slot.operation !== operation)
      return failure(operation, 'stale_result');
    slot.cancelled = true; slot.identity = null; slot.semesters = null; slot.summary = null; slot.diagnostics = null;
    slot.courses = null; slot.exams = null;
    slot.phase = slot.settled ? 'cancelled' : 'running'; slot.code = 'cancelled';
    if (slot.controller) call(abort, slot.controller, []);
    return reply(slot);
  };
  freeze(api.start); freeze(api.data); freeze(api.collect); freeze(api.poll); freeze(api.cancel); freeze(api);
  define(root, '__ustcJwProbeV1', {value: api, writable: false, configurable: false, enumerable: false});
  if (worker) call(addListener, worker, ['controllerchange', () => {
    // A controller appearing/disappearing during a read invalidates the entire
    // candidate operation; it cannot be repaired by later uncontrolled state.
    if (slot) invalidateWorker(slot);
  }]);
})
)JWPROBE";

#endif  // RUNNER_JW_PROBE_SCRIPT_H_
