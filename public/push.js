// Browser-side push setup. Loaded on every page (defer in the layout)
// to register the service worker, and exposes `window.taskOrchPush`
// for the settings page button to call.

(function () {
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
    return;
  }

  const SUBSCRIBE_URL = '/push_subscriptions';
  const VAPID_KEY_URL = '/push/vapid-public-key';

  // Register the service worker on every load — it's idempotent.
  navigator.serviceWorker.register('/sw.js').catch((err) => {
    console.warn('[push] sw register failed:', err);
  });

  function urlBase64ToUint8Array(base64) {
    const padding = '='.repeat((4 - (base64.length % 4)) % 4);
    const normalized = (base64 + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = atob(normalized);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) {
      out[i] = raw.charCodeAt(i);
    }
    return out;
  }

  async function getVapidKey() {
    const resp = await fetch(VAPID_KEY_URL, { cache: 'no-store' });
    if (!resp.ok) throw new Error('vapid key fetch failed: ' + resp.status);
    const text = (await resp.text()).trim();
    if (!text) throw new Error('vapid key not configured on server');
    return urlBase64ToUint8Array(text);
  }

  async function subscribe() {
    const perm = await Notification.requestPermission();
    if (perm !== 'granted') {
      throw new Error('permission ' + perm);
    }
    const reg = await navigator.serviceWorker.ready;
    const key = await getVapidKey();
    const sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: key
    });
    const resp = await fetch(SUBSCRIBE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(sub.toJSON())
    });
    if (!resp.ok) throw new Error('server rejected subscribe: ' + resp.status);
    return sub;
  }

  async function unsubscribe() {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (!sub) return false;
    const json = sub.toJSON();
    await sub.unsubscribe();
    await fetch(SUBSCRIBE_URL + '/delete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(json)
    });
    return true;
  }

  async function currentState() {
    if (typeof Notification === 'undefined') return 'unsupported';
    if (Notification.permission === 'denied') return 'denied';
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) return 'subscribed';
    if (Notification.permission === 'granted') return 'granted';
    return 'default';
  }

  window.taskOrchPush = { subscribe, unsubscribe, currentState };
})();
