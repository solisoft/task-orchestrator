// Custom confirm dialog. Replaces native window.confirm() for any
// <form data-confirm="message">. Listens for `submit` via delegation,
// pops a styled overlay that matches the app's design tokens, and only
// submits when the user clicks "Confirm" (or presses Enter). Cancel,
// backdrop click, and Escape dismiss without submitting. Falls back
// to window.confirm() in environments where the overlay can't render.

(function () {
  let overlay = null;
  let messageEl = null;
  let confirmBtn = null;
  let activeForm = null;
  let returnFocus = null;

  function buildOverlay() {
    overlay = document.createElement('div');
    overlay.className = 'confirm-overlay';
    overlay.setAttribute('aria-hidden', 'true');
    overlay.innerHTML =
      '<div class="confirm-overlay-backdrop" data-confirm-cancel></div>' +
      '<div class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="confirm-dialog-title">' +
        '<div class="confirm-dialog-icon" aria-hidden="true">' +
          '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>' +
            '<line x1="12" y1="9" x2="12" y2="13"/>' +
            '<line x1="12" y1="17" x2="12.01" y2="17"/>' +
          '</svg>' +
        '</div>' +
        '<div class="confirm-dialog-title" id="confirm-dialog-title">Are you sure?</div>' +
        '<p class="confirm-dialog-message"></p>' +
        '<div class="confirm-dialog-actions">' +
          '<button type="button" class="confirm-dialog-btn confirm-dialog-btn-cancel" data-confirm-cancel>Cancel</button>' +
          '<button type="button" class="confirm-dialog-btn confirm-dialog-btn-confirm" data-confirm-ok>Confirm</button>' +
        '</div>' +
      '</div>';

    document.body.appendChild(overlay);
    messageEl = overlay.querySelector('.confirm-dialog-message');
    confirmBtn = overlay.querySelector('[data-confirm-ok]');

    overlay.addEventListener('click', function (e) {
      if (e.target.closest('[data-confirm-ok]')) {
        close(true);
      } else if (e.target.closest('[data-confirm-cancel]')) {
        close(false);
      }
    });
  }

  function open(form, message) {
    if (!overlay) buildOverlay();
    activeForm = form;
    returnFocus = document.activeElement;
    messageEl.textContent = message;
    overlay.classList.add('is-open');
    overlay.setAttribute('aria-hidden', 'false');
    document.body.classList.add('confirm-open');
    requestAnimationFrame(function () {
      try { confirmBtn.focus(); } catch (e) { /* ignore */ }
    });
  }

  function close(submitted) {
    if (!overlay) return;
    overlay.classList.remove('is-open');
    overlay.setAttribute('aria-hidden', 'true');
    document.body.classList.remove('confirm-open');
    const form = activeForm;
    activeForm = null;
    if (returnFocus && typeof returnFocus.focus === 'function') {
      try { returnFocus.focus(); } catch (e) { /* node detached */ }
    }
    returnFocus = null;
    // form.submit() does NOT fire another `submit` event, so we won't
    // re-enter this handler.
    if (submitted && form) form.submit();
  }

  document.addEventListener('submit', function (e) {
    const form = e.target;
    if (!form || form.tagName !== 'FORM') return;
    const message = form.getAttribute('data-confirm');
    if (!message) return;
    e.preventDefault();
    try {
      open(form, message);
    } catch (err) {
      // Fallback for unsupported environments.
      if (window.confirm(message)) form.submit();
    }
  });

  document.addEventListener('keydown', function (e) {
    if (!overlay || !overlay.classList.contains('is-open')) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      close(false);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      close(true);
    }
  });
})();
