# Web Push notifications

Web Push notifies a user's devices when a generation finishes (`done`) or fails
(`error`). User cancellations, subagent chats and suppressed handoff parents do
not notify. Delivery is driven by `IntellectualClub.Notifications`:
`WebPushGenerationEvent` is an idempotency ledger, `WebPushSender` performs the
encrypted HTTP request, and `server/priv/static/service-worker.js` shows the
notification on the device.

## Payload format

Every push carries one JSON document that works both with Declarative Web Push
(Safari / iOS / iPadOS 18.4+, macOS Safari 18.5+) and with service workers in
every other browser:

```json
{
  "web_push": 8030,
  "mutable": true,
  "notification": {
    "title": "Generation finished",
    "body": "Chat note: answer preview…",
    "lang": "en",
    "navigate": "https://club.example/chats/12?focusMessage=34",
    "tag": "chat:12",
    "icon": "https://club.example/images/pwa/icon-192.png",
    "data": { "url": "/chats/12?focusMessage=34", "chat_id": 12, "message_id": 34, "status": "done" }
  },
  "type": "generation_finished",
  "status": "done",
  "chat_id": 12,
  "message_id": 34,
  "title": "Generation finished",
  "body": "Chat note: answer preview…",
  "url": "/chats/12?focusMessage=34",
  "tag": "chat:12"
}
```

- `web_push: 8030` opts the message into declarative parsing. WebKit requires a
  non-empty `notification.title` and absolute `navigate` (and `icon`) URLs; any
  invalid member makes it silently treat the message as a classic push, so the
  URLs are built from the Web Push settings `public_origin`. Without a public
  origin only the flat legacy fields are sent.
- `mutable: true` still dispatches the `push` event to the service worker. For a
  declarative message WebKit sets `event.data` to `null` and exposes the parsed
  `notification` as the proposed `event.notification` (with `data` already
  parsed); the worker rebuilds the same notification from it and replaces the
  proposed one. If the worker fails or is gone, Safari shows the declarative
  `notification` itself.
- A notification with `navigate` is opened by the browser itself on click
  (Notifications spec: `notificationclick` is not fired), so `navigate` must be
  the in-app chat URL. The SPA honours such a launch URL: the last stored PWA
  route is only restored when the app starts at `/`.
- iOS applies `navigate` when the Home Screen app was terminated or is visible,
  but restores a backgrounded app without navigating (WebKit bug 268797). To
  recover, the service worker records each shown notification (tag, in-app URL,
  time) in the `intellectual-club:web-push:shown` cache. When an iOS Home Screen
  app becomes visible again, the page takes those records and routes to the
  latest notification shown while it was hidden that is no longer in
  Notification Center (`startWebPushTapRecovery`). A notification swiped away in
  the meantime is indistinguishable from a tap and also opens its chat.
- The flat legacy fields keep service workers installed before the declarative
  format working until they update. Browsers without Declarative Web Push
  (Chrome, Firefox, Android) ignore `web_push` and hand the JSON to the worker.
- The JSON is kept under 3584 bytes (push services cap encrypted messages at
  4096 bytes); the body is shortened with an ellipsis when needed.
- Pushes are sent with `Urgency: high`, otherwise FCM uses normal priority and
  Android defers delivery while the device dozes.

## Silent push penalty

Safari requires `userVisibleOnly`: a classic push whose `push` event settles
without `showNotification()` (handler error, rejected `waitUntil` promise, worker
that failed to start) counts as a silent push. After three silent pushes WebKit
removes every push subscription of the origin, and the counter is never reset by
successful pushes. Apple keeps accepting pushes for the removed endpoint, so the
server cannot notice. On iOS the penalty is also applied when
`showNotification()` is not called within webpushd's timeout, which can happen
while a closed web app cold-starts. Declarative messages are exempt because a
notification is always shown.

The service worker therefore:

- never lets the `push` lifetime promise reject and falls back to a generic
  "Intellectual Club" notification when the payload or the first
  `showNotification()` call fails; for a declarative push it skips the generic
  fallback, because the proposed notification is shown anyway;
- passes `navigate` to `showNotification()`, because WebKit refuses to replace a
  declarative notification without it;
- does not throw while evaluating its script: a missing or invalid precache
  manifest only fails `install` and leaves requests to the network.

## Devices and lost subscriptions

- The browser keeps a stable device id in `localStorage`
  (`intellectual-club:web-push:device-id`) and sends it with each subscription
  upsert. When a device subscribes with a new endpoint, the server removes that
  user's other subscriptions with the same device id, so a revoked endpoint does
  not linger.
- Subscriptions rejected by the push service with 404/410 are removed and logged
  with the endpoint host, device id and user agent.
- A subscription created with rotated VAPID keys is removed on the server as well
  as unsubscribed in the browser.
- `intellectual-club:web-push:enabled` remembers that notifications were enabled
  on this device. On startup, if it is set but the browser has no subscription
  (or permission was reset), the app shows a banner offering to turn
  notifications on again; enabling must happen from that click because Safari
  only subscribes on a user gesture. If permission is denied, the banner only
  explains how to allow notifications. Dismissing the banner, disabling
  notifications or signing out clears the flag.
- `pushsubscriptionchange` is not handled: re-subscribing from the worker would
  need the session's CSRF token, and the event is not a reliable signal for
  subscriptions WebKit revokes after silent pushes.
