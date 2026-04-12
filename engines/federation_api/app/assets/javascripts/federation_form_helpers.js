// Federation form helpers — disable-on-submit with spinner feedback,
// character counters, and auto-submit selects.
// Included in both admin and hub layouts.
(function() {
  document.addEventListener('DOMContentLoaded', function() {

    // --- Double-submit prevention ---
    document.addEventListener('submit', function(e) {
      var form = e.target;
      if (!form || form.tagName !== 'FORM') return;

      // Skip GET forms (filters, searches)
      if (form.method && form.method.toUpperCase() === 'GET') return;

      var btn = form.querySelector('button[type="submit"], input[type="submit"]');
      if (!btn || btn.disabled) return;

      // Disable button and show spinner
      btn.disabled = true;
      var originalText = btn.innerHTML;
      btn.setAttribute('data-original-text', originalText);
      btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1" role="status" aria-hidden="true"></span> Processing\u2026';

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

    // --- Character counters ---
    // Any input/textarea with data-char-counter="true" and a maxlength attribute
    // will show a live character count in the next sibling .char-counter element.
    document.querySelectorAll('[data-char-counter="true"]').forEach(function(field) {
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

    // --- Auto-submit selects ---
    // Any select with data-auto-submit will submit its parent form on change.
    document.querySelectorAll('select[data-auto-submit]').forEach(function(sel) {
      sel.addEventListener('change', function() {
        var form = sel.closest('form');
        if (form) form.submit();
      });
    });
  });
})();
