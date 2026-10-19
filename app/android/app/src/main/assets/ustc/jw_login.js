(function(expectedSource, casOrigin, jwOrigin, externalCurrent) {
  'use strict';
  const root = window;
  const doc = root.document;
  const apply = Reflect.apply;
  const freeze = Object.freeze;
  const query = Document.prototype.querySelectorAll;
  const elementQuery = Element.prototype.querySelectorAll;
  const contains = Node.prototype.contains;
  const rectangles = Element.prototype.getClientRects;
  const style = root.getComputedStyle.bind(root);
  const click = HTMLElement.prototype.click;
  const dispatch = EventTarget.prototype.dispatchEvent;
  const setValue = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype, 'value').set;
  const EventClass = root.Event;
  const monotonicNow = root.performance.now.bind(root.performance);
  // A partial form gets one fixed deadline for this document and login closure.
  const PARTIAL_FORM_GRACE_MS = 1500;
  let captured = null;
  let consumed = false;
  let portalConsumed = false;
  let partialFormSince = null;

  function current() {
    return typeof externalCurrent === 'function' && externalCurrent() &&
        root === root.top && root.document === doc &&
        root.location.href === expectedSource;
  }
  function cas() {
    return current() && root.location.origin === casOrigin &&
        root.location.pathname === '/cas/login';
  }
  function all(scope, selector) {
    return apply(scope === doc ? query : elementQuery, scope, [selector]);
  }
  function visibleTree(node) {
    if (!node || node.ownerDocument !== doc || !node.isConnected ||
        !apply(contains, doc, [node])) return false;
    for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
      const css = style(ancestor);
      if (ancestor.hidden || ancestor.inert ||
          ancestor.getAttribute('aria-hidden') === 'true' ||
          css.display === 'none' || css.visibility === 'hidden' ||
          css.visibility === 'collapse' || Number(css.opacity) === 0)
        return false;
    }
    return true;
  }
  function visible(node) {
    return visibleTree(node) && apply(rectangles, node, []).length > 0;
  }
  function actionable(node) {
    return visible(node) && !node.disabled &&
        node.getAttribute('aria-disabled') !== 'true';
  }
  function challenge() {
    // A login-method switch is availability, not an active challenge. Inspect
    // rendered challenge controls and explicit active modes, never their text.
    const markers = all(doc,
        '[id*="captcha" i], [name*="captcha" i], [class*="captcha" i], ' +
        '[id*="verify-code" i], [name*="otp" i], [autocomplete="one-time-code"], ' +
        'iframe[src*="captcha" i]');
    for (const marker of markers) {
      if (!visible(marker)) continue;
      if (['INPUT', 'IMG', 'CANVAS', 'IFRAME'].includes(marker.tagName)) return true;
      if (['BUTTON', 'A'].includes(marker.tagName) ||
          marker.getAttribute('role') === 'tab') continue;
      for (const control of all(marker, 'input:not([type="hidden"]), img, canvas, iframe'))
        if (visible(control)) return true;
      if (marker.getAttribute('role') === 'dialog') return true;
    }
    const keys = all(doc, '[data-webauthn], [id*="passkey" i], [name*="passkey" i]');
    for (const key of keys) {
      if (!visible(key)) continue;
      if (key.tagName === 'INPUT' || key.getAttribute('aria-selected') === 'true' ||
          key.getAttribute('aria-pressed') === 'true' ||
          ['dialog', 'tabpanel'].includes(key.getAttribute('role'))) return true;
    }
    return false;
  }
  function selectForm() {
    if (!cas()) return {state: 'manualRequired'};
    if (challenge()) return {state: 'challengeRequired'};
    // The public CAS template has a hidden autoLoginForm and a display:none
    // username mirror. Neither grants a credential capability. Uniqueness is
    // proved over visible controls, then over their one shared owning form.
    const formContainers = Array.from(all(doc, 'form')).filter(visibleTree);
    // A hidden-only auxiliary form has no credential controls even when the
    // form element itself has default CSS. Count rendered owning controls,
    // as the public CAS template and the Windows reader do.
    const forms = formContainers.filter(form =>
      Array.from(all(form, 'input, button, select, textarea')).some(control =>
        control.form === form && visible(control)));
    const usernames = Array.from(all(doc, 'input[name="username"], input#username'))
        .filter(visible);
    const passwords = Array.from(all(doc, 'input[type="password"]')).filter(visible);
    const buttons = Array.from(all(doc, '#submitBtn, button.login-button')).filter(visible);
    const form = forms.length === 1 ? forms[0] : null;
    const visibleFormControls = form ?
        Array.from(all(form, 'input, button, select, textarea')).filter(control =>
          control.form === form && visible(control)) : [];
    const visibleActions = form ? Array.from(all(form,
        'button, input[type="submit"], input[type="button"]')).filter(visible) : [];
    if (usernames.length === 0 && passwords.length === 0 && buttons.length === 0 &&
        forms.length === 0) return {state: formContainers.length === 0 ?
          'waiting' : 'incompleteForm'};
    if (usernames.length > 1 || passwords.length > 1 || buttons.length > 1 ||
        forms.length > 1) return {state: 'pageStructureChanged'};
    if (buttons.length === 0 && visibleActions.some(action => !buttons.includes(action)))
      return {state: 'pageStructureChanged'};
    const username = usernames[0] || null;
    const password = passwords[0] || null;
    const button = buttons[0] || null;
    const present = [username, password, button].filter(Boolean);
    if (!form) return {state: 'pageStructureChanged'};
    if (present.length === 0) {
      return visibleFormControls.length === 0 ?
          {state: 'incompleteForm'} : {state: 'pageStructureChanged'};
    }
    if (present.some(node => node.form !== form) ||
        (username && (!['text', 'email'].includes(username.type) || username.readOnly)) ||
        (password && (password.type !== 'password' || password.readOnly)) ||
        (button && (!['BUTTON', 'INPUT'].includes(button.tagName) ||
            !['submit', 'button'].includes(button.type))) ||
        !actionable(form) || present.some(node => !actionable(node)))
      return {state: 'pageStructureChanged'};
    for (const input of all(doc, 'input, select, textarea')) {
      if (input === username || input === password || !visible(input)) continue;
      if (input.tagName !== 'INPUT' ||
          !['hidden', 'submit', 'button', 'reset', 'checkbox'].includes(input.type))
        return {state: 'pageStructureChanged'};
    }
    if (!username || !password || !button) return {state: 'incompleteForm'};
    return {state: 'formReady', form, username, password, button};
  }
  function changed(nodes) {
    if (!nodes || !cas()) return 'manualRequired';
    const checked = selectForm();
    if (checked.state === 'challengeRequired') return checked.state;
    return checked.state === 'formReady' && checked.form === nodes.form &&
        checked.username === nodes.username && checked.password === nodes.password &&
        checked.button === nodes.button ? null : 'pageStructureChanged';
  }
  function clearCaptured(nodes) {
    // Clear only the captured input objects; do not inspect their current value
    // and do not dispatch further school handlers after a failed guard.
    if (!nodes) return;
    try { apply(setValue, nodes.password, ['']); } catch (_) {}
    try { apply(setValue, nodes.username, ['']); } catch (_) {}
  }
  function advance() {
    if (!current()) return 'manualRequired';
    if (root.location.origin === jwOrigin && root.location.pathname === '/login') {
      if (portalConsumed) return 'waiting';
      const wrappers = all(doc, '#login-unified-wrapper');
      if (wrappers.length === 0) return 'waiting';
      if (wrappers.length !== 1 || !actionable(wrappers[0])) return 'pageStructureChanged';
      portalConsumed = true;
      apply(click, wrappers[0], []);
      return 'portalActivated';
    }
    const selected = selectForm();
    if (selected.state === 'formReady') {
      captured = selected;
      return selected.state;
    }
    if (selected.state === 'incompleteForm') {
      if (partialFormSince === null) partialFormSince = monotonicNow();
      // Keep the first observation time so DOM churn cannot extend the grace.
      return monotonicNow() - partialFormSince < PARTIAL_FORM_GRACE_MS ?
          'waiting' : 'pageStructureChanged';
    }
    return selected.state;
  }
  function submit(username, password) {
    // Consume before any validation or school event. No retry can reuse this
    // closure, even when a synchronous handler replaces nodes or changes route.
    if (consumed) return 'manualRequired';
    consumed = true;
    const nodes = captured;
    captured = null;
    if (typeof username !== 'string' || typeof password !== 'string' ||
        !username.length || username.length > 256 ||
        !password.length || password.length > 1024)
      return 'manualRequired';
    const initialChange = changed(nodes);
    if (initialChange) return initialChange;
    try {
      function stopIfChanged() {
        const state = changed(nodes);
        if (state) clearCaptured(nodes);
        return state;
      }
      apply(setValue, nodes.username, [username]);
      for (const type of ['input', 'change']) {
        const before = stopIfChanged();
        if (before) return before;
        apply(dispatch, nodes.username, [new EventClass(type, {bubbles: true})]);
        const after = stopIfChanged();
        if (after) return after;
      }
      const beforePassword = stopIfChanged();
      if (beforePassword) return beforePassword;
      apply(setValue, nodes.password, [password]);
      for (const type of ['input', 'change']) {
        const before = stopIfChanged();
        if (before) return before;
        apply(dispatch, nodes.password, [new EventClass(type, {bubbles: true})]);
        const after = stopIfChanged();
        if (after) return after;
      }
      const beforeClick = stopIfChanged();
      if (beforeClick) return beforeClick;
      apply(click, nodes.button, []);
      return 'submitted';
    } catch (_) {
      clearCaptured(nodes);
      return 'pageStructureChanged';
    }
  }
  return freeze({advance, submit});
})
