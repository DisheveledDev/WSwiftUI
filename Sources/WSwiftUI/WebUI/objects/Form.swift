//
//  Form.swift
//  SWWebAppServer
//
//  Created by Adrian on 08/07/2025.
//

import Foundation

// 1) Dedicated subclass for the <form> element
public class WebFormElement: WebElement {}

// 2) Enums for method and encoding types
public enum FormMethod: String {
    case get = "get"
    case post = "post"
}

public enum FormEncType: String {
    case urlEncoded    = "application/x-www-form-urlencoded"
    case multipart      = "multipart/form-data"
    case plainText      = "text/plain"
}

// 3) Fluent modifiers for form attributes
public extension WebFormElement {
    /// Sets the form action URL
    @discardableResult
    func action(_ url: String) -> Self {
        addAttribute(.pair("action", url))
        return self
    }

    /// Sets the HTTP method (get or post)
    @discardableResult
    func method(_ method: FormMethod) -> Self {
        addAttribute(.pair("method", method.rawValue))
        return self
    }

    /// Sets the form encoding type
    @discardableResult
    func encType(_ type: FormEncType) -> Self {
        addAttribute(.pair("enctype", type.rawValue))
        return self
    }

    /// Enables or disables browser validation
    @discardableResult
    func noValidate(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.custom("novalidate"))
        }
        return self
    }

    /// Sets the autocomplete attribute ("on", "off", or any valid value)
    @discardableResult
    func autoComplete(_ setting: String) -> Self {
        addAttribute(.pair("autocomplete", setting))
        return self
    }
}

