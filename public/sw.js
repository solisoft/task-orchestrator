// Service worker — receives Web Push payloads from the server and
// renders a system notification. Click → focus an existing tab on the
// task URL, or open a new one.

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload = { title: 'Task', status: '', url: '/' };
  if (event.data) {
    try {
      payload = Object.assign(payload, event.data.json());
    } catch (e) {
      payload.title = event.data.text() || payload.title;
    }
  }
  const title = payload.title || 'Task';
  const opts = {
    body: '→ ' + (payload.status || 'updated'),
    data: { url: payload.url || '/' },
    icon: '/css/application.css' // no dedicated icon yet — fall through to the OS default
  };
  event.waitUntil(self.registration.showNotification(title, opts));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil((async () => {
    const clientList = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of clientList) {
      if (client.url.endsWith(target) && 'focus' in client) {
        return client.focus();
      }
    }
    if (self.clients.openWindow) {
      return self.clients.openWindow(target);
    }
    return null;
  })());
});
