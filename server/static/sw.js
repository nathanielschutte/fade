// napsack's service worker: only notifications. It doesn't cache the app, so
// every load gets the newest version and the "napsack was updated" banner
// keeps working. Notifications say who, never what (server/src/push.rs).

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let note = {};
  try {
    note = event.data ? event.data.json() : {};
  } catch {
    // Show something anyway: browsers expect a notification for every push.
  }
  const title = typeof note.title === "string" && note.title ? note.title : "napsack";
  event.waitUntil(self.registration.showNotification(title, {
    body: typeof note.body === "string" ? note.body : "",
    tag: typeof note.tag === "string" ? note.tag : undefined,
    renotify: Boolean(note.tag),
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    data: { url: typeof note.url === "string" ? note.url : "/" },
  }));
});

// Tapping a notification opens napsack at that chat: in an open window if
// there is one, otherwise in a new one.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  // Only ever a path on this site.
  const url = new URL(event.notification.data?.url || "/", self.location.origin);
  const target = url.origin === self.location.origin ? url.href : self.location.origin + "/";
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of windows) {
      if (new URL(w.url).origin === self.location.origin) {
        await w.focus();
        w.postMessage({ type: "open", url: target });
        return;
      }
    }
    await self.clients.openWindow(target);
  })());
});
