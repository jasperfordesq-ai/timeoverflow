// Federation form helpers — disable-on-submit with spinner feedback.
// Included in both admin and hub layouts.
(function() {
  document.addEventListener('DOMContentLoaded', function() {
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

      // Re-enable after 10 seconds as safety timeout
      setTimeout(function() {
        btn.disabled = false;
        btn.innerHTML = originalText;
      }, 10000);
    });
  });
})();