// 4) DSL factory on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Creates a <form> element with optional attributes
    @discardableResult
    func Form(action: String? = nil,
              method: FormMethod = .post,
              encType: FormEncType? = .multipart,
              autoComplete: String? = nil,
              _ content: WebComposerClosure) -> WebFormElement {
        let form = WebFormElement()
        populateCreatedObject(form)
        form.elementName = "form"
        form.addAttribute(.class("wsui-form"))
        form.method(method)
        if let url = action {
            form.action(url)
        }
        if let enc = encType {
            form.encType(enc)
        }
        if let auto = autoComplete {
            form.autoComplete(auto)
        }
        
        // now we want to add a script that intercepts the form submission. It will look within the form element for all child objects that have an attribute of `validation`.  The contents of this attribute is a comma separated list of validation conditions.  If no validation attributes are found for any child objects or they all all pass the conditions then allow the submission to continue. If it fails, then insert the appropriate error message in the the div with the id validation_error_{id} where {id} is the id of the form element.
        form.addAttribute(.domLoadedScript("""
            // Attach validation to this form
        (function () {
        var formEl =  document.getElementsByClassName('\(form.builderId)')[0];
        if (!formEl) return;
        
        // Optional: live re-validation as users type/change
        var watch = formEl.querySelectorAll('[validation]');
        watch.forEach(function (el) {
        el.addEventListener('input', function () { validateAndRender(el); });
        el.addEventListener('change', function () { validateAndRender(el); });
        });
        
        formEl.onsubmit = function (event) {
        var valid = true;
        var firstInvalid = null;
        
        // Validate every element that declares `validation`
        var elements = formEl.querySelectorAll('[validation]');
        elements.forEach(function (el) {
        // clear previous state, then validate
        clearError(el);
        var result = validateAndRender(el);
        if (!result.ok) {
        valid = false;
        if (!firstInvalid) firstInvalid = el;
        }
        });
        
        if (!valid) {
        event.preventDefault();
        // Highlight + focus the first invalid field
        if (firstInvalid && typeof firstInvalid.focus === 'function') {
        firstInvalid.focus({ preventScroll: true });
        if (typeof firstInvalid.scrollIntoView === 'function') {
          firstInvalid.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
        }
        }
        };
        
        // -- Helpers --------------------------------------------------------------
        
        function validateAndRender(el) {
        var tokens = (el.getAttribute('validation') || '')
        .split(',')
        .map(function (s) { return s.trim(); })
        .filter(Boolean);
        
        var messages = [];
        var ok = true;
        
        tokens.forEach(function (token) {
        if (!validateElement(el, token)) {
        ok = false;
        messages.push(messageForValidation(token));
        }
        });
        
        if (!ok) {
        setError(el, messages.join(' '));
        } else {
        setValid(el);
        }
        
        return { ok: ok, messages: messages };
        }
        
        function getElementStringValue(el) {
        var tag = (el.tagName || '').toLowerCase();
        var type = (el.getAttribute('type') || '').toLowerCase();
        
        if (tag === 'select') {
        if (el.multiple) {
        // join selected text values for length checks
        return Array.from(el.selectedOptions || []).map(function (o) { return o.value || o.text; }).join(',').trim();
        }
        return (el.value || '').toString();
        }
        
        if (tag === 'textarea') {
        return (el.value || '').toString();
        }
        
        if (tag === 'input') {
        if (type === 'checkbox' || type === 'radio') {
        return el.checked ? (el.value || 'on') : '';
        }
        return (el.value || '').toString();
        }
        
        // fallback to textContent if needed
        return (el.value != null ? el.value : el.textContent || '').toString();
        }
        
        function parseValidationToken(token) {
        var parts = token.split(':');
        return { name: parts[0], arg: parts.length > 1 ? parts.slice(1).join(':') : null };
        }
        
        function validateElement(el, token) {
        var value = getElementStringValue(el);
        var v = parseValidationToken(token);
        var name = (v.name || '').trim();
        var arg = v.arg;
        
        // Helpers
        var isEmpty = value.trim().length === 0;
        
        switch (name) {
        case 'notEmpty':
        return !isEmpty;
        
        case 'empty':
        return isEmpty;
        
        case 'atLeast': {
        var n = parseInt(arg || '0', 10);
        if (isNaN(n) || n < 0) n = 0;
        return value.length >= n;
        }
        
        // Type/format validators treat empty as OK *unless* `notEmpty` is also present
        // so that you can combine e.g. `notEmpty,validEmail`.
        case 'validURL':
        if (isEmpty) return true;
        try {
          var u = new URL(value);
          return u.protocol === 'http:' || u.protocol === 'https:';
        } catch (e) {
          return false;
        }
        
        case 'validEmail':
        if (isEmpty) return true;
        // Simple, sane email pattern
        return /^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(value);
        
        case 'validPhoneNumber':
        if (isEmpty) return true;
        // Allows +, spaces, (), dashes, dots; min 6 digits/characters
        return /^[+]?[\\d\\s().-]{6,}$/.test(value);
        
        case 'validDate':
        if (isEmpty) return true;
        return !isNaN(Date.parse(value));
        
        case 'validJSON':
        if (isEmpty) return true;
        try {
          JSON.parse(value);
          return true;
        } catch (e) {
          return false;
        }
        
        case 'validNumber':
        if (isEmpty) return true;
        var n = Number(value);
        return Number.isFinite(n);
        
        default:
        // Unknown validators are treated as pass
        return true;
        }
        }
        
        function messageForValidation(token) {
        var v = parseValidationToken(token);
        switch (v.name) {
        case 'notEmpty':        return 'This field is required.';
        case 'empty':           return 'This field must be empty.';
        case 'atLeast':         return 'Please enter at least ' + (v.arg || '0') + ' characters.';
        case 'validURL':        return 'Please enter a valid URL (e.g., https://example.com).';
        case 'validEmail':      return 'Please enter a valid email address.';
        case 'validPhoneNumber':return 'Please enter a valid phone number.';
        case 'validDate':       return 'Please enter a valid date.';
        case 'validJSON':       return 'Please enter valid JSON.';
        case 'validNumber':     return 'Please enter a valid number.';
        default:                return 'Invalid value.';
        }
        }
        
        function errorDivFor(el) {
        if (!el || !el.id) return null;
        var id = 'validation_error_' + el.id;
        return document.getElementById(id);
        }
        
        function clearError(el) {
        if (!el) return;
        el.classList.remove('is-invalid');
        el.removeAttribute('aria-invalid');
        
        var div = errorDivFor(el);
        if (div) {
        div.textContent = '';
        // keep a consistent class for Bootstrap feedback styling
        if (!div.classList.contains('invalid-feedback')) {
        div.classList.add('invalid-feedback');
        }
        // If you’re hiding it via CSS when empty, that’s fine; otherwise no-op
        }
        }
        
        function setError(el, message) {
        if (!el) return;
        el.classList.add('is-invalid');
        el.classList.remove('is-valid');
        el.setAttribute('aria-invalid', 'true');
        
        var div = errorDivFor(el);
        if (div) {
        if (!div.classList.contains('invalid-feedback')) {
        div.classList.add('invalid-feedback');
        }
        div.textContent = message || 'Invalid value.';
        // Ensure screen readers associate input with error
        var describedBy = (el.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean);
        if (describedBy.indexOf(div.id) === -1) {
        describedBy.push(div.id);
        el.setAttribute('aria-describedby', describedBy.join(' '));
        }
        }
        }
        
        function setValid(el) {
        if (!el) return;
        el.classList.remove('is-invalid');
        el.removeAttribute('aria-invalid');
        el.classList.add('is-valid');
        
        var div = errorDivFor(el);
        if (div) {
        div.textContent = '';
        if (!div.classList.contains('invalid-feedback')) {
        div.classList.add('invalid-feedback');
        }
        }
        }
        })();

        """))
        
        return withParent(form, content)
    }

}
