// Federation form helpers — disable-on-submit with spinner feedback,
// character counters, auto-submit selects, and listing expand/collapse.
// Included in both admin and hub layouts.
// Compatible with both plain page loads and Turbo/Turbolinks navigation.
(function() {
  // --- Delegated listeners (register once, never duplicate) ---
  function installGlobalListeners() {
    if (window._federationGlobalListenersInstalled) return;
    window._federationGlobalListenersInstalled = true;

    // Double-submit prevention (delegated on document)
    document.addEventListener('submit', function(e) {
      var form = e.target;
      if (!form || form.tagName !== 'FORM') return;

      // Skip GET forms (filters, searches)
      if (form.method && form.method.toUpperCase() === 'GET') return;

      var btn = form.querySelector('button[type="submit"], input[type="submit"]');
      if (!btn || btn.disabled) return;

      // Disable button and show spinner — use data attribute for i18n
      btn.disabled = true;
      var originalText = btn.innerHTML;
      btn.setAttribute('data-original-text', originalText);
      var processingText = btn.getAttribute('data-processing-text') || 'Processing\u2026';
      btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1" role="status" aria-hidden="true"></span> ' + processingText;

      // Re-enable after 30 seconds as safety timeout (page will reload on response)
      setTimeout(function() {
        btn.disabled = false;
        btn.innerHTML = originalText;
      }, 30000);
    });

    // Re-enable buttons when navigating back (bfcache)
    window.addEventListener('pageshow', function(event) {
      if (event.persisted) {
        document.querySelectorAll('button[data-original-text]').forEach(function(btn) {
          btn.disabled = false;
          btn.innerHTML = btn.getAttribute('data-original-text');
        });
      }
    });

    // Listing expand/collapse (delegated on document)
    document.addEventListener('click', function(e) {
      var expand = e.target.closest('.listing-expand');
      if (expand) {
        e.preventDefault();
        var shortSpan = expand.closest('.listing-desc-short');
        if (shortSpan) {
          shortSpan.style.display = 'none';
          shortSpan.nextElementSibling.style.display = 'inline';
          // L8: Toggle aria-expanded on the expand/collapse buttons
          expand.setAttribute('aria-expanded', 'true');
          var collapseBtn = shortSpan.nextElementSibling.querySelector('.listing-collapse');
          if (collapseBtn) collapseBtn.setAttribute('aria-expanded', 'true');
        }
        return;
      }
      var collapse = e.target.closest('.listing-collapse');
      if (collapse) {
        e.preventDefault();
        var fullSpan = collapse.closest('.listing-desc-full');
        if (fullSpan) {
          fullSpan.style.display = 'none';
          fullSpan.previousElementSibling.style.display = 'inline';
          // L8: Toggle aria-expanded on the expand/collapse buttons
          collapse.setAttribute('aria-expanded', 'false');
          var expandBtn = fullSpan.previousElementSibling.querySelector('.listing-expand');
          if (expandBtn) expandBtn.setAttribute('aria-expanded', 'false');
        }
      }
    });
  }

  // --- Per-page initializers (safe to run on every navigation) ---
  function initPageHelpers() {

    // Character counters — skip already-initialized fields
    document.querySelectorAll('[data-char-counter="true"]').forEach(function(field) {
      if (field.dataset.charCounterInit) return;
      field.dataset.charCounterInit = '1';

      var max = parseInt(field.getAttribute('maxlength'), 10);
      if (!max) return;

      var counter = field.parentElement.querySelector('.char-counter');
      if (!counter) return;

      function updateCounter() {
        var remaining = max - field.value.length;
        counter.textContent = remaining + ' / ' + max + ' characters remaining';
        counter.style.color = remaining < max * 0.1 ? '#dc3545' : '';
      }

      field.addEventListener('input', updateCounter);
      updateCounter();
    });

    // Auto-submit selects — skip already-initialized selects
    document.querySelectorAll('select[data-auto-submit]').forEach(function(sel) {
      if (sel.dataset.autoSubmitInit) return;
      sel.dataset.autoSubmitInit = '1';

      var debounceTimer = null;
      sel.addEventListener('change', function() {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(function() {
          var form = sel.closest('form');
          if (form) form.submit();
        }, 300);
      });
    });
  }

  function boot() {
    installGlobalListeners();
    initPageHelpers();
  }

  // Support both standard page loads and Turbo/Turbolinks navigation.
  // DOMContentLoaded fires on initial load; turbo:load fires on Turbo navigations;
  // turbolinks:load fires on legacy Turbolinks navigations.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
  document.addEventListener('turbo:load', boot);
  document.addEventListener('turbolinks:load', boot);
})();
